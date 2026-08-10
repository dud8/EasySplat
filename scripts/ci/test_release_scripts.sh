#!/usr/bin/env bash
# shellcheck source-path=SCRIPTDIR
# Source-contract assertions intentionally match literal shell and Actions expressions.
# shellcheck disable=SC2016
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
/usr/bin/python3 -I \
  "$ROOT/scripts/release/tests/test_release_entrypoint_headless.py"
if [ "${EASYSPLAT_RELEASE_TEST_SACRIFICIAL_CHILD:-0}" != 1 ]; then
  /usr/bin/python3 -I - "$ROOT/scripts/ci/test_release_scripts.sh" <<'PY'
import os
import signal
import subprocess
import sys

environment = os.environ.copy()
environment["EASYSPLAT_RELEASE_TEST_SACRIFICIAL_CHILD"] = "1"
process = subprocess.Popen(
    ["/bin/bash", "--noprofile", "--norc", sys.argv[1]],
    env=environment,
    start_new_session=True,
)
try:
    status = process.wait()
except KeyboardInterrupt:
    try:
        os.killpg(process.pid, signal.SIGTERM)
    except ProcessLookupError:
        pass
    process.wait()
    raise SystemExit(130)
raise SystemExit(status if status >= 0 else 128 - status)
PY
  exit $?
fi
/usr/bin/python3 -I - "$$" <<'PY'
import os
import sys

expected_session_leader = int(sys.argv[1])
if (
    os.getppid() != expected_session_leader
    or os.getsid(0) != expected_session_leader
    or os.getpgrp() != expected_session_leader
):
    raise SystemExit("release-test child is not its sacrificial session leader")
PY
# shellcheck source=../release/lib/token_process_cleanup.sh
source "$ROOT/scripts/release/lib/token_process_cleanup.sh"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/easysplat-release-test.XXXXXX")"
TMP_DIR="$(cd "$TMP_DIR" && pwd -P)"
release_tests_completed=0
release_test_build_root="$TMP_DIR/app-build"
default_export="$ROOT/build/Export"
release_fixture_root=""

tree_digest() {
  python3 - "$1" <<'PY'
import hashlib
import os
import stat
import re
import sys
from pathlib import Path

root = Path(sys.argv[1])
digest = hashlib.sha256()
if not os.path.lexists(root):
    digest.update(b"absent\0")
    print(digest.hexdigest())
    raise SystemExit(0)

paths = [root]
if root.is_dir() and not root.is_symlink():
    paths.extend(sorted(root.rglob("*"), key=lambda path: path.relative_to(root).as_posix()))

for path in paths:
    relative = "." if path == root else path.relative_to(root).as_posix()
    metadata = path.lstat()
    digest.update(relative.encode("utf-8", errors="surrogateescape"))
    digest.update(b"\0")
    digest.update(f"{metadata.st_mode}:{metadata.st_size}:{metadata.st_mtime_ns}".encode())
    digest.update(b"\0")
    if stat.S_ISLNK(metadata.st_mode):
        digest.update(os.readlink(path).encode("utf-8", errors="surrogateescape"))
    elif stat.S_ISREG(metadata.st_mode):
        with path.open("rb") as handle:
            while chunk := handle.read(1024 * 1024):
                digest.update(chunk)
print(digest.hexdigest())
PY
}

default_export_before="$(tree_digest "$default_export")"

release_and_drain_verifier_fixture() {
  local release_path="${verifier_process_release:-}"
  local pid_path="${verifier_process_pid:-}"
  local release_parent=""
  local fixture_pid=""
  local fixture_processes_alive=0
  local fixture_pid_file_seen=0
  local _

  if [ -n "$release_path" ]; then
    release_parent="${release_path%/*}"
    if [ -d "$release_parent" ]; then
      : >"$release_path" || return 1
    fi
  fi
  if [ -z "$pid_path" ] || [ "${verifier_process_fixture_active:-0}" -ne 1 ]; then
    return 0
  fi

  for _ in {1..3000}; do
    fixture_processes_alive=0
    if [ -s "$pid_path" ]; then
      fixture_pid_file_seen=1
      while IFS= read -r fixture_pid; do
        if [ -n "$fixture_pid" ] && kill -0 "$fixture_pid" 2>/dev/null; then
          fixture_processes_alive=1
          break
        fi
      done <"$pid_path"
    fi
    if [ "$fixture_pid_file_seen" -eq 1 ] \
        && [ "$fixture_processes_alive" -eq 0 ]; then
      return 0
    fi
    sleep 0.01
  done
  return 1
}

cleanup() {
  local status=$?
  local default_export_after
  local preserve_tmp=0
  trap - EXIT
  # A `set -u` abort leaves $? at zero, so a fatal error would otherwise leave
  # through this trap as a pass. Only the last line of the file clears this.
  if [ "$release_tests_completed" -ne 1 ] && [ "$status" -eq 0 ]; then
    echo "Release-script tests aborted before reaching the end of the suite." >&2
    status=1
  fi
  if ! release_and_drain_verifier_fixture; then
    echo "Detached verifier fixture did not drain; retained test state at $TMP_DIR." >&2
    status=1
    preserve_tmp=1
  fi
  if declare -F stop_broker_probe >/dev/null 2>&1; then
    stop_broker_probe || status=1
  fi
  default_export_after="$(tree_digest "$default_export")" || status=1
  if [ "$default_export_after" != "$default_export_before" ]; then
    echo "Release-script tests modified the default app export at $default_export" >&2
    status=1
  fi
  if [ -n "$release_fixture_root" ] && [ -e "$release_fixture_root" ]; then
    case "$release_fixture_root" in
      "$TMP_DIR"/*) ;;
      *)
        echo "Refusing to make a release fixture outside the test root writable." >&2
        status=1
        preserve_tmp=1
        ;;
    esac
    if [ "$preserve_tmp" -eq 0 ]; then
      if [ ! -d "$release_fixture_root" ] || [ -L "$release_fixture_root" ]; then
        echo "Generated release fixture changed type before cleanup." >&2
        status=1
        preserve_tmp=1
      else
        /bin/chmod -R u+w "$release_fixture_root" || {
          status=1
          preserve_tmp=1
        }
      fi
    fi
  fi
  if [ "$preserve_tmp" -eq 0 ]; then
    rm -rf "$TMP_DIR"
  fi
  exit "$status"
}
trap cleanup EXIT

if ! declare -F easysplat_audit_and_drain_verification_processes >/dev/null; then
  echo "Release process cleanup has no active residual-process audit." >&2
  exit 1
fi
process_audit_clean_token='easysplat-release-verify-10000000-0000-4000-8000-000000000001'
if [ "$(easysplat_audit_and_drain_verification_processes \
    "$process_audit_clean_token")" != clean ]; then
  echo "Residual-process audit did not prove a clean verifier boundary." >&2
  exit 1
fi
process_audit_invalid_status=0
process_audit_invalid_output="$TMP_DIR/process-audit-invalid.stdout"
process_audit_invalid_error="$TMP_DIR/process-audit-invalid.stderr"
easysplat_audit_and_drain_verification_processes invalid-token \
  >"$process_audit_invalid_output" 2>"$process_audit_invalid_error" \
  || process_audit_invalid_status=$?
if [ "$process_audit_invalid_status" -ne 2 ] \
  || [ -s "$process_audit_invalid_output" ]; then
  echo "Residual-process audit accepted an invalid ownership token." >&2
  exit 1
fi
process_audit_failure_token='easysplat-release-verify-10000000-0000-4000-8000-000000000009'
process_audit_failure_suffix="${process_audit_failure_token#easysplat-release-verify-}"
process_audit_failure_profile="(version 1) (allow default) \
(deny mach-lookup (global-name \"com.easysplat.releaseverify.${process_audit_failure_suffix}.deny\")) \
(allow mach-lookup (global-name \"com.easysplat.releaseverify.${process_audit_failure_suffix}.allow\"))"
process_audit_failure_output="$TMP_DIR/process-audit-failure.stdout"
process_audit_failure_error="$TMP_DIR/process-audit-failure.stderr"
process_audit_failure_status=0
EASYSPLAT_TEST_AUDIT_TOKEN="$process_audit_failure_token" \
EASYSPLAT_TEST_ROOT="$ROOT" \
  /usr/bin/sandbox-exec -p "$process_audit_failure_profile" \
  /bin/bash --noprofile --norc -c '
    source "$EASYSPLAT_TEST_ROOT/scripts/release/lib/token_process_cleanup.sh"
    easysplat_audit_and_drain_verification_processes "$EASYSPLAT_TEST_AUDIT_TOKEN"
  ' >"$process_audit_failure_output" 2>"$process_audit_failure_error" \
  || process_audit_failure_status=$?
if [ "$process_audit_failure_status" -ne 1 ] \
    || [ -s "$process_audit_failure_output" ] \
    || [ "$(wc -l <"$process_audit_failure_error" | tr -d ' ')" -ne 1 ] \
    || ! grep -Fxq \
      'Release-process audit could not prove exact-identity quiescence.' \
      "$process_audit_failure_error" \
    || grep -Fq "$process_audit_failure_token" "$process_audit_failure_error"; then
  echo "Residual-process audit did not fail closed with a generic inspection error." >&2
  exit 1
fi
(
  delayed_token='easysplat-release-verify-10000000-0000-4000-8000-000000000002'
  delayed_token_pid=""
  # Invoked through the EXIT trap for a failed fixture.
  # shellcheck disable=SC2329
  cleanup_delayed_token_process() {
    [ -z "$delayed_token_pid" ] \
      || kill -TERM "$delayed_token_pid" 2>/dev/null \
      || true
    [ -z "$delayed_token_pid" ] \
      || wait "$delayed_token_pid" 2>/dev/null \
      || true
  }
  trap cleanup_delayed_token_process EXIT
  (
    sleep 0.05
    EASYSPLAT_RELEASE_VERIFY_TOKEN="$delayed_token" \
      /usr/bin/python3 -c 'import time; time.sleep(0.3)'
  ) &
  delayed_token_pid=$!
  delayed_token_result="$(
    easysplat_audit_and_drain_verification_processes "$delayed_token"
  )"
  wait "$delayed_token_pid" 2>/dev/null || true
  delayed_token_pid=""
  trap - EXIT
  if [ "$delayed_token_result" != contained ]; then
    echo "Environment-token audit accepted an early empty sample." >&2
    exit 1
  fi
)

process_scan_token='easysplat-release-verify-00000000-0000-0000-0000-000000000001'
if easysplat_sandbox_marker_process_action signal \
    "$process_scan_token" TERM >/dev/null 2>&1 \
  || [ "$?" -ne 2 ]; then
  echo "Sandbox-marker inspection accepted a signaling action." >&2
  exit 1
fi
if easysplat_token_process_action signal \
    "$process_scan_token" KILL >/dev/null 2>&1 \
  || [ "$?" -ne 2 ]; then
  echo "Token inspection accepted a signaling action." >&2
  exit 1
fi
marker_scanner_source="$(declare -f easysplat_sandbox_marker_process_action)"
token_scanner_source="$(declare -f easysplat_token_process_action)"
if printf '%s\n%s\n' "$marker_scanner_source" "$token_scanner_source" \
    | grep -Eq 'os\.kill(pg)?\('; then
  echo "A residual-process scanner can still signal a sampled PID." >&2
  exit 1
fi
marker_cleanup_source="$(
  declare -f _easysplat_sandbox_marker_process_action
  declare -f easysplat_cleanup_sandbox_marker_processes
)"
for required_audit_cleanup_primitive in \
  TASK_AUDIT_TOKEN \
  KERN_PROCARGS2 \
  expected_assignment \
  known_owned \
  signal.SIGSTOP \
  signal.SIGKILL \
  sandbox_check_by_audit_token \
  proc_signal_with_audittoken; do
  if ! grep -Fq "$required_audit_cleanup_primitive" <<<"$marker_cleanup_source"; then
    echo "Sandbox-marker cleanup does not bind $required_audit_cleanup_primitive." >&2
    exit 1
  fi
done
if ! grep -Fq '3<<< "$token"' <<<"$marker_cleanup_source" \
    || grep -Fq '"$action" "$token"' <<<"$marker_cleanup_source"; then
  echo "Release-process audit exposed its ownership token in the inspector argv." >&2
  exit 1
fi
if grep -Eq 'os\.kill(pg)?\(' <<<"$marker_cleanup_source"; then
  echo "Sandbox-marker cleanup can still signal a sampled process identifier." >&2
  exit 1
fi
supervisor_source="$(declare -f easysplat_supervise_process_group)"
cleanup_source="$(declare -f easysplat_cleanup_supervised_process_group)"
if ! grep -Fq 'exec /usr/bin/python3' <<<"$supervisor_source"; then
  echo "The supervised background job is not the process-group controller." >&2
  exit 1
fi
if grep -Eq 'kill .*(-|--) "?-\$group_pid' <<<"$cleanup_source"; then
  echo "Shell cleanup can still signal a sampled process-group identifier." >&2
  exit 1
fi
if ! grep -Fq 'KQ_FILTER_PROC' <<<"$supervisor_source" \
  || ! grep -Fq 'KQ_NOTE_EXIT' <<<"$supervisor_source"; then
  echo "The controller does not observe leader exit without reaping it." >&2
  exit 1
fi
if grep -Fq 'signal.SIG_IGN' <<<"$supervisor_source"; then
  echo "The process-group anchor discards an early termination signal." >&2
  exit 1
fi
if ! /usr/bin/python3 - "$supervisor_source" <<'PY'
import sys

source = sys.argv[1]
main = source[source.index("try:\n    while not command_completed"):]
if "raise SystemExit(126)" in main:
    raise SystemExit(
        "The controller can exit while its owned process-group anchor is unreaped."
    )
PY
then
  exit 1
fi

cleanup_function_source="$TMP_DIR/release-cleanup-function.sh"
awk '/^cleanup\(\) \{/ { include = 1 } \
     /^trap cleanup EXIT/ { exit } \
     include { print }' \
  "$ROOT/scripts/release/verify_release.sh" >"$cleanup_function_source"
cleanup_preservation_root="$TMP_DIR/failed-cleanup-preservation"
cleanup_preservation_marker="$TMP_DIR/failed-cleanup-ownership-preserved"
mkdir -p \
  "$cleanup_preservation_root/app" \
  "$cleanup_preservation_root/e2e"
# The cleanup function is sourced dynamically and consumes every test seam.
# shellcheck disable=SC2034,SC2329
if (
  # shellcheck source=/dev/null
  source "$cleanup_function_source"
  cleanup_packaged_app_verification_processes() { return 1; }
  cleanup_release_verifier_processes() { return 1; }
  write_release_verification_status() {
    [ "$APP_WIRING_TOKEN" = app-token ] \
      && [ "$APP_WIRING_PID" = 23456 ] \
      && [ "$APP_WIRING_GROUP_FILE" = app-group ] \
      && [ "$E2E_VERIFIER_TOKEN" = e2e-token ] \
      && [ "$E2E_VERIFIER_SUPERVISOR_PID" = 12345 ] \
      && [ "$E2E_VERIFIER_GROUP_FILE" = e2e-group ] \
      && : >"$cleanup_preservation_marker"
  }
  preserve_release_verification_log() { return 0; }
  APP_WIRING_TOKEN=app-token
  APP_WIRING_PID=23456
  APP_WIRING_GROUP_FILE=app-group
  E2E_VERIFIER_TOKEN=e2e-token
  E2E_VERIFIER_SUPERVISOR_PID=12345
  E2E_VERIFIER_GROUP_FILE=e2e-group
  SMOKE_INSTALL_ROOT="$cleanup_preservation_root/app"
  E2E_DIR="$cleanup_preservation_root/e2e"
  MOUNT_ATTACHED=0
  MOUNT_DIR=""
  APP_WIRING_LOG=""
  EVIDENCE_DIR=""
  REMOTE_MANIFEST=""
  ALLOW_INCOMPLETE=0
  FINAL_SUCCESS_MESSAGE=""
  trap cleanup EXIT
  exit 0
) >/dev/null 2>&1; then
  echo "Release cleanup accepted failed process containment." >&2
  exit 1
fi
if [ ! -f "$cleanup_preservation_marker" ] \
  || [ ! -d "$cleanup_preservation_root/app" ] \
  || [ ! -d "$cleanup_preservation_root/e2e" ]; then
  echo "Release cleanup discarded ownership state after process cleanup failed." >&2
  exit 1
fi

unpreserved_packaged_root="$TMP_DIR/unpreserved-packaged-cleanup"
unpreserved_cleanup_error="$TMP_DIR/unpreserved-packaged-cleanup.stderr"
mkdir -p "$unpreserved_packaged_root/ReleaseVerificationHome/Documents/EasySplat Projects/Run.easysplatproj"
printf '%s\n' '{}' >"$unpreserved_packaged_root/ReleaseVerificationHome/release-verification-pipeline-passed.json"
# The cleanup function is sourced dynamically and consumes every test seam.
# shellcheck disable=SC2030,SC2034,SC2329
if (
  # shellcheck source=/dev/null
  source "$cleanup_function_source"
  cleanup_packaged_app_verification_processes() { return 0; }
  cleanup_release_verifier_processes() { return 0; }
  packaged_app_smoke_has_substantive_evidence() { return 0; }
  write_release_verification_status() { return 0; }
  preserve_release_verification_log() { return 0; }
  APP_WIRING_TOKEN=""
  APP_WIRING_PID=""
  APP_WIRING_GROUP_FILE=""
  E2E_VERIFIER_TOKEN=""
  E2E_VERIFIER_SUPERVISOR_PID=""
  E2E_VERIFIER_GROUP_FILE=""
  PACKAGED_APP_ATTESTATION_PRESERVED=0
  SMOKE_INSTALL_ROOT="$unpreserved_packaged_root"
  E2E_DIR=""
  MOUNT_ATTACHED=0
  MOUNT_DIR=""
  APP_WIRING_LOG=""
  EVIDENCE_DIR=""
  REMOTE_MANIFEST=""
  ALLOW_INCOMPLETE=0
  FINAL_SUCCESS_MESSAGE=""
  trap cleanup EXIT
  exit 1
) >/dev/null 2>"$unpreserved_cleanup_error"; then
  echo "Release cleanup converted an unpreserved packaged-attestation failure into success." >&2
  exit 1
fi
if [ ! -d "$unpreserved_packaged_root" ]; then
  echo "Release cleanup deleted packaged project evidence before attestation preservation." >&2
  exit 1
fi
grep -Fq 'retained packaged-app project evidence because attestation preservation did not complete' \
  "$unpreserved_cleanup_error"

python3 "$ROOT/scripts/toolchain/tests/test_generate_supply_chain_manifest.py"
python3 "$ROOT/scripts/toolchain/tests/test_da3_payload.py"
python3 "$ROOT/scripts/toolchain/tests/test_create_reproducible_zip.py"
python3 "$ROOT/scripts/toolchain/tests/test_local_launcher.py"
/usr/bin/python3 -I \
  "$ROOT/scripts/benchmark/tests/test_subject_isolation_release_gate.py"
/usr/bin/python3 -I "$ROOT/scripts/toolchain/tests/test_atomic_swap_install.py"
/usr/bin/python3 -I "$ROOT/scripts/toolchain/tests/test_colmap_build_supervisor.py"
/usr/bin/python3 -I "$ROOT/scripts/toolchain/tests/test_colmap_support_builder.py" \
  SourceContractTests ArchiveSafetyTests ReleaseArchiveMetadataTests AtomicPromotionTests \
  BuildLockSafetyTests
/usr/bin/python3 -I "$ROOT/scripts/toolchain/tests/test_ceres_builder.py"
/usr/bin/python3 -I "$ROOT/scripts/toolchain/tests/test_openimageio_builder.py"
/usr/bin/python3 -I "$ROOT/scripts/toolchain/tests/test_native_colmap_retriever.py" SourceContractTests
python3 "$ROOT/scripts/release/tests/test_verify_publication_bundle.py"
python3 "$ROOT/scripts/release/tests/test_release_policy_workflow.py"
python3 "$ROOT/scripts/release/tests/test_testflight_workflow.py"
/usr/bin/python3 -I \
  "$ROOT/scripts/release/tests/test_testflight_dogfood_evidence.py"
python3 "$ROOT/scripts/release/tests/test_finalize_signed_toolchain.py"
python3 "$ROOT/scripts/release/tests/test_notarize_artifact.py"
/usr/bin/python3 -I "$ROOT/scripts/release/tests/test_export_reviewed_source.py"
/usr/bin/python3 -I "$ROOT/scripts/release/tests/test_mas_release_evidence.py"
/usr/bin/python3 -I \
  "$ROOT/scripts/release/tests/test_validate_mas_provisioning_profile.py"
python3 "$ROOT/scripts/release/tests/test_upload_mas_package.py"
/usr/bin/python3 -I \
  "$ROOT/scripts/release/tests/test_release_reliability_fixtures.py"
python3 "$ROOT/scripts/release/tests/test_toolchain_authority_handoff.py"
python3 "$ROOT/scripts/release/tests/test_toolchain_publication.py"
python3 "$ROOT/scripts/release/tests/test_toolchain_benchmark_workflow.py"
python3 "$ROOT/scripts/release/tests/test_generate_release_fixture.py"
"$ROOT/scripts/release/tests/test_strict_semver.sh"

unsafe_toolchain_root="$TMP_DIR/unsafe-toolchain-root"
mkdir -p "$unsafe_toolchain_root"
printf '%s' 'preserve' >"$unsafe_toolchain_root/sentinel"
unsafe_toolchain_error="$TMP_DIR/unsafe-toolchain-root.stderr"
if "$ROOT/scripts/run.sh" \
  --fast \
  --toolchain-root "$unsafe_toolchain_root" \
  >/dev/null 2>"$unsafe_toolchain_error"; then
  echo "Local launcher accepted an unsafe destructive toolchain root." >&2
  exit 1
fi
grep -Fqi 'Refusing unsafe toolchain root' "$unsafe_toolchain_error"
test "$(cat "$unsafe_toolchain_root/sentinel")" = preserve

signature_fixture="$TMP_DIR/rewritten-macho"
cp "$(command -v rg)" "$signature_fixture"
chmod +x "$signature_fixture"
install_name_tool -add_rpath '@executable_path/../lib' "$signature_fixture"
/usr/bin/codesign --force --sign - --timestamp=none "$signature_fixture"
/usr/bin/codesign --verify --strict "$signature_fixture"
"$signature_fixture" --version >/dev/null

mock_xcodebuild="$TMP_DIR/mock-xcodebuild.sh"
cat >"$mock_xcodebuild" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

derived=""
if [ -n "${EASYSPLAT_TEST_XCODEBUILD_LOG:-}" ]; then
  printf '%s\n' "$*" >"$EASYSPLAT_TEST_XCODEBUILD_LOG"
fi
while [[ $# -gt 0 ]]; do
  case "$1" in
    -derivedDataPath)
      derived="$2"
      shift 2
      ;;
    *)
      shift
      ;;
  esac
done

mkdir -p "$derived/Build/Products/Release/EasySplat_EasySplatApp.bundle"
mock_source="$derived/mock-app.c"
cat >"$mock_source" <<'SOURCE'
int main(void) {
    return 0;
}
SOURCE
if [ "${EASYSPLAT_TEST_ENABLE_COVERAGE:-}" = "1" ]; then
  for index in $(jot 10000 1); do
    printf '__attribute__((noinline,used)) int coverage_fixture_%s(void) { return %s; }\n' \
      "$index" "$index" >>"$mock_source"
  done
fi
mock_object="$derived/mock-app.o"
build_mock_binary() {
  xcrun clang \
    "$@" \
    -arch "${EASYSPLAT_TEST_BINARY_ARCH:-arm64}" \
    -g \
    -c \
    "$mock_source" \
    -o "$mock_object"
  xcrun clang \
    "$@" \
    -arch "${EASYSPLAT_TEST_BINARY_ARCH:-arm64}" \
    "$mock_object" \
    -o "$derived/Build/Products/Release/EasySplatApp"
}
if [ "${EASYSPLAT_TEST_ENABLE_COVERAGE:-}" = "1" ]; then
  build_mock_binary -fprofile-instr-generate -fcoverage-mapping
else
  build_mock_binary
fi
xcrun dsymutil \
  "$derived/Build/Products/Release/EasySplatApp" \
  -o "$derived/Build/Products/Release/EasySplatApp.dSYM"
/usr/bin/codesign --force --sign - --timestamp=none \
  "$derived/Build/Products/Release/EasySplatApp"
printf '%s' 'DEFAULT_PROJECT_URL' >"$derived/Build/Products/Release/EasySplat_EasySplatApp.bundle/project_home_url.txt"
if [ -n "${EASYSPLAT_TEST_BUILD_WAIT_PATH:-}" ]; then
  : >"$EASYSPLAT_TEST_BUILD_WAIT_PATH.ready"
  while [ ! -e "$EASYSPLAT_TEST_BUILD_WAIT_PATH.release" ]; do
    sleep 0.05
  done
fi
EOF
chmod +x "$mock_xcodebuild"

project_before="$(cat "$ROOT/EasySplatApp/Resources/project_home_url.txt")"

project_url="https://example.com/EasySplat"
xcodebuild_log="$TMP_DIR/xcodebuild.log"

# The app embeds a toolchain tree rather than installing from an archive, so the
# fixture the build consumes is that tree.
toolchain_fixture_root="$TMP_DIR/bootstrap-toolchain"
python3 "$ROOT/scripts/release/tests/create_toolchain_fixture.py" "$toolchain_fixture_root"
toolchain_tree="$toolchain_fixture_root/core"
for required in bin/colmap bin/easysplat-train bin/default.metallib lib/libomp.dylib; do
  test -f "$toolchain_tree/$required"
done

if rg -n 'EASYSPLAT_MANIFEST_TOOL_BIN|MANIFEST_TOOL_BIN=' \
  "$ROOT/scripts/release/build_app.sh" "$ROOT/scripts/release/verify_release.sh" >/dev/null; then
  echo "Release scripts retain a verifier-bypass environment override." >&2
  exit 1
fi
if rg -n 'EASYSPLAT_RELEASE_HELPER_TEST_MODE|EASYSPLAT_SIGNING_HELPER_BIN' \
  "$ROOT/scripts/release/build_app.sh" "$ROOT/scripts/release/build_dmg.sh" >/dev/null; then
  echo "Signed release scripts retain a signing-helper bypass." >&2
  exit 1
fi
test "$(grep -Fc 'EASYSPLAT_NOTARY_TEST_MODE=0' "$ROOT/scripts/release/build_dmg.sh")" -eq 2
grep -Fq 'INPUT_SNAPSHOT_DIR=' "$ROOT/scripts/release/build_app.sh"
grep -Fq 'TOOLCHAIN_DIR' "$ROOT/scripts/release/build_app.sh"
grep -Fq 'export_reviewed_source.py' "$ROOT/scripts/release/build_app.sh"
grep -Fq 'cd "$BUILD_SOURCE_ROOT"' "$ROOT/scripts/release/build_app.sh"
grep -Fq 'install -d -m 0700 "$BUILD_SOURCE_ROOT/.swiftpm/xcode"' \
  "$ROOT/scripts/release/build_app.sh"
grep -Fq 'validate_mas_provisioning_profile.py' \
  "$ROOT/scripts/release/build_app.sh"
grep -Fq 'PROVISIONING_PROFILE="$VALIDATED_PROVISIONING_PROFILE"' \
  "$ROOT/scripts/release/build_app.sh"
grep -Fq 'BundledToolchainLocator(bundleURL: arguments.appBundle)' \
  "$ROOT/Tools/ReleaseVerifier/main.swift"
grep -Fq '"--input-manifest", "--input-root"' \
  "$ROOT/Tools/ReleaseVerifier/main.swift"
if grep -Fq '"--fixture"' "$ROOT/Tools/ReleaseVerifier/main.swift"; then
  echo "Independent release verification still accepts the inferred --fixture input." >&2
  exit 1
fi
grep -Fq 'rawArguments.first == "verify-packaged-project"' \
  "$ROOT/Tools/ReleaseVerifier/main.swift"
packaged_project_parser="$ROOT/Tools/ReleaseVerifierCore/PackagedProjectArguments.swift"
for packaged_option in \
  --input-manifest \
  --input-root \
  --expected-release-verification-token-sha256 \
  --expected-executable \
  --expected-executable-sha256 \
  --expected-executable-bytes \
  --evidence; do
  grep -Fq -- "\"$packaged_option\"" "$packaged_project_parser"
done
if grep -Fq -- '"--input"' "$packaged_project_parser"; then
  echo "Packaged-project verification still accepts the legacy --input option." >&2
  exit 1
fi
grep -Fq 'document.schemaVersion == 1' "$packaged_project_parser"
grep -Fq 'manifestURL: inputManifestURL' "$packaged_project_parser"
grep -Fq 'inputRoot: inputRootURL' "$packaged_project_parser"
grep -Fq 'expectedInput: initialInput.expectedInput' \
  "$ROOT/Tools/ReleaseVerifier/main.swift"
grep -Fq 'marker.schemaVersion == 3' \
  "$ROOT/Tools/ReleaseVerifierCore/PackagedProjectMarker.swift"
grep -Fq 'PackagedProjectMarkerCodec.decodeCanonical(data)' \
  "$ROOT/Tools/ReleaseVerifier/main.swift"
grep -Fq 'captureExpectedInputSnapshot(' \
  "$ROOT/Tools/ReleaseVerifier/main.swift" \
  "$ROOT/EasySplatApp/AppModel+ReleaseVerification.swift"
grep -Fq 'writePackagedProjectEvidence(' "$ROOT/Tools/ReleaseVerifier/main.swift"
grep -Fq 'Input manifest SHA-256:' \
  "$ROOT/Tools/ReleaseVerifier/main.swift"
grep -Fq 'try await validateBeforePublication()' \
  "$ROOT/Tools/ReleaseVerifier/main.swift"
grep -Fq 'hasNoASCIIControlCharacters' "$ROOT/Tools/ReleaseVerifier/main.swift"
grep -Fq 'ProjectArtifactValidator.validateFinishedProject(' \
  "$ROOT/Tools/ReleaseVerifier/main.swift"
packaged_smoke="$ROOT/scripts/release/lib/packaged_app_bootstrap_smoke.sh"
e2e_verifier_helpers="$ROOT/scripts/release/lib/e2e_verifier.sh"
grep -Fq 'run_packaged_app_bootstrap_smoke() {' "$packaged_smoke"
grep -Fq 'sandbox-exec' "$packaged_smoke"
grep -Fq 'CFFIXED_USER_HOME=' "$packaged_smoke"
grep -Fq -- '--easysplat-release-verify-bundled-pipeline' \
  "$packaged_smoke" "$ROOT/EasySplatApp/AppConfig.swift"
grep -Fq 'model = AppModel()' "$ROOT/EasySplatApp/AppDelegate.swift"
grep -Fq 'model.runBundledPipelineForReleaseVerification(' "$ROOT/EasySplatApp/AppDelegate.swift"
grep -Fq 'Darwin.exit(EXIT_FAILURE)' "$ROOT/EasySplatApp/AppDelegate.swift"
grep -Fq 'toolchainManager: ToolchainManaging = AppModel.makeDefaultToolchainManager()' \
  "$ROOT/EasySplatApp/AppModel.swift"
grep -Fq 'toolchainManager: ToolchainManaging = AppModel.makeDefaultToolchainManager()' \
  "$ROOT/EasySplatApp/AppModel.swift"
grep -Fq 'requireIntactCodeSignature' \
  "$ROOT/EasySplatCore/Sources/EasySplatCore/Tools/BundledToolchainLocator.swift"
grep -Fq '(deny default)' "$packaged_smoke"
grep -Fq '(deny network* (with send-signal SIGKILL))' "$packaged_smoke"
if grep -Fq '(allow process*)' "$packaged_smoke" "$e2e_verifier_helpers"; then
  echo "Release verification still grants unrestricted subprocess execution." >&2
  exit 1
fi
grep -Fq '"(allow process-fork)"' "$packaged_smoke" "$e2e_verifier_helpers"
grep -Fq 'f"(allow process-exec {process_filters})"' \
  "$packaged_smoke" "$e2e_verifier_helpers"
for launch_service in \
  com.apple.coreservices.launchservicesd \
  com.apple.lsd.mapdb \
  com.apple.lsd.modifydb \
  com.apple.runningboard \
  com.apple.runningboardd; do
  grep -Fq "(global-name \"$launch_service\")" \
    "$packaged_smoke" "$e2e_verifier_helpers"
done
grep -Fq 'DARWIN_USER_TEMP_DIR' "$packaged_smoke" "$e2e_verifier_helpers"
grep -Fq 'NSIRD_' "$packaged_smoke" "$e2e_verifier_helpers"
grep -Fq 'replacement_pattern' "$packaged_smoke" "$e2e_verifier_helpers"
grep -Fq 'allow file-write-create file-write-unlink' \
  "$packaged_smoke" "$e2e_verifier_helpers"
grep -Fq 'sandbox-exec -f "$sandbox_profile"' "$packaged_smoke"
grep -Fq 'APP_WIRING_LOG="$verifier_home/packaged-app-wiring.log"' \
  "$packaged_smoke"
grep -Fq -- '--input-manifest "$input_manifest"' \
  "$packaged_smoke"
grep -Fq -- '--input-root "$input_path" < /dev/null >"$APP_WIRING_LOG" 2>&1 &' \
  "$packaged_smoke"
grep -Fq 'Input manifest SHA-256' "$packaged_smoke"
grep -Fq 'inputManifestSHA256' \
  "$packaged_smoke" \
  "$ROOT/Tools/ReleaseVerifierCore/PackagedProjectMarker.swift" \
  "$ROOT/EasySplatApp/AppModel+ReleaseVerification.swift"
grep -Fq 'outside-write-probe' "$packaged_smoke"
grep -Fq 'release-verification-pipeline-passed.json' \
  "$packaged_smoke" "$ROOT/EasySplatApp/AppConfig.swift"
grep -Fq "/usr/bin/env -C \"\$verifier_home\" -i \\" "$packaged_smoke"
grep -Fq 'cleanup_packaged_app_verification_processes || true' \
  "$packaged_smoke"
grep -Fq '"$PACKAGED_PROJECT_VERIFIER" verify-packaged-project' \
  "$packaged_smoke"
grep -Fq 'PACKAGED_PROJECT_VERIFIER="$EXPECTED_RELEASE_RUNNER"' \
  "$ROOT/scripts/release/verify_release.sh"
grep -Fq 'Release-verifier app bundle does not match the sandboxed read-only root.' \
  "$e2e_verifier_helpers"
grep -Fq 'easysplat_wait_for_supervised_process_group' \
  "$packaged_smoke" "$e2e_verifier_helpers"
grep -Fq 'source "$ROOT/scripts/release/lib/e2e_verifier.sh"' \
  "$ROOT/scripts/release/verify_release.sh"
python3 - "$ROOT/EasySplatApp/AppDelegate.swift" \
  "$ROOT/EasySplatApp/AppModel+ReleaseVerification.swift" <<'PY'
import sys
from pathlib import Path

delegate = Path(sys.argv[1]).read_text(encoding="utf-8")
verification = Path(sys.argv[2]).read_text(encoding="utf-8")
release_block = delegate[delegate.index("if let configuration = releaseVerificationConfiguration"):]
release_block = release_block[:release_block.index("showMainWindow()")]
if "startFromPendingSelection" in release_block or "PipelineRunner(" in verification:
    raise SystemExit("Release verification bypasses AppModel's production project path.")
required = (
    "runBundledPipelineForReleaseVerification",
    "input: input,",
    "validatedFinishedOutputURL",
    "ProjectArtifactValidator.validatedPlyEvidence",
    "successMarkerURL",
    "guard let toolchain = await startProject",
)
if any(value not in release_block + verification for value in required):
    raise SystemExit("Release verification does not bind the packaged pipeline and marker.")
PY
if rg -n 'EASYSPLAT_TOOLCHAIN_MANIFEST_URL=|EASYSPLAT_TOOLCHAIN_PUBLIC_KEY_BASE64=|EASYSPLAT_LOCAL_TOOLCHAIN_ROOT=' \
  "$ROOT/scripts/release/verify_release.sh" >/dev/null; then
  echo "Packaged-app verification injects toolchain authority or a local toolchain override." >&2
  exit 1
fi

# Exercise the exact cached-closure attestation used before and after the
# network-denied release lane.
# shellcheck source=../release/lib/e2e_verifier.sh
# The generated helper path is checked separately.
# shellcheck disable=SC1091
source "$e2e_verifier_helpers"
fixture="$TMP_DIR/release-verifier-fixture"
release_fixture_root="$fixture"
/usr/bin/python3 -I "$ROOT/scripts/release/generate_release_fixture.py" generate \
  --output "$fixture" >/dev/null
evidence_helper_prefix="$TMP_DIR/release-evidence-functions.sh"
awk '/^release_fixture_attestation\(\)/ { include = 1 } \
     /^detach_disk_image_once\(\)/ { exit } \
     include { print }' \
  "$ROOT/scripts/release/verify_release.sh" >"$evidence_helper_prefix"
awk '/^canonical_path\(\)/ { include = 1 } \
     include { print } \
     include && /^}/ { exit }' \
  "$ROOT/scripts/release/verify_release.sh" >>"$evidence_helper_prefix"
large_log_root="$TMP_DIR/large-release-log-evidence"
large_raw_log="$TMP_DIR/large-release-verifier.raw"
mkdir -m 700 "$large_log_root"
python3 - "$large_raw_log" "$HOME" <<'PY'
import sys
from pathlib import Path

destination = Path(sys.argv[1])
home = sys.argv[2]
head = (
    f"HEAD {home}/Private/Secret Scene.mp4 "
    "https://person:password@example.com/run?token=secret "
    "file:///Users/release-audit/Secret%20Scene.mp4 "
    r"file:/Volumes/Private\ Disk/Scene.mov "
    r"/Users/release-audit/Secret\ Scene.mp4 "
    "/Volumes/Private%20Disk/Scene.mov "
    "123e4567-e89b-42d3-a456-426614174000\n"
).encode()
head_boundary = b"HEAD_BOUNDARY_SECRET" + (b"h" * (192 * 1024)) + b"\n"
tail_boundary = (b"t" * (1024 * 1024)) + b"TAIL_BOUNDARY_SECRET\n"
tail = b"\nTAIL release verifier evidence\n"
destination.write_bytes(head + head_boundary + tail_boundary + tail)
PY
sanitizer_started="$(python3 -c 'import time; print(time.monotonic_ns())')"
# The sourced helper consumes these test-scoped variables inside the subshell.
# shellcheck disable=SC2030,SC2034
(
  # shellcheck source=/dev/null
  source "$evidence_helper_prefix"
  EVIDENCE_DIR="$large_log_root"
  VERIFIED_EVIDENCE_DIRECTORY_IDENTITY=""
  bind_release_evidence_directory
  E2E_FIXTURE="$HOME/Private/Secret Scene.mp4"
  preserve_release_verification_log "$large_raw_log" "bounded.log"
  E2E_FIXTURE="$fixture"
  EXPECTED_VERSION="0.2.0"
  SOURCE_URL="https://example.com/EasySplat"
  SOURCE_COMMIT="deadbeef"
  VERIFIED_TOOLCHAIN_CLOSURE_SHA256="$(printf 'a%.0s' {1..64})"
  VERIFIED_FIXTURE_ATTESTATION=""
  VERIFIED_FIXTURE_MANIFEST_SHA256=""
  VERIFIED_FIXTURE_GENERATOR_SHA256=""
  VERIFIED_FIXTURE_CLOSURE_SHA256=""
  bind_release_fixture
  write_release_verification_status passed
)
sanitizer_finished="$(python3 -c 'import time; print(time.monotonic_ns())')"
python3 - "$sanitizer_started" "$sanitizer_finished" <<'PY'
import sys

elapsed = (int(sys.argv[2]) - int(sys.argv[1])) / 1_000_000_000
if not 0 < elapsed < 5:
    raise SystemExit(f"Release-evidence sanitization exceeded its five-second budget: {elapsed:.3f}s")
PY
bounded_log="$large_log_root/bounded.log"
grep -Fq 'HEAD ' "$bounded_log"
grep -Fq '[... middle truncated ...]' "$bounded_log"
grep -Fq 'TAIL release verifier evidence' "$bounded_log"
if rg -n 'Secret Scene|person:password|token=secret|123e4567|release-audit|Private(%20|\\ )Disk|BOUNDARY_SECRET|/Users/|/Volumes/' \
  "$bounded_log" >/dev/null; then
  echo "Bounded release evidence retained a private path, credential, token, UUID, or truncated-line fragment." >&2
  exit 1
fi
if [[ "$(stat -f '%Lp' "$bounded_log")" != "600" ]]; then
  echo "Bounded release evidence is not private." >&2
  exit 1
fi
semantic_fixture_evidence="$TMP_DIR/semantic-fixture-evidence"
semantic_fixture_attestation="$TMP_DIR/semantic-fixture-attestation.md"
mkdir -m 700 "$semantic_fixture_evidence"
printf '%s\n' \
  '# EasySplat Packaged-App Release Attestation' \
  'Schema: 1' \
  'Status: passed' \
  'Executable bytes: 4096' \
  "Executable SHA-256: $(printf 'b%.0s' {1..64})" \
  "Input path SHA-256: $(printf 'a%.0s' {1..64})" \
  "Private fixture path: $TMP_DIR/Executable" \
  >"$semantic_fixture_attestation"
(
  # shellcheck source=/dev/null
  source "$evidence_helper_prefix"
  EVIDENCE_DIR="$semantic_fixture_evidence"
  # The dynamically sourced preservation helper consumes this test seam.
  # shellcheck disable=SC2034
  E2E_FIXTURE="$TMP_DIR/Executable"
  preserve_release_verification_log \
    "$semantic_fixture_attestation" "packaged-app-attestation.md" required
)
preserved_semantic_attestation="$semantic_fixture_evidence/packaged-app-attestation.md"
grep -Fxq 'Status: passed' "$preserved_semantic_attestation"
grep -Fxq 'Schema: 1' "$preserved_semantic_attestation"
grep -Fxq 'Executable bytes: 4096' "$preserved_semantic_attestation"
grep -Fxq "Executable SHA-256: $(printf 'b%.0s' {1..64})" \
  "$preserved_semantic_attestation"
grep -Fxq 'Private fixture path: <verification-path>' \
  "$preserved_semantic_attestation"
if grep -Fq "$TMP_DIR/Executable" "$preserved_semantic_attestation"; then
  echo "Structured release evidence retained the private fixture path." >&2
  exit 1
fi
active_lane_root="$TMP_DIR/active-lane-evidence"
active_lane_work="$TMP_DIR/active-lane-work"
mkdir -m 700 "$active_lane_root" "$active_lane_work"
printf 'active /Users/private/Capture.mov?token=secret\n' >"$active_lane_work/console.raw"
printf 'diagnostic /Volumes/private/Project\n' >"$active_lane_work/diagnostic.md"
(
  # shellcheck source=/dev/null
  source "$evidence_helper_prefix"
  EVIDENCE_DIR="$active_lane_root"
  E2E_DIR="$active_lane_work"
  # The dynamically sourced helper consumes these active-lane test seams.
  # shellcheck disable=SC2034
  ACTIVE_LANE_NAME="bundled"
  # shellcheck disable=SC2034
  ACTIVE_LANE_RAW_LOG="$active_lane_work/console.raw"
  # shellcheck disable=SC2034
  ACTIVE_LANE_DIAGNOSTIC="$active_lane_work/diagnostic.md"
  preserve_active_release_verifier_evidence
)
test -s "$active_lane_root/bundled-console.log"
test -s "$active_lane_root/bundled-diagnostic.md"
if rg -n '/Users/|/Volumes/|token=secret' "$active_lane_root" >/dev/null; then
  echo "Active release lane retained unsanitized cancellation evidence." >&2
  exit 1
fi
grep -Fq 'Source commit: deadbeef' \
  "$large_log_root/release-verification-status.txt"
grep -Fq "Bundled toolchain closure SHA-256: $(printf 'a%.0s' {1..64})" \
  "$large_log_root/release-verification-status.txt"
fixture_attestation="$(/usr/bin/python3 -I \
  "$ROOT/scripts/release/generate_release_fixture.py" verify \
  --root "$fixture")"
fixture_manifest_sha256="$(python3 -c \
  'import json, sys; print(json.loads(sys.argv[1])["fixtureManifestSHA256"])' \
  "$fixture_attestation")"
fixture_generator_sha256="$(python3 -c \
  'import json, sys; print(json.loads(sys.argv[1])["generatorSHA256"])' \
  "$fixture_attestation")"
fixture_closure_sha256="$(python3 -c \
  'import json, sys; print(json.loads(sys.argv[1])["fixtureClosureSHA256"])' \
  "$fixture_attestation")"
grep -Fq "Release fixture manifest SHA-256: $fixture_manifest_sha256" \
  "$large_log_root/release-verification-status.txt"
grep -Fq "Release fixture generator SHA-256: $fixture_generator_sha256" \
  "$large_log_root/release-verification-status.txt"
grep -Fq "Release fixture closure SHA-256: $fixture_closure_sha256" \
  "$large_log_root/release-verification-status.txt"

missing_fixture_evidence="$TMP_DIR/release-status-missing-fixture"
missing_fixture_error="$TMP_DIR/release-status-missing-fixture.stderr"
mkdir -m 700 "$missing_fixture_evidence"
# Reproduce the original generated-helper path without silently substituting
# caller-provided fixture digests.
# shellcheck disable=SC2030,SC2034
if (
  # shellcheck source=/dev/null
  source "$evidence_helper_prefix"
  EVIDENCE_DIR="$missing_fixture_evidence"
  VERIFIED_EVIDENCE_DIRECTORY_IDENTITY=""
  bind_release_evidence_directory
  E2E_FIXTURE="$fixture"
  EXPECTED_VERSION="0.2.0"
  SOURCE_URL="https://example.com/EasySplat"
  SOURCE_COMMIT="deadbeef"
  VERIFIED_TOOLCHAIN_CLOSURE_SHA256="$(printf 'a%.0s' {1..64})"
  VERIFIED_FIXTURE_ATTESTATION=""
  unset VERIFIED_FIXTURE_MANIFEST_SHA256
  unset VERIFIED_FIXTURE_GENERATOR_SHA256
  unset VERIFIED_FIXTURE_CLOSURE_SHA256
  write_release_verification_status passed
) >/dev/null 2>"$missing_fixture_error"; then
  echo "Release status accepted a passed result without bound fixture provenance." >&2
  exit 1
fi
grep -Fq 'Release fixture provenance is not bound.' "$missing_fixture_error"
if grep -Fq 'unbound variable' "$missing_fixture_error"; then
  echo "Missing fixture provenance escaped as an unbound shell variable." >&2
  exit 1
fi
test ! -e "$missing_fixture_evidence/release-verification-status.txt"

forged_fixture_evidence="$TMP_DIR/release-status-forged-fixture"
forged_fixture_error="$TMP_DIR/release-status-forged-fixture.stderr"
mkdir -m 700 "$forged_fixture_evidence"
# shellcheck disable=SC2030,SC2034
if (
  # shellcheck source=/dev/null
  source "$evidence_helper_prefix"
  EVIDENCE_DIR="$forged_fixture_evidence"
  VERIFIED_EVIDENCE_DIRECTORY_IDENTITY=""
  bind_release_evidence_directory
  E2E_FIXTURE="$fixture"
  EXPECTED_VERSION="0.2.0"
  SOURCE_URL="https://example.com/EasySplat"
  SOURCE_COMMIT="deadbeef"
  VERIFIED_TOOLCHAIN_CLOSURE_SHA256="$(printf 'a%.0s' {1..64})"
  VERIFIED_FIXTURE_ATTESTATION=""
  VERIFIED_FIXTURE_MANIFEST_SHA256=""
  VERIFIED_FIXTURE_GENERATOR_SHA256=""
  VERIFIED_FIXTURE_CLOSURE_SHA256=""
  bind_release_fixture
  VERIFIED_FIXTURE_MANIFEST_SHA256="$(printf 'd%.0s' {1..64})"
  write_release_verification_status passed
) >/dev/null 2>"$forged_fixture_error"; then
  echo "Release status accepted fixture hashes that differ from the verified attestation." >&2
  exit 1
fi
grep -Fq 'Release fixture digests differ from the verified attestation.' \
  "$forged_fixture_error"
test ! -e "$forged_fixture_evidence/release-verification-status.txt"

authenticated_failed_evidence="$TMP_DIR/release-status-authenticated-failure"
mkdir -m 700 "$authenticated_failed_evidence"
# Failed evidence written after a rejected pass must use the authenticated
# attestation, not the mutable digest variables that caused the rejection.
# shellcheck disable=SC2030,SC2034
(
  # shellcheck source=/dev/null
  source "$evidence_helper_prefix"
  EVIDENCE_DIR="$authenticated_failed_evidence"
  VERIFIED_EVIDENCE_DIRECTORY_IDENTITY=""
  bind_release_evidence_directory
  E2E_FIXTURE="$fixture"
  EXPECTED_VERSION="0.2.0"
  SOURCE_URL="https://example.com/EasySplat"
  SOURCE_COMMIT="deadbeef"
  VERIFIED_TOOLCHAIN_CLOSURE_SHA256="$(printf 'a%.0s' {1..64})"
  VERIFIED_FIXTURE_ATTESTATION=""
  VERIFIED_FIXTURE_MANIFEST_SHA256=""
  VERIFIED_FIXTURE_GENERATOR_SHA256=""
  VERIFIED_FIXTURE_CLOSURE_SHA256=""
  bind_release_fixture
  VERIFIED_FIXTURE_MANIFEST_SHA256="$(printf 'd%.0s' {1..64})"
  write_release_verification_status failed
)
authenticated_failed_status="$authenticated_failed_evidence/release-verification-status.txt"
grep -Fxq 'Status: failed' "$authenticated_failed_status"
grep -Fxq "Release fixture manifest SHA-256: $fixture_manifest_sha256" \
  "$authenticated_failed_status"
if grep -Fq "Release fixture manifest SHA-256: $(printf 'd%.0s' {1..64})" \
    "$authenticated_failed_status"; then
  echo "Failed release evidence trusted a mutable fixture digest variable." >&2
  exit 1
fi

fake_python_root="$TMP_DIR/release-status-fake-python"
fake_python_marker="$TMP_DIR/release-status-fake-python.invoked"
path_safe_evidence="$TMP_DIR/release-status-path-safe"
mkdir -m 700 "$fake_python_root" "$path_safe_evidence"
cat >"$fake_python_root/python3" <<'EOF'
#!/bin/sh
: >"$EASYSPLAT_FAKE_PYTHON_MARKER"
exit 93
EOF
chmod +x "$fake_python_root/python3"
EASYSPLAT_TEST_EVIDENCE_HELPER="$evidence_helper_prefix" \
EASYSPLAT_TEST_EVIDENCE_DIR="$path_safe_evidence" \
EASYSPLAT_FAKE_PYTHON_MARKER="$fake_python_marker" \
  /usr/bin/env PATH="$fake_python_root:/usr/bin:/bin" \
  /bin/bash --noprofile --norc <<'BASH'
  set -euo pipefail
  # shellcheck source=/dev/null
  source "$EASYSPLAT_TEST_EVIDENCE_HELPER"
  EVIDENCE_DIR="$EASYSPLAT_TEST_EVIDENCE_DIR"
  VERIFIED_EVIDENCE_DIRECTORY_IDENTITY=""
  bind_release_evidence_directory
  EXPECTED_VERSION="0.2.0"
  SOURCE_URL="https://example.com/EasySplat"
  SOURCE_COMMIT="deadbeef"
  VERIFIED_TOOLCHAIN_CLOSURE_SHA256="$(printf 'a%.0s' {1..64})"
  VERIFIED_FIXTURE_ATTESTATION=""
  write_release_verification_status failed
BASH
test ! -e "$fake_python_marker"
grep -Fxq 'Status: failed' "$path_safe_evidence/release-verification-status.txt"

acl_bound_evidence="$TMP_DIR/release-status-acl-at-binding"
acl_bound_error="$TMP_DIR/release-status-acl-at-binding.stderr"
mkdir -m 700 "$acl_bound_evidence"
/bin/chmod +a \
  'everyone allow read,write,execute,append,delete,file_inherit,directory_inherit' \
  "$acl_bound_evidence"
if (
  # shellcheck source=/dev/null
  source "$evidence_helper_prefix"
  EVIDENCE_DIR="$acl_bound_evidence"
  VERIFIED_EVIDENCE_DIRECTORY_IDENTITY=""
  bind_release_evidence_directory
) >/dev/null 2>"$acl_bound_error"; then
  echo "Release evidence accepted an extended ACL at directory binding." >&2
  exit 1
fi
grep -Fxq 'Release-verification evidence directory cannot have an extended ACL.' \
  "$acl_bound_error"
test ! -e "$acl_bound_evidence/release-verification-status.txt"
/bin/chmod -N "$acl_bound_evidence"

acl_added_evidence="$TMP_DIR/release-status-acl-after-binding"
acl_added_error="$TMP_DIR/release-status-acl-after-binding.stderr"
mkdir -m 700 "$acl_added_evidence"
# shellcheck disable=SC2030,SC2034
if (
  # shellcheck source=/dev/null
  source "$evidence_helper_prefix"
  EVIDENCE_DIR="$acl_added_evidence"
  VERIFIED_EVIDENCE_DIRECTORY_IDENTITY=""
  bind_release_evidence_directory
  /bin/chmod +a \
    'everyone allow read,write,execute,append,delete,file_inherit,directory_inherit' \
    "$acl_added_evidence"
  EXPECTED_VERSION="0.2.0"
  SOURCE_URL="https://example.com/EasySplat"
  SOURCE_COMMIT="deadbeef"
  VERIFIED_TOOLCHAIN_CLOSURE_SHA256="$(printf 'a%.0s' {1..64})"
  VERIFIED_FIXTURE_ATTESTATION=""
  write_release_verification_status failed
) >/dev/null 2>"$acl_added_error"; then
  echo "Release evidence accepted an extended ACL added after binding." >&2
  exit 1
fi
grep -Fxq 'Release-verification evidence directory gained an extended ACL.' \
  "$acl_added_error"
test ! -e "$acl_added_evidence/release-verification-status.txt"
/bin/chmod -N "$acl_added_evidence"

invalid_status_evidence="$TMP_DIR/release-status-invalid-value"
invalid_status_error="$TMP_DIR/release-status-invalid-value.stderr"
mkdir -m 700 "$invalid_status_evidence"
# shellcheck disable=SC2030,SC2034
if (
  # shellcheck source=/dev/null
  source "$evidence_helper_prefix"
  EVIDENCE_DIR="$invalid_status_evidence"
  VERIFIED_EVIDENCE_DIRECTORY_IDENTITY=""
  bind_release_evidence_directory
  EXPECTED_VERSION="0.2.0"
  SOURCE_URL="https://example.com/EasySplat"
  SOURCE_COMMIT="deadbeef"
  VERIFIED_TOOLCHAIN_CLOSURE_SHA256="$(printf 'a%.0s' {1..64})"
  VERIFIED_FIXTURE_ATTESTATION=""
  write_release_verification_status 'passed'$'\n''Status: forged'
) >/dev/null 2>"$invalid_status_error"; then
  echo "Release evidence accepted an invalid status value." >&2
  exit 1
fi
grep -Fxq 'Release verification status is invalid.' "$invalid_status_error"
test ! -e "$invalid_status_evidence/release-verification-status.txt"

injected_field_evidence="$TMP_DIR/release-status-injected-field"
injected_field_error="$TMP_DIR/release-status-injected-field.stderr"
mkdir -m 700 "$injected_field_evidence"
# shellcheck disable=SC2030,SC2034
if (
  # shellcheck source=/dev/null
  source "$evidence_helper_prefix"
  EVIDENCE_DIR="$injected_field_evidence"
  VERIFIED_EVIDENCE_DIRECTORY_IDENTITY=""
  bind_release_evidence_directory
  EXPECTED_VERSION="0.2.0"
  SOURCE_URL='https://example.com/EasySplat'$'\n''Status: passed'
  SOURCE_COMMIT="deadbeef"
  VERIFIED_TOOLCHAIN_CLOSURE_SHA256="$(printf 'a%.0s' {1..64})"
  VERIFIED_FIXTURE_ATTESTATION=""
  write_release_verification_status failed
) >/dev/null 2>"$injected_field_error"; then
  echo "Release evidence accepted a control character in a provenance field." >&2
  exit 1
fi
grep -Fxq 'Release verification evidence contains a control character.' \
  "$injected_field_error"
test ! -e "$injected_field_evidence/release-verification-status.txt"

unicode_line_field_evidence="$TMP_DIR/release-status-unicode-line-field"
unicode_line_field_error="$TMP_DIR/release-status-unicode-line-field.stderr"
mkdir -m 700 "$unicode_line_field_evidence"
# shellcheck disable=SC2030,SC2034
if (
  # shellcheck source=/dev/null
  source "$evidence_helper_prefix"
  EVIDENCE_DIR="$unicode_line_field_evidence"
  VERIFIED_EVIDENCE_DIRECTORY_IDENTITY=""
  bind_release_evidence_directory
  EXPECTED_VERSION="0.2.0"
  unicode_line_separator="$(printf '\302\205')"
  if [ "$(printf '%s' "$unicode_line_separator" | /usr/bin/xxd -p)" != c285 ]; then
    echo "Unicode line-separator fixture has the wrong UTF-8 bytes." >&2
    exit 1
  fi
  SOURCE_URL="https://example.com/EasySplat${unicode_line_separator}Status: passed"
  SOURCE_COMMIT="deadbeef"
  VERIFIED_TOOLCHAIN_CLOSURE_SHA256="$(printf 'a%.0s' {1..64})"
  VERIFIED_FIXTURE_ATTESTATION=""
  write_release_verification_status failed
) >/dev/null 2>"$unicode_line_field_error"; then
  echo "Release evidence accepted a Unicode line separator in a provenance field." >&2
  exit 1
fi
grep -Fxq 'Release verification evidence contains a control character.' \
  "$unicode_line_field_error"
test ! -e "$unicode_line_field_evidence/release-verification-status.txt"

unbound_attestation_evidence="$TMP_DIR/release-status-unbound-attestation"
unbound_attestation_error="$TMP_DIR/release-status-unbound-attestation.stderr"
mkdir -m 700 "$unbound_attestation_evidence"
# shellcheck disable=SC2030,SC2034
if (
  # shellcheck source=/dev/null
  source "$evidence_helper_prefix"
  EVIDENCE_DIR="$unbound_attestation_evidence"
  VERIFIED_EVIDENCE_DIRECTORY_IDENTITY=""
  bind_release_evidence_directory
  EXPECTED_VERSION="0.2.0"
  SOURCE_URL="https://example.com/EasySplat"
  SOURCE_COMMIT="deadbeef"
  VERIFIED_TOOLCHAIN_CLOSURE_SHA256="$(printf 'a%.0s' {1..64})"
  VERIFIED_FIXTURE_ATTESTATION="$fixture_attestation"
  write_release_verification_status failed
) >/dev/null 2>"$unbound_attestation_error"; then
  echo "Failed release evidence accepted attestation text that was never bound." >&2
  exit 1
fi
grep -Fxq 'Release fixture provenance attestation was not bound by the verifier.' \
  "$unbound_attestation_error"
test ! -e "$unbound_attestation_evidence/release-verification-status.txt"

replaced_evidence="$TMP_DIR/release-status-replaced-directory"
replaced_evidence_original="$TMP_DIR/release-status-replaced-directory.original"
replaced_evidence_error="$TMP_DIR/release-status-replaced-directory.stderr"
mkdir -m 700 "$replaced_evidence"
# shellcheck disable=SC2030,SC2034
if (
  # shellcheck source=/dev/null
  source "$evidence_helper_prefix"
  EVIDENCE_DIR="$replaced_evidence"
  VERIFIED_EVIDENCE_DIRECTORY_IDENTITY=""
  bind_release_evidence_directory
  mv "$replaced_evidence" "$replaced_evidence_original"
  mkdir -m 700 "$replaced_evidence"
  EXPECTED_VERSION="0.2.0"
  SOURCE_URL="https://example.com/EasySplat"
  SOURCE_COMMIT="deadbeef"
  VERIFIED_TOOLCHAIN_CLOSURE_SHA256="$(printf 'a%.0s' {1..64})"
  VERIFIED_FIXTURE_ATTESTATION=""
  write_release_verification_status failed
) >/dev/null 2>"$replaced_evidence_error"; then
  echo "Release status followed a replacement evidence directory." >&2
  exit 1
fi
grep -Fxq 'Release-verification evidence directory changed after binding.' \
  "$replaced_evidence_error"
test ! -e "$replaced_evidence/release-verification-status.txt"

symlinked_evidence="$TMP_DIR/release-status-symlinked-directory"
symlinked_evidence_original="$TMP_DIR/release-status-symlinked-directory.original"
symlinked_evidence_target="$TMP_DIR/release-status-symlinked-directory.target"
symlinked_evidence_error="$TMP_DIR/release-status-symlinked-directory.stderr"
mkdir -m 700 "$symlinked_evidence" "$symlinked_evidence_target"
# shellcheck disable=SC2030,SC2034
if (
  # shellcheck source=/dev/null
  source "$evidence_helper_prefix"
  EVIDENCE_DIR="$symlinked_evidence"
  VERIFIED_EVIDENCE_DIRECTORY_IDENTITY=""
  bind_release_evidence_directory
  mv "$symlinked_evidence" "$symlinked_evidence_original"
  ln -s "$symlinked_evidence_target" "$symlinked_evidence"
  EXPECTED_VERSION="0.2.0"
  SOURCE_URL="https://example.com/EasySplat"
  SOURCE_COMMIT="deadbeef"
  VERIFIED_TOOLCHAIN_CLOSURE_SHA256="$(printf 'a%.0s' {1..64})"
  VERIFIED_FIXTURE_ATTESTATION=""
  write_release_verification_status failed
) >/dev/null 2>"$symlinked_evidence_error"; then
  echo "Release status followed a symlinked evidence directory." >&2
  exit 1
fi
grep -Fxq 'Release-verification evidence directory changed after binding.' \
  "$symlinked_evidence_error"
test ! -e "$symlinked_evidence_target/release-verification-status.txt"

status_symlink_evidence="$TMP_DIR/release-status-symlink-path"
status_symlink_target="$TMP_DIR/release-status-symlink-target.txt"
status_symlink_error="$TMP_DIR/release-status-symlink-path.stderr"
mkdir -m 700 "$status_symlink_evidence"
printf '%s\n' 'preserve-target' >"$status_symlink_target"
# shellcheck disable=SC2030,SC2034
if (
  # shellcheck source=/dev/null
  source "$evidence_helper_prefix"
  EVIDENCE_DIR="$status_symlink_evidence"
  VERIFIED_EVIDENCE_DIRECTORY_IDENTITY=""
  bind_release_evidence_directory
  ln -s "$status_symlink_target" \
    "$status_symlink_evidence/release-verification-status.txt"
  EXPECTED_VERSION="0.2.0"
  SOURCE_URL="https://example.com/EasySplat"
  SOURCE_COMMIT="deadbeef"
  VERIFIED_TOOLCHAIN_CLOSURE_SHA256="$(printf 'a%.0s' {1..64})"
  VERIFIED_FIXTURE_ATTESTATION=""
  write_release_verification_status failed
) >/dev/null 2>"$status_symlink_error"; then
  echo "Release status replaced a pre-existing status path." >&2
  exit 1
fi
grep -Fxq 'Release verification status path already exists.' "$status_symlink_error"
grep -Fxq 'preserve-target' "$status_symlink_target"

tampered_fixture="$TMP_DIR/release-status-tampered-fixture"
tampered_fixture_evidence="$TMP_DIR/release-status-tampered-fixture-evidence"
tampered_fixture_error="$TMP_DIR/release-status-tampered-fixture.stderr"
/usr/bin/ditto "$fixture" "$tampered_fixture"
mkdir -m 700 "$tampered_fixture_evidence"
tampered_fixture_status=0
# The cleanup function reaches these test seams dynamically from the EXIT trap.
# shellcheck disable=SC2030,SC2034,SC2329
(
  # shellcheck source=/dev/null
  source "$evidence_helper_prefix"
  # shellcheck source=/dev/null
  source "$cleanup_function_source"
  cleanup_packaged_app_verification_processes() { return 0; }
  cleanup_release_verifier_processes() { return 0; }
  preserve_active_release_verifier_evidence() { return 0; }
  packaged_app_smoke_has_substantive_evidence() { return 1; }
  preserve_release_verification_log() { return 0; }
  EVIDENCE_DIR="$tampered_fixture_evidence"
  VERIFIED_EVIDENCE_DIRECTORY_IDENTITY=""
  bind_release_evidence_directory
  E2E_FIXTURE="$tampered_fixture"
  EXPECTED_VERSION="0.2.0"
  SOURCE_URL="https://example.com/EasySplat"
  SOURCE_COMMIT="deadbeef"
  VERIFIED_TOOLCHAIN_CLOSURE_SHA256="$(printf 'a%.0s' {1..64})"
  VERIFIED_FIXTURE_ATTESTATION=""
  VERIFIED_FIXTURE_MANIFEST_SHA256=""
  VERIFIED_FIXTURE_GENERATOR_SHA256=""
  VERIFIED_FIXTURE_CLOSURE_SHA256=""
  bind_release_fixture
  original_fixture_manifest_sha256="$(
    /usr/bin/shasum -a 256 "$tampered_fixture/fixture-manifest.json" | awk '{print $1}'
  )"
  chmod u+w "$tampered_fixture/fixture-manifest.json"
  printf '\n' >>"$tampered_fixture/fixture-manifest.json"
  tampered_fixture_manifest_sha256="$(
    /usr/bin/shasum -a 256 "$tampered_fixture/fixture-manifest.json" | awk '{print $1}'
  )"
  if [ "$tampered_fixture_manifest_sha256" = "$original_fixture_manifest_sha256" ]; then
    echo "Fixture-manifest tamper did not change its SHA-256." >&2
    exit 1
  fi
  SMOKE_INSTALL_ROOT=""
  E2E_DIR=""
  MOUNT_ATTACHED=0
  MOUNT_DIR=""
  APP_WIRING_LOG=""
  REMOTE_MANIFEST=""
  ALLOW_INCOMPLETE=0
  FINAL_SUCCESS_MESSAGE="must-not-print"
  trap cleanup EXIT
  exit 0
) >/dev/null 2>"$tampered_fixture_error" || tampered_fixture_status=$?
if [ "$tampered_fixture_status" -eq 0 ]; then
  echo "Release status accepted a fixture manifest changed after binding." >&2
  exit 1
fi
grep -Fq 'The generated release fixture changed during verification.' \
  "$tampered_fixture_error"
grep -Fq 'error: could not preserve release verification status.' \
  "$tampered_fixture_error"
tampered_fixture_status_file="$tampered_fixture_evidence/release-verification-status.txt"
grep -Fxq 'Status: failed' "$tampered_fixture_status_file"
grep -Fxq "Release fixture manifest SHA-256: $fixture_manifest_sha256" \
  "$tampered_fixture_status_file"
chmod -R u+w "$tampered_fixture"

missing_signature_evidence="$TMP_DIR/release-status-missing-signature"
missing_signature_error="$TMP_DIR/release-status-missing-signature.stderr"
mkdir -m 700 "$missing_signature_evidence"
# The sourced helper consumes these test-scoped variables inside the subshell.
# shellcheck disable=SC2030,SC2034
if (
  # shellcheck source=/dev/null
  source "$evidence_helper_prefix"
  EVIDENCE_DIR="$missing_signature_evidence"
  VERIFIED_EVIDENCE_DIRECTORY_IDENTITY=""
  bind_release_evidence_directory
  E2E_FIXTURE="$fixture"
  EXPECTED_VERSION="0.2.0"
  SOURCE_URL="https://example.com/EasySplat"
  SOURCE_COMMIT="deadbeef"
  # The fixture provenance binds, so the refusal has to come from the missing
  # toolchain closure digest rather than from the earlier shell guard.
  VERIFIED_TOOLCHAIN_CLOSURE_SHA256=""
  VERIFIED_FIXTURE_ATTESTATION=""
  VERIFIED_FIXTURE_MANIFEST_SHA256=""
  VERIFIED_FIXTURE_GENERATOR_SHA256=""
  VERIFIED_FIXTURE_CLOSURE_SHA256=""
  bind_release_fixture
  write_release_verification_status passed
) >/dev/null 2>"$missing_signature_error"; then
  echo "Release status accepted a passed result without signature provenance." >&2
  exit 1
fi
grep -Fq 'Successful release evidence is missing source, toolchain, or fixture provenance.' \
  "$missing_signature_error"
test ! -e "$missing_signature_evidence/release-verification-status.txt"

captured_lane_root="$TMP_DIR/captured-release-lane"
captured_lane_evidence="$TMP_DIR/captured-release-evidence"
mkdir -m 700 "$captured_lane_evidence"
# The captured helper invokes the test seam by name.
# shellcheck disable=SC2030,SC2034,SC2329
if (
  # shellcheck source=/dev/null
  source "$evidence_helper_prefix"
  E2E_DIR="$TMP_DIR/captured-release-work"
  EVIDENCE_DIR="$captured_lane_evidence"
  run_release_verifier() {
    mkdir -p "$captured_lane_root/work"
    printf '%s\n' "diagnostic $HOME/Private/Scene.mov" > \
      "$captured_lane_root/work/diagnostic.md"
    printf '%s\n' "console file:///Users/release-audit/Scene.mov"
    return 17
  }
  run_captured_release_verifier captured "$captured_lane_root" ignored
); then
  echo "Captured release lane discarded its verifier failure status." >&2
  exit 1
else
  captured_lane_status=$?
fi
if [ "$captured_lane_status" -ne 17 ]; then
  echo "Captured release lane returned $captured_lane_status instead of the verifier status." >&2
  exit 1
fi
grep -Fq 'diagnostic <verification-path>' "$captured_lane_evidence/captured-diagnostic.md"
if rg -n '/Users/|release-audit' "$captured_lane_evidence" >/dev/null; then
  echo "Captured release-lane evidence retained a private path." >&2
  exit 1
fi
for captured_file in \
  "$captured_lane_evidence/captured-console.log" \
  "$captured_lane_evidence/captured-diagnostic.md"; do
  if [[ "$(stat -f '%Lp' "$captured_file")" != "600" ]]; then
    echo "Captured release-lane evidence is not private: $captured_file" >&2
    exit 1
  fi
done

missing_diagnostic_evidence="$TMP_DIR/missing-release-diagnostic-evidence"
mkdir -m 700 "$missing_diagnostic_evidence"
# The captured helper invokes the test seam by name.
# shellcheck disable=SC2030,SC2034,SC2329
if (
  # shellcheck source=/dev/null
  source "$evidence_helper_prefix"
  E2E_DIR="$TMP_DIR/missing-release-diagnostic-work"
  EVIDENCE_DIR="$missing_diagnostic_evidence"
  run_release_verifier() { printf '%s\n' "completed without diagnostics"; }
  run_captured_release_verifier missing-diagnostic \
    "$TMP_DIR/missing-release-diagnostic-lane" ignored
) >/dev/null 2>&1; then
  echo "Captured release lane accepted missing required diagnostics." >&2
  exit 1
fi
test -s "$missing_diagnostic_evidence/missing-diagnostic-console.log"
test ! -e "$missing_diagnostic_evidence/missing-diagnostic-diagnostic.md"

authenticated_lane_evidence="$TMP_DIR/authenticated-release-lane-evidence"
authenticated_lane_output="$TMP_DIR/authenticated-release-lane-output.ply"
mkdir -m 700 "$authenticated_lane_evidence"
printf '%s\n' \
  'ply' \
  'format ascii 1.0' \
  'element vertex 1' \
  'property float x' \
  'property float y' \
  'property float z' \
  'end_header' \
  '0 0 0' >"$authenticated_lane_output"
chmod 600 "$authenticated_lane_output"
# The captured helper invokes the test seam by name.
# shellcheck disable=SC2030,SC2034,SC2329
(
  # shellcheck source=/dev/null
  source "$evidence_helper_prefix"
  E2E_DIR="$TMP_DIR/authenticated-release-lane-work"
  EVIDENCE_DIR="$authenticated_lane_evidence"
  VERIFIED_TOOLCHAIN_CLOSURE_SHA256="$(printf 'a%.0s' {1..64})"
  run_release_verifier() {
    local diagnostic="$TMP_DIR/authenticated-release-lane/work/diagnostic.md"
    local output_bytes
    local output_digest
    mkdir -p "$(dirname "$diagnostic")"
    output_bytes="$(wc -c <"$authenticated_lane_output" | tr -d '[:space:]')"
    output_digest="$(shasum -a 256 "$authenticated_lane_output" | awk '{ print $1 }')"
    cat >"$diagnostic" <<EOF
# EasySplat Release Verification Evidence
Status: passed
Integrity policy: signedAppBundle
Installed closure SHA-256: $(printf 'e%.0s' {1..64})
Installation identity SHA-256: $(printf 'f%.0s' {1..64})
Installed component: bundled-helpers $(printf '1%.0s' {1..64})
Installed capabilities: runtime.core, geometry.colmap, training.msplat
Output bytes: $output_bytes
Output vertices: 1
Output format: ascii
Output SHA-256: $output_digest
EOF
    chmod 600 "$diagnostic"
    printf '%s\n' "authenticated lane completed"
  }
  run_captured_release_verifier bundled \
    "$TMP_DIR/authenticated-release-lane" "$authenticated_lane_output" ignored
)
grep -Fq 'Integrity policy: signedAppBundle' \
  "$authenticated_lane_evidence/bundled-diagnostic.md"

preserved_lane_evidence="$TMP_DIR/preserved-release-lane-evidence"
mkdir -m 700 "$preserved_lane_evidence"
# The wrapper mutates the verifier-owned source only after the uploadable copy
# is durable. The lane must authenticate the exact preserved evidence.
# shellcheck disable=SC2030,SC2034,SC2329
(
  # shellcheck source=/dev/null
  source "$evidence_helper_prefix"
  eval "$(declare -f preserve_release_verification_log \
    | sed '1s/preserve_release_verification_log/preserve_release_verification_log_original/')"
  preserve_release_verification_log() {
    preserve_release_verification_log_original "$@" || return
    if [ "$2" = "bundled-diagnostic.md" ]; then
      sed -i '' \
        's/^Integrity policy: .*/Integrity policy: source-mutated-after-preservation/' \
        "$1"
    fi
  }
  E2E_DIR="$TMP_DIR/preserved-release-lane-work"
  EVIDENCE_DIR="$preserved_lane_evidence"
  VERIFIED_TOOLCHAIN_CLOSURE_SHA256="$(printf 'a%.0s' {1..64})"
  run_release_verifier() {
    local diagnostic="$TMP_DIR/preserved-release-lane/work/diagnostic.md"
    mkdir -p "$(dirname "$diagnostic")"
    cp "$TMP_DIR/authenticated-release-lane/work/diagnostic.md" "$diagnostic"
    chmod 600 "$diagnostic"
  }
  run_captured_release_verifier bundled \
    "$TMP_DIR/preserved-release-lane" "$authenticated_lane_output" ignored
)
grep -Fq "Integrity policy: signedAppBundle" \
  "$preserved_lane_evidence/bundled-diagnostic.md"

tampered_lane_evidence="$TMP_DIR/tampered-release-lane-evidence"
mkdir -m 700 "$tampered_lane_evidence"
# The captured helper invokes the test seam by name.
# shellcheck disable=SC2030,SC2034,SC2329
if (
  # shellcheck source=/dev/null
  source "$evidence_helper_prefix"
  E2E_DIR="$TMP_DIR/tampered-release-lane-work"
  EVIDENCE_DIR="$tampered_lane_evidence"
  VERIFIED_TOOLCHAIN_CLOSURE_SHA256="$(printf 'a%.0s' {1..64})"
  run_release_verifier() {
    local diagnostic="$TMP_DIR/tampered-release-lane/work/diagnostic.md"
    mkdir -p "$(dirname "$diagnostic")"
    sed 's/^Integrity policy: .*/Integrity policy: incorrect/' \
      "$TMP_DIR/authenticated-release-lane/work/diagnostic.md" >"$diagnostic"
    chmod 600 "$diagnostic"
    printf '%s\n' "tampered lane completed"
  }
  run_captured_release_verifier bundled \
    "$TMP_DIR/tampered-release-lane" "$authenticated_lane_output" ignored
) >/dev/null 2>&1; then
  echo "Captured release lane accepted evidence for a different manifest signature." >&2
  exit 1
fi
test -s "$tampered_lane_evidence/bundled-console.log"
test -s "$tampered_lane_evidence/bundled-diagnostic.md"

mutated_output="$TMP_DIR/mutated-release-lane-output.ply"
cp "$authenticated_lane_output" "$mutated_output"
python3 - "$mutated_output" <<'PY'
import sys
from pathlib import Path

path = Path(sys.argv[1])
payload = bytearray(path.read_bytes())
payload[-2] = ord("1")
path.write_bytes(payload)
PY
chmod 600 "$mutated_output"
mutated_lane_evidence="$TMP_DIR/mutated-release-lane-evidence"
mkdir -m 700 "$mutated_lane_evidence"
# shellcheck disable=SC2030,SC2034,SC2329
if (
  # shellcheck source=/dev/null
  source "$evidence_helper_prefix"
  E2E_DIR="$TMP_DIR/mutated-release-lane-work"
  EVIDENCE_DIR="$mutated_lane_evidence"
  VERIFIED_TOOLCHAIN_CLOSURE_SHA256="$(printf 'a%.0s' {1..64})"
  run_release_verifier() {
    local diagnostic="$TMP_DIR/mutated-release-lane/work/diagnostic.md"
    mkdir -p "$(dirname "$diagnostic")"
    cp "$TMP_DIR/authenticated-release-lane/work/diagnostic.md" "$diagnostic"
    chmod 600 "$diagnostic"
  }
  run_captured_release_verifier bundled \
    "$TMP_DIR/mutated-release-lane" "$mutated_output" ignored
) >/dev/null 2>&1; then
  echo "Captured release lane accepted a PLY that diverged from its output digest." >&2
  exit 1
fi
supervisor_signal_fixture="$TMP_DIR/supervisor-signal-fixture.py"
cat >"$supervisor_signal_fixture" <<'PY'
#!/usr/bin/python3
import signal
import sys
import time
from pathlib import Path

mask_path, termination_path = map(Path, sys.argv[1:])
blocked = signal.pthread_sigmask(signal.SIG_BLOCK, [])
mask_path.write_text(
    "\n".join(sorted(item.name for item in blocked)),
    encoding="utf-8",
)

def terminate(_signum, _frame):
    termination_path.write_text("SIGTERM\n", encoding="utf-8")
    raise SystemExit(0)

signal.signal(signal.SIGTERM, terminate)
time.sleep(120)
PY
chmod +x "$supervisor_signal_fixture"
supervisor_signal_group="$TMP_DIR/supervisor-signal.group"
supervisor_signal_mask="$TMP_DIR/supervisor-signal.mask"
supervisor_signal_received="$TMP_DIR/supervisor-signal.received"
easysplat_supervise_process_group \
  "$supervisor_signal_group" \
  "$supervisor_signal_fixture" \
  "$supervisor_signal_mask" \
  "$supervisor_signal_received" 2>"$TMP_DIR/supervisor-signal.stderr" &
supervisor_signal_pid=$!
easysplat_wait_for_supervised_process_group \
  "$supervisor_signal_pid" "$supervisor_signal_group"
supervisor_signal_state="$(
  easysplat_read_supervised_process_group_state "$supervisor_signal_group"
)"
if [ "$(printf '%s\n' "$supervisor_signal_state" | cut -d: -f5)" != \
  "$supervisor_signal_pid" ]; then
  echo "Supervised-process state does not bridge the caller's background job." >&2
  exit 1
fi
for _ in {1..200}; do
  [ -f "$supervisor_signal_mask" ] && break
  sleep 0.01
done
if [ ! -f "$supervisor_signal_mask" ]; then
  echo "Supervised child did not report its inherited signal mask." >&2
  exit 1
fi
if grep -Eq '^SIG(HUP|INT|TERM)$' "$supervisor_signal_mask"; then
  echo "Supervised child inherited a blocked termination signal." >&2
  exit 1
fi
easysplat_cleanup_supervised_process_group \
  "$supervisor_signal_pid" "$supervisor_signal_group"
grep -Fxq 'SIGTERM' "$supervisor_signal_received"
test ! -e "$supervisor_signal_group"

supervisor_disposition_source="$TMP_DIR/supervisor-disposition-fixture.c"
supervisor_disposition_fixture="$TMP_DIR/supervisor-disposition-fixture"
supervisor_disposition_result="$TMP_DIR/supervisor-disposition.result"
cat >"$supervisor_disposition_source" <<'C'
#include <signal.h>
#include <stdio.h>

int main(int argc, char **argv) {
    struct sigaction action;
    int defaults_restored = 1;
    FILE *output;

    if (argc != 2 || sigaction(SIGPIPE, NULL, &action) != 0) {
        return 2;
    }
    defaults_restored = action.sa_handler == SIG_DFL;
#ifdef SIGXFZ
    if (sigaction(SIGXFZ, NULL, &action) != 0) {
        return 2;
    }
    defaults_restored = defaults_restored && action.sa_handler == SIG_DFL;
#endif
#ifdef SIGXFSZ
    if (sigaction(SIGXFSZ, NULL, &action) != 0) {
        return 2;
    }
    defaults_restored = defaults_restored && action.sa_handler == SIG_DFL;
#endif
    output = fopen(argv[1], "w");
    if (output == NULL) {
        return 2;
    }
    if (fputs(defaults_restored ? "default\n" : "not-default\n", output) < 0) {
        fclose(output);
        return 2;
    }
    return fclose(output) == 0 ? 0 : 2;
}
C
xcrun clang \
  -Wall -Wextra -Werror \
  "$supervisor_disposition_source" \
  -o "$supervisor_disposition_fixture"
supervisor_disposition_group="$TMP_DIR/supervisor-disposition.group"
easysplat_supervise_process_group \
  "$supervisor_disposition_group" \
  "$supervisor_disposition_fixture" "$supervisor_disposition_result" &
supervisor_disposition_pid=$!
easysplat_wait_for_supervised_process_group \
  "$supervisor_disposition_pid" "$supervisor_disposition_group"
wait "$supervisor_disposition_pid"
grep -Fxq default "$supervisor_disposition_result"
easysplat_cleanup_supervised_process_group "" "$supervisor_disposition_group"
test ! -e "$supervisor_disposition_group"

supervisor_lingering_fixture="$TMP_DIR/supervisor-lingering-fixture.py"
cat >"$supervisor_lingering_fixture" <<'PY'
#!/usr/bin/python3
import os
import signal
import sys
import time
from pathlib import Path

worker_path = Path(sys.argv[1])
worker = os.fork()
if worker == 0:
    signal.signal(signal.SIGTERM, signal.SIG_IGN)
    worker_path.write_text(f"{os.getpid()}\n", encoding="utf-8")
    time.sleep(8)
    raise SystemExit(0)
for _ in range(200):
    if worker_path.exists():
        break
    time.sleep(0.005)
raise SystemExit(0)
PY
chmod +x "$supervisor_lingering_fixture"
supervisor_lingering_group="$TMP_DIR/supervisor-lingering.group"
supervisor_lingering_worker="$TMP_DIR/supervisor-lingering.worker"
easysplat_supervise_process_group \
  "$supervisor_lingering_group" \
  "$supervisor_lingering_fixture" "$supervisor_lingering_worker" \
  2>"$TMP_DIR/supervisor-lingering.stderr" &
supervisor_lingering_pid=$!
easysplat_wait_for_supervised_process_group \
  "$supervisor_lingering_pid" "$supervisor_lingering_group"
set +e
wait "$supervisor_lingering_pid"
supervisor_lingering_status=$?
set -e
if [ "$supervisor_lingering_status" -ne 125 ]; then
  echo "Lingering same-group worker returned $supervisor_lingering_status instead of 125." >&2
  exit 1
fi
grep -Fq 'left a detached pipeline or toolchain worker process' \
  "$TMP_DIR/supervisor-lingering.stderr"
[[ "$(easysplat_read_supervised_process_group_state "$supervisor_lingering_group")" == \
  quiescent:* ]]
easysplat_cleanup_supervised_process_group "" "$supervisor_lingering_group"
test ! -e "$supervisor_lingering_group"

release_test_outer_session="$(/usr/bin/python3 -I - "$$" <<'PY'
import os
import sys

print(os.getsid(int(sys.argv[1])))
PY
)"
EASYSPLAT_RELEASE_TEST_OUTER_PID="$$" \
EASYSPLAT_RELEASE_TEST_OUTER_SESSION="$release_test_outer_session" \
  "$ROOT/scripts/ci/test_hostile_process_supervision.sh" \
    "$TMP_DIR/hostile-process-supervision"

for supervisor_race_index in {1..40}; do
  supervisor_race_group="$TMP_DIR/supervisor-race-${supervisor_race_index}.group"
  easysplat_supervise_process_group \
    "$supervisor_race_group" /bin/sleep 731923 2>/dev/null &
  supervisor_race_pid=$!
  easysplat_cleanup_supervised_process_group \
    "$supervisor_race_pid" "$supervisor_race_group"
  test ! -e "$supervisor_race_group"
done
if pgrep -f '^/bin/sleep 731923$' >/dev/null; then
  echo "Immediate supervisor cleanup orphaned a native child." >&2
  exit 1
fi

(
  stopped_supervisor_group="$TMP_DIR/stopped-supervisor.group"
  easysplat_supervise_process_group \
    "$stopped_supervisor_group" /bin/sleep 12 2>/dev/null &
  stopped_supervisor_pid=$!
  stopped_supervisor_is_stopped=0
  trap '[ "$stopped_supervisor_is_stopped" -eq 0 ] || kill -CONT "$stopped_supervisor_pid" 2>/dev/null || true; \
    wait "$stopped_supervisor_pid" 2>/dev/null || true' EXIT
  easysplat_wait_for_supervised_process_group \
    "$stopped_supervisor_pid" "$stopped_supervisor_group"
  kill -STOP "$stopped_supervisor_pid"
  stopped_supervisor_is_stopped=1
  stopped_cleanup_started="$(/usr/bin/python3 -c 'import time; print(time.time_ns())')"
  if easysplat_cleanup_supervised_process_group \
      "$stopped_supervisor_pid" "$stopped_supervisor_group" \
      >/dev/null 2>&1; then
    echo "Stopped controller acknowledged a request while it could not run." >&2
    exit 1
  fi
  stopped_cleanup_finished="$(/usr/bin/python3 -c 'import time; print(time.time_ns())')"
  /usr/bin/python3 - "$stopped_cleanup_started" "$stopped_cleanup_finished" <<'PY'
import sys

elapsed = (int(sys.argv[2]) - int(sys.argv[1])) / 1_000_000_000
# The wait is bounded at 3.5 seconds in monotonic time. The window proves both
# halves of that: it really waited, and it gave up well before the 12 seconds
# the supervised process would have taken on its own.
if not 3.4 < elapsed < 8:
    raise SystemExit(f"Stopped process-supervisor cleanup was not bounded: {elapsed:.3f}s")
PY
  if [ ! -f "$stopped_supervisor_group.request" ]; then
    echo "Stopped controller cleanup did not leave its authenticated request pending." >&2
    exit 1
  fi
  kill -CONT "$stopped_supervisor_pid"
  stopped_supervisor_is_stopped=0
  wait "$stopped_supervisor_pid" 2>/dev/null || true
  [[ "$(easysplat_read_supervised_process_group_state "$stopped_supervisor_group")" == \
    quiescent:* ]]
  easysplat_cleanup_supervised_process_group "" "$stopped_supervisor_group"
  test ! -e "$stopped_supervisor_group"
  test ! -e "$stopped_supervisor_group.request"
  trap - EXIT
)

(
  # O_NOFOLLOW turns away a symbolic link but admits a named pipe, and a
  # read-only open of one blocks until somebody writes. A state path swapped for
  # a pipe must be refused, not waited on: without O_NONBLOCK the bounded wait
  # never returns at all.
  swapped_supervisor_group="$TMP_DIR/swapped-supervisor.group"
  easysplat_supervise_process_group \
    "$swapped_supervisor_group" /bin/sleep 12 2>/dev/null &
  swapped_supervisor_pid=$!
  swapped_supervisor_is_stopped=0
  trap '[ "$swapped_supervisor_is_stopped" -eq 0 ] || kill -CONT "$swapped_supervisor_pid" 2>/dev/null || true; \
    kill -TERM "$swapped_supervisor_pid" 2>/dev/null || true; \
    wait "$swapped_supervisor_pid" 2>/dev/null || true' EXIT
  easysplat_wait_for_supervised_process_group \
    "$swapped_supervisor_pid" "$swapped_supervisor_group"
  kill -STOP "$swapped_supervisor_pid"
  swapped_supervisor_is_stopped=1
  rm -f "$swapped_supervisor_group"
  mkfifo -m 0600 "$swapped_supervisor_group"
  swapped_cleanup_started="$(/usr/bin/python3 -c 'import time; print(time.time_ns())')"
  if easysplat_cleanup_supervised_process_group \
      "$swapped_supervisor_pid" "$swapped_supervisor_group" \
      >/dev/null 2>&1; then
    echo "Cleanup accepted a process-group state path swapped for a pipe." >&2
    exit 1
  fi
  swapped_cleanup_finished="$(/usr/bin/python3 -c 'import time; print(time.time_ns())')"
  /usr/bin/python3 - "$swapped_cleanup_started" "$swapped_cleanup_finished" <<'PY'
import sys

elapsed = (int(sys.argv[2]) - int(sys.argv[1])) / 1_000_000_000
if elapsed >= 8:
    raise SystemExit(f"A swapped state path blocked cleanup: {elapsed:.3f}s")
PY
  rm -f "$swapped_supervisor_group"
  kill -CONT "$swapped_supervisor_pid"
  swapped_supervisor_is_stopped=0
  kill -TERM "$swapped_supervisor_pid" 2>/dev/null || true
  wait "$swapped_supervisor_pid" 2>/dev/null || true
  trap - EXIT
)

(
  quiescent_stopped_group="$TMP_DIR/quiescent-stopped-supervisor.group"
  easysplat_supervise_process_group \
    "$quiescent_stopped_group" /bin/sleep 30 2>/dev/null &
  quiescent_stopped_pid=$!
  quiescent_stopped_watchdog=""
  trap 'kill -CONT "$quiescent_stopped_pid" 2>/dev/null || true; \
    kill -TERM "$quiescent_stopped_pid" 2>/dev/null || true; \
    [ -z "$quiescent_stopped_watchdog" ] || kill "$quiescent_stopped_watchdog" 2>/dev/null || true; \
    wait "$quiescent_stopped_pid" 2>/dev/null || true; \
    [ -z "$quiescent_stopped_watchdog" ] || wait "$quiescent_stopped_watchdog" 2>/dev/null || true' EXIT
  easysplat_wait_for_supervised_process_group \
    "$quiescent_stopped_pid" "$quiescent_stopped_group"
  quiescent_stopped_state="$(
    easysplat_read_supervised_process_group_state "$quiescent_stopped_group"
  )"
  IFS=: read -r _ _ _ _ state_supervisor_pid state_seconds state_microseconds state_nonce \
    <<<"$quiescent_stopped_state"
  test "$state_supervisor_pid" = "$quiescent_stopped_pid"
  kill -STOP "$quiescent_stopped_pid"
  printf 'quiescent %s %s %s %s\n' \
    "$state_supervisor_pid" "$state_seconds" "$state_microseconds" "$state_nonce" \
    >"$quiescent_stopped_group"
  chmod 600 "$quiescent_stopped_group"
  (
    sleep 5
    kill -CONT "$quiescent_stopped_pid" 2>/dev/null || true
    kill -TERM "$quiescent_stopped_pid" 2>/dev/null || true
  ) &
  quiescent_stopped_watchdog=$!
  quiescent_cleanup_started="$(/usr/bin/python3 -c 'import time; print(time.time_ns())')"
  set +e
  easysplat_cleanup_supervised_process_group \
    "$quiescent_stopped_pid" "$quiescent_stopped_group" \
    >/dev/null 2>&1
  quiescent_cleanup_status=$?
  set -e
  quiescent_cleanup_finished="$(/usr/bin/python3 -c 'import time; print(time.time_ns())')"
  if [ "$quiescent_cleanup_status" -eq 0 ]; then
    echo "Cleanup accepted a quiescent controller that remained stopped." >&2
    exit 1
  fi
  /usr/bin/python3 - "$quiescent_cleanup_started" "$quiescent_cleanup_finished" <<'PY'
import sys

elapsed = (int(sys.argv[2]) - int(sys.argv[1])) / 1_000_000_000
if not 0 < elapsed < 4:
    raise SystemExit(f"Quiescent stopped-controller cleanup was not bounded: {elapsed:.3f}s")
PY
  test -f "$quiescent_stopped_group"
  kill "$quiescent_stopped_watchdog" 2>/dev/null || true
  wait "$quiescent_stopped_watchdog" 2>/dev/null || true
  quiescent_stopped_watchdog=""
  kill -CONT "$quiescent_stopped_pid"
  kill -TERM "$quiescent_stopped_pid"
  wait "$quiescent_stopped_pid" 2>/dev/null || true
  easysplat_cleanup_supervised_process_group "" "$quiescent_stopped_group"
  test ! -e "$quiescent_stopped_group"
  trap - EXIT
)

supervisor_quick_group="$TMP_DIR/supervisor-quick.group"
easysplat_supervise_process_group \
  "$supervisor_quick_group" /usr/bin/true &
supervisor_quick_pid=$!
easysplat_wait_for_supervised_process_group \
  "$supervisor_quick_pid" "$supervisor_quick_group"
wait "$supervisor_quick_pid"
[[ "$(easysplat_read_supervised_process_group_state "$supervisor_quick_group")" == \
  quiescent:* ]]
easysplat_cleanup_supervised_process_group "" "$supervisor_quick_group"
test ! -e "$supervisor_quick_group"

for supervisor_signal_case in INT:130 HUP:129 TERM:143; do
  supervisor_exit_signal="${supervisor_signal_case%%:*}"
  supervisor_expected_status="${supervisor_signal_case##*:}"
  supervisor_exit_group="$TMP_DIR/supervisor-exit-${supervisor_exit_signal}.group"
  easysplat_supervise_process_group \
    "$supervisor_exit_group" /bin/sleep 30 2>/dev/null &
  supervisor_exit_pid=$!
  easysplat_wait_for_supervised_process_group \
    "$supervisor_exit_pid" "$supervisor_exit_group"
  kill -"$supervisor_exit_signal" "$supervisor_exit_pid"
  set +e
  wait "$supervisor_exit_pid"
  supervisor_exit_status=$?
  set -e
  if [ "$supervisor_exit_status" -ne "$supervisor_expected_status" ]; then
    echo "Supervisor returned $supervisor_exit_status after SIG${supervisor_exit_signal}, expected $supervisor_expected_status." >&2
    exit 1
  fi
  [[ "$(easysplat_read_supervised_process_group_state "$supervisor_exit_group")" == \
    quiescent:* ]]
  easysplat_cleanup_supervised_process_group "" "$supervisor_exit_group"
  test ! -e "$supervisor_exit_group"
done

invalid_group_state="$TMP_DIR/invalid-process-group-state"
printf '1\n' >"$invalid_group_state"
chmod 600 "$invalid_group_state"
E2E_VERIFIER_TOKEN=""
E2E_VERIFIER_SUPERVISOR_PID=""
E2E_VERIFIER_GROUP_FILE="$invalid_group_state"
if cleanup_release_verifier_processes 2>/dev/null; then
  echo "Release cleanup accepted an unsafe process-group identifier." >&2
  exit 1
fi
test -f "$invalid_group_state"
test "$E2E_VERIFIER_GROUP_FILE" = "$invalid_group_state"
E2E_VERIFIER_GROUP_FILE=""
printf 'active 9999999999 1 1\n' >"$invalid_group_state"
chmod 600 "$invalid_group_state"
if easysplat_read_supervised_process_group_state \
    "$invalid_group_state" >/dev/null 2>&1; then
  echo "Process-group state accepted a PID beyond Darwin's process-ID ceiling." >&2
  exit 1
fi

(
  /bin/sleep 30 &
  identity_probe_pid=$!
  trap 'kill -TERM "$identity_probe_pid" 2>/dev/null || true; \
    wait "$identity_probe_pid" 2>/dev/null || true' EXIT
  identity_probe_state="$TMP_DIR/reused-process-group-state"
  printf 'active %s 1 1 2 1 1 %064d\n' \
    "$identity_probe_pid" 0 >"$identity_probe_state"
  chmod 600 "$identity_probe_state"
  if easysplat_cleanup_supervised_process_group \
      "" "$identity_probe_state" >/dev/null 2>&1; then
    echo "Release cleanup accepted a live group with a mismatched start identity." >&2
    exit 1
  fi
  if ! kill -0 "$identity_probe_pid" 2>/dev/null; then
    echo "Release cleanup signaled a process group with a mismatched start identity." >&2
    exit 1
  fi
  test -f "$identity_probe_state"
  kill -TERM "$identity_probe_pid"
  wait "$identity_probe_pid" 2>/dev/null || true
  trap - EXIT
)

verifier_process_source="$TMP_DIR/release-verifier-process-fixture.c"
verifier_process_fixture="$TMP_DIR/release-verifier-process-fixture"
cat >"$verifier_process_source" <<'C'
#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <stdio.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

extern char **environ;

static int append_line(const char *path, const char *line) {
    int fd = open(path, O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC, 0600);
    size_t offset = 0;
    size_t length = strlen(line);
    if (fd < 0) {
        return 1;
    }
    while (offset < length) {
        ssize_t written = write(fd, line + offset, length - offset);
        if (written < 0) {
            if (errno == EINTR) {
                continue;
            }
            close(fd);
            return 1;
        }
        offset += (size_t)written;
    }
    return close(fd) == 0 ? 0 : 1;
}

static long monotonic_ms(void) {
    struct timespec now;
    if (clock_gettime(CLOCK_MONOTONIC, &now) != 0) {
        return 0;
    }
    return (now.tv_sec * 1000L) + (now.tv_nsec / 1000000L);
}

static int signal_readiness(int readiness_fd) {
    const char readiness_byte = 'R';
    ssize_t written;

    do {
        written = write(readiness_fd, &readiness_byte, 1);
    } while (written < 0 && errno == EINTR);
    if (written != 1 || close(readiness_fd) != 0) {
        return 2;
    }
    return 0;
}

static int await_readiness(int readiness_fd) {
    char readiness_byte = '\0';
    char unexpected_byte = '\0';
    ssize_t received;

    do {
        received = read(readiness_fd, &readiness_byte, 1);
    } while (received < 0 && errno == EINTR);
    if (received != 1 || readiness_byte != 'R') {
        return 2;
    }
    do {
        received = read(readiness_fd, &unexpected_byte, 1);
    } while (received < 0 && errno == EINTR);
    return received == 0 ? 0 : 2;
}

static int run_worker(
    const char *pid_path,
    const char *signal_path,
    const char *release_path,
    int readiness_fd,
    int clear_environment
) {
    char line[128];
    struct timespec pause_time = { .tv_sec = 0, .tv_nsec = 3000000L };
    long deadline_ms = monotonic_ms() + 30000L;

    snprintf(line, sizeof(line), "%ld\n", (long)getpid());
    if (append_line(pid_path, line) != 0) {
        return 2;
    }
    if (signal_readiness(readiness_fd) != 0) {
        return 2;
    }
    if (clear_environment) {
        if (environ == NULL) {
            return 2;
        }
        environ[0] = NULL;
    }

    while (access(release_path, F_OK) != 0 && monotonic_ms() < deadline_ms) {
        while (nanosleep(&pause_time, &pause_time) != 0 && errno == EINTR) {
        }
        pause_time.tv_sec = 0;
        pause_time.tv_nsec = 3000000L;

        pid_t successor = fork();
        if (successor < 0) {
            return 2;
        }
        if (successor == 0) {
            if (setsid() < 0) {
                _exit(2);
            }
            snprintf(line, sizeof(line), "%ld\n", (long)getpid());
            if (append_line(pid_path, line) != 0) {
                _exit(2);
            }
            continue;
        }
        snprintf(line, sizeof(line), "%ld\n", (long)successor);
        if (append_line(pid_path, line) != 0) {
            return 2;
        }
        snprintf(line, sizeof(line), "%ld:%ld\n", (long)getpid(), (long)successor);
        if (append_line(signal_path, line) != 0) {
            return 2;
        }
        _exit(0);
    }
    return 0;
}

int main(int argc, char **argv) {
    int readiness_pipe[2];
    int readiness_status;
    pid_t child;
    if (argc != 5) {
        return 2;
    }
    if (strcmp(argv[4], "marker-only") != 0
        && strcmp(argv[4], "environment-only") != 0) {
        return 2;
    }
    if (pipe(readiness_pipe) != 0) {
        return 2;
    }
    child = fork();
    if (child < 0) {
        close(readiness_pipe[0]);
        close(readiness_pipe[1]);
        return 2;
    }
    if (child == 0) {
        if (close(readiness_pipe[0]) != 0 || setsid() < 0) {
            _exit(2);
        }
        _exit(run_worker(
            argv[1],
            argv[2],
            argv[3],
            readiness_pipe[1],
            strcmp(argv[4], "marker-only") == 0
        ));
    }
    if (close(readiness_pipe[1]) != 0) {
        close(readiness_pipe[0]);
        return 2;
    }
    readiness_status = await_readiness(readiness_pipe[0]);
    if (close(readiness_pipe[0]) != 0) {
        return 2;
    }
    return readiness_status;
}
C
xcrun clang -arch arm64 -O2 \
  "$verifier_process_source" -o "$verifier_process_fixture"
process_probe_home="$TMP_DIR/release-verifier-process-home"
process_probe_write_root="$TMP_DIR/release-verifier-process-output"
process_probe_cache_root="$TMP_DIR/release-verifier-process-cache/Probe.app"
verifier_process_pid="$process_probe_write_root/release-verifier-process.pid"
verifier_process_signal="$process_probe_write_root/release-verifier-process.signal"
verifier_process_release="$process_probe_write_root/release-verifier-process.release"
mkdir -p "$process_probe_write_root" "$process_probe_cache_root"
run_release_verifier allow \
  "$process_probe_home" "$process_probe_write_root" "$process_probe_cache_root" \
  /usr/bin/true
detached_process_error="$TMP_DIR/release-verifier-detached-process.stderr"
detached_process_status=0
verifier_process_fixture_active=1
run_release_verifier allow \
	    "$process_probe_home" "$process_probe_write_root" "$process_probe_cache_root" \
	    "$verifier_process_fixture" "$verifier_process_pid" \
	      "$verifier_process_signal" "$verifier_process_release" marker-only \
    >/dev/null 2>"$detached_process_error" \
  || detached_process_status=$?
if ! release_and_drain_verifier_fixture; then
  echo "Audit-token cleanup left a detached rotating verifier process alive." >&2
  exit 1
fi
if [ "$detached_process_status" -eq 0 ]; then
  echo "Release verifier accepted a detached token-bearing worker." >&2
  exit 1
fi
if ! grep -Fxq \
    'Release verification left a detached pipeline or toolchain worker process.' \
    "$detached_process_error"; then
  echo "Detached-worker verifier failed without reporting the precise containment breach:" >&2
  /bin/cat "$detached_process_error" >&2
  exit 1
fi
test -s "$verifier_process_signal"
if [ "$(cut -d: -f2 "$verifier_process_signal" \
    | sort -nu | wc -l | tr -d ' ')" -lt 8 ]; then
  echo "Detached verifier fixture did not continuously rotate cleared-environment setsid successors." >&2
  exit 1
fi
test -z "$E2E_VERIFIER_TOKEN"
test -z "$E2E_VERIFIER_SUPERVISOR_PID"
test -z "$E2E_VERIFIER_GROUP_FILE"
verifier_process_release=""
verifier_process_pid=""
verifier_process_signal=""
verifier_process_fixture_active=0

environment_process_token='easysplat-release-verify-30000000-0000-4000-8000-000000000003'
environment_process_root="$TMP_DIR/release-verifier-environment-process"
verifier_process_pid="$environment_process_root/process.pid"
verifier_process_signal="$environment_process_root/process.signal"
verifier_process_release="$environment_process_root/process.release"
mkdir -p "$environment_process_root"
verifier_process_fixture_active=1
EASYSPLAT_RELEASE_VERIFY_TOKEN="$environment_process_token" \
  "$verifier_process_fixture" \
    "$verifier_process_pid" \
    "$verifier_process_signal" \
    "$verifier_process_release" \
    environment-only
for _ in {1..200}; do
  if [ -s "$verifier_process_signal" ] \
      && [ "$(cut -d: -f2 "$verifier_process_signal" \
        | sort -nu | wc -l | tr -d ' ')" -ge 8 ]; then
    break
  fi
  sleep 0.003
done
if [ ! -s "$verifier_process_signal" ] \
    || [ "$(cut -d: -f2 "$verifier_process_signal" \
      | sort -nu | wc -l | tr -d ' ')" -lt 8 ]; then
  echo "Environment-only verifier fixture did not establish hostile process churn." >&2
  exit 1
fi
environment_process_result="$(
  easysplat_audit_and_drain_verification_processes "$environment_process_token"
)"
if [ "$environment_process_result" != contained ]; then
  echo "Residual-process audit accepted an environment-only rotating lineage." >&2
  exit 1
fi
if ! release_and_drain_verifier_fixture; then
  echo "Exact-token cleanup left an environment-only rotating process alive." >&2
  exit 1
fi
verifier_process_release=""
verifier_process_pid=""
verifier_process_signal=""
verifier_process_fixture_active=0

broker_probe_root="$TMP_DIR/release-verifier-broker-probe"
broker_probe_app="$broker_probe_root/EasySplatSandboxDenied-${PPID}-$$.app"
broker_probe_executable="$broker_probe_app/Contents/MacOS/EasySplatBrokerProbe"
broker_probe_proofs=()
broker_probe_releases=()
broker_probe_executables=()
mkdir -p "$broker_probe_app/Contents/MacOS"
broker_probe_source="$broker_probe_root/EasySplatBrokerProbe.c"
cat >"$broker_probe_source" <<'C'
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

static double monotonic_seconds(void) {
    struct timespec value;
    if (clock_gettime(CLOCK_MONOTONIC, &value) != 0) {
        return 0.0;
    }
    return (double)value.tv_sec + ((double)value.tv_nsec / 1000000000.0);
}

int main(int argc, char **argv) {
    const char *proof = NULL;
    const char *release = NULL;
    for (int index = 1; index + 1 < argc; index += 1) {
        if (strcmp(argv[index], "--proof") == 0) {
            proof = argv[++index];
        } else if (strcmp(argv[index], "--release") == 0) {
            release = argv[++index];
        }
    }
    if (proof == NULL || release == NULL) {
        return 2;
    }
    int descriptor = open(proof, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0600);
    if (descriptor < 0) {
        return 3;
    }
    dprintf(descriptor, "%d\n", getpid());
    close(descriptor);

    const double deadline = monotonic_seconds() + 5.0;
    while (access(release, F_OK) != 0 && monotonic_seconds() < deadline) {
        usleep(10000);
    }
    return 0;
}
C
xcrun clang -arch arm64 -O2 "$broker_probe_source" -o "$broker_probe_executable"
cat >"$broker_probe_app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key>
  <string>EasySplatBrokerProbe</string>
  <key>CFBundleIdentifier</key>
  <string>com.easysplat.release-tests.broker-probe</string>
  <key>CFBundleName</key>
  <string>EasySplatBrokerProbe</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>LSBackgroundOnly</key>
  <true/>
</dict>
</plist>
PLIST
/usr/bin/codesign --force --deep --sign - --timestamp=none "$broker_probe_app"

broker_probe_is_running() {
  local proof=$1
  local executable=$2
  [ -s "$proof" ] || return 1
  /usr/bin/python3 -I - "$proof" "$executable" <<'PY'
import ctypes
import sys
from pathlib import Path

try:
    pid = int(Path(sys.argv[1]).read_text(encoding="utf-8").strip())
except (OSError, ValueError):
    raise SystemExit(1)
if not 2 <= pid <= 99_999:
    raise SystemExit(1)
buffer = ctypes.create_string_buffer(4096)
libproc = ctypes.CDLL("/usr/lib/libproc.dylib")
proc_pidpath = libproc.proc_pidpath
proc_pidpath.argtypes = [ctypes.c_int, ctypes.c_void_p, ctypes.c_uint32]
proc_pidpath.restype = ctypes.c_int
size = proc_pidpath(pid, buffer, len(buffer))
if size <= 0 or buffer.value.decode("utf-8") != sys.argv[2]:
    raise SystemExit(1)
PY
}

stop_broker_process() {
  local proof=$1
  local release=$2
  local executable=$3
  : >"$release"
  for _ in {1..700}; do
    broker_probe_is_running "$proof" "$executable" || return 0
    sleep 0.01
  done
  echo "Temporary LaunchServices broker fixture did not exit by its hard deadline." >&2
  return 1
}

stop_broker_probe() {
  local cleanup_status=0
  local index=0
  while [ "$index" -lt "${#broker_probe_proofs[@]}" ]; do
    stop_broker_process \
      "${broker_probe_proofs[$index]}" \
      "${broker_probe_releases[$index]}" \
      "${broker_probe_executables[$index]}" \
      || cleanup_status=1
    index=$((index + 1))
  done
  return "$cleanup_status"
}

broker_open_invoker="$broker_probe_root/invoke-open.py"
cat >"$broker_open_invoker" <<'PY'
#!/usr/bin/python3
import os
import sys

os.execv(
    "/usr/bin/open",
    [
        "/usr/bin/open",
        "-gj",
        "-n",
        "-a",
        sys.argv[1],
        "--args",
        "--proof",
        sys.argv[2],
        "--release",
        sys.argv[3],
    ],
)
PY
chmod +x "$broker_open_invoker"

broker_workspace_source="$broker_probe_root/invoke-workspace.m"
broker_workspace_invoker="$broker_probe_root/invoke-workspace"
cat >"$broker_workspace_source" <<'OBJC'
#import <AppKit/AppKit.h>

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc != 4) {
            return 2;
        }
        NSURL *applicationURL = [NSURL fileURLWithPath:@(argv[1])];
        NSWorkspaceOpenConfiguration *configuration =
            [NSWorkspaceOpenConfiguration configuration];
        configuration.createsNewApplicationInstance = YES;
        configuration.activates = NO;
        configuration.arguments = @[
            @"--proof", @(argv[2]), @"--release", @(argv[3])
        ];
        __block BOOL completed = NO;
        __block int result = 1;
        [[NSWorkspace sharedWorkspace]
            openApplicationAtURL:applicationURL
            configuration:configuration
            completionHandler:^(NSRunningApplication *application, NSError *error) {
                result = application != nil && error == nil ? 0 : 1;
                completed = YES;
            }];
        NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:3.0];
        while (!completed && deadline.timeIntervalSinceNow > 0) {
            [[NSRunLoop currentRunLoop]
                runMode:NSDefaultRunLoopMode
                beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
        }
        return completed ? result : 1;
    }
}
OBJC
xcrun clang -arch arm64 -fobjc-arc -fblocks "$broker_workspace_source" \
  -framework AppKit -o "$broker_workspace_invoker"

assert_release_verifier_blocks_broker() {
  local label=$1
  local invoker=$2
  local case_root="$broker_probe_root/$label"
  local case_app=""
  local case_executable=""
  local case_proof="$broker_probe_root/$label.broker.pid"
  local case_release="$broker_probe_root/$label.broker.release"
  local status=0
  local escaped=0
  case_app="$case_root/output/$(basename "$broker_probe_app")"
  case_executable="$case_app/Contents/MacOS/EasySplatBrokerProbe"
  broker_probe_proofs+=("$case_proof")
  broker_probe_releases+=("$case_release")
  broker_probe_executables+=("$case_executable")
  rm -f "$case_proof" "$case_release"
  mkdir -p "$case_root/home" "$case_root/output" "$case_root/cache/Probe.app"
  /usr/bin/ditto "$broker_probe_app" "$case_app"
  set +e
  run_release_verifier allow \
    "$case_root/home" "$case_root/output" "$case_root/cache/Probe.app" \
    "$invoker" "$case_app" "$case_proof" "$case_release" \
    >"$case_root/verifier.log" 2>&1
  status=$?
  set -e
  for _ in {1..300}; do
    [ -s "$case_proof" ] && break
    sleep 0.01
  done
  if broker_probe_is_running "$case_proof" "$case_executable"; then
    escaped=1
  fi
  stop_broker_process "$case_proof" "$case_release" "$case_executable"
  if [ "$status" -eq 0 ] || [ "$escaped" -eq 1 ]; then
    echo "Release-verifier sandbox allowed the $label LaunchServices broker escape." >&2
    return 1
  fi
}

broker_direct_root="$broker_probe_root/direct-predicate-self-check"
broker_direct_app="$broker_direct_root/$(basename "$broker_probe_app")"
broker_direct_executable="$broker_direct_app/Contents/MacOS/EasySplatBrokerProbe"
broker_direct_proof="$broker_probe_root/direct-predicate.broker.pid"
broker_direct_release="$broker_probe_root/direct-predicate.broker.release"
mkdir -p "$broker_direct_root"
/usr/bin/ditto "$broker_probe_app" "$broker_direct_app"
broker_probe_proofs+=("$broker_direct_proof")
broker_probe_releases+=("$broker_direct_release")
broker_probe_executables+=("$broker_direct_executable")
rm -f "$broker_direct_proof" "$broker_direct_release"
"$broker_direct_executable" \
  --proof "$broker_direct_proof" --release "$broker_direct_release" &
broker_direct_pid=$!
for _ in {1..300}; do
  [ -s "$broker_direct_proof" ] && break
  sleep 0.01
done
if ! broker_probe_is_running "$broker_direct_proof" "$broker_direct_executable"; then
  : >"$broker_direct_release"
  wait "$broker_direct_pid" 2>/dev/null || true
  echo "LaunchServices broker predicate missed a directly launched copied fixture." >&2
  exit 1
fi
stop_broker_process \
  "$broker_direct_proof" "$broker_direct_release" "$broker_direct_executable"
wait "$broker_direct_pid"

broker_probe_failures=0
assert_release_verifier_blocks_broker \
  open-worker "$broker_open_invoker" \
  || broker_probe_failures=1
assert_release_verifier_blocks_broker \
  workspace-api "$broker_workspace_invoker" \
  || broker_probe_failures=1
if [ "$broker_probe_failures" -ne 0 ]; then
  exit 1
fi
for broker_case in open-worker workspace-api; do
  broker_profile="$broker_probe_root/$broker_case/home/release-verifier.sb"
  test -s "$broker_profile"
  grep -Fq '(allow process-fork)' "$broker_profile"
  grep -Fq '(allow process-exec ' "$broker_profile"
  if grep -Fq '(allow process*)' "$broker_profile"; then
    echo "Release-verifier broker profile retained unrestricted process rights." >&2
    exit 1
  fi
  for launch_service in \
    com.apple.coreservices.launchservicesd \
    com.apple.lsd.mapdb \
    com.apple.lsd.modifydb \
    com.apple.runningboard \
    com.apple.runningboardd; do
    grep -Fq "(deny mach-lookup (global-name \"$launch_service\"))" \
      "$broker_profile"
  done
done

tool_process_probe_root="$TMP_DIR/release-verifier-tool-process-probe"
tool_process_probe_source="$tool_process_probe_root/tool-process-probe.c"
tool_process_probe_binary="$tool_process_probe_root/tool-process-probe"
tool_process_probe_invoker="$tool_process_probe_root/invoke-tools.py"
tool_process_probe_home="$tool_process_probe_root/home"
tool_process_probe_output="$tool_process_probe_root/output"
tool_process_probe_cache="$tool_process_probe_root/cache/EasySplat.app"
tool_process_probe_bin="$tool_process_probe_cache/Contents/Helpers/bin"
tool_process_probe_proof="$tool_process_probe_output/tool-processes.txt"
mkdir -p "$tool_process_probe_bin" "$tool_process_probe_output"
cat >"$tool_process_probe_source" <<'C'
int main(void) {
    return 0;
}
C
xcrun clang -arch arm64 -O2 \
  "$tool_process_probe_source" -o "$tool_process_probe_binary"
for tool_name in colmap ffmpeg easysplat-train; do
  cp "$tool_process_probe_binary" "$tool_process_probe_bin/$tool_name"
  chmod 755 "$tool_process_probe_bin/$tool_name"
done
cat >"$tool_process_probe_invoker" <<'PY'
#!/usr/bin/python3
import subprocess
import sys
from pathlib import Path

toolchain_bin = Path(sys.argv[1])
proof = Path(sys.argv[2])
for name in ("colmap", "ffmpeg", "easysplat-train"):
    subprocess.run([toolchain_bin / name], check=True)
proof.write_text("colmap\nffmpeg\neasysplat-train\n", encoding="ascii")
PY
chmod +x "$tool_process_probe_invoker"
run_release_verifier deny \
  "$tool_process_probe_home" "$tool_process_probe_output" "$tool_process_probe_cache" \
  "$tool_process_probe_invoker" "$tool_process_probe_bin" "$tool_process_probe_proof"
test "$(cat "$tool_process_probe_proof")" = $'colmap\nffmpeg\neasysplat-train'
for tool_name in colmap ffmpeg easysplat-train; do
  grep -Fq "(literal \"$tool_process_probe_bin/$tool_name\")" \
    "$tool_process_probe_home/release-verifier.sb"
done

sandbox_test_root="$TMP_DIR/sandbox-write-isolation"
mkdir -p "$sandbox_test_root/home"
sandbox_test_root="$(cd "$sandbox_test_root" && pwd -P)"
sandbox_test_profile="(version 1)
(deny default)
(allow process*)
(allow file-read*)
(allow file-write* (subpath \"$sandbox_test_root/home\"))
(allow mach-lookup)
(allow ipc-posix*)
(allow sysctl-read)
(allow iokit-open)
(allow signal)"
/usr/bin/sandbox-exec -p "$sandbox_test_profile" \
  /usr/bin/touch "$sandbox_test_root/home/inside"
if /usr/bin/sandbox-exec -p "$sandbox_test_profile" \
  /usr/bin/touch "$sandbox_test_root/outside" 2>/dev/null; then
  echo "Packaged-app sandbox contract allowed a write outside its isolated home." >&2
  exit 1
fi
test -f "$sandbox_test_root/home/inside"
test ! -e "$sandbox_test_root/outside"

atomic_writer_source="$sandbox_test_root/AtomicWriter.swift"
atomic_writer_root="$TMP_DIR/release-verifier-executable"
atomic_writer="$atomic_writer_root/EasySplatReleaseVerifier"
mkdir -p "$atomic_writer_root"
cat >"$atomic_writer_source" <<'SWIFT'
import Darwin
import Foundation

@main
struct AtomicWriter {
    static func main() throws {
        guard CommandLine.arguments.count == 4 else { exit(64) }
        let inside = URL(fileURLWithPath: CommandLine.arguments[1])
        let outside = URL(fileURLWithPath: CommandLine.arguments[2])
        let malformedScratch = URL(fileURLWithPath: CommandLine.arguments[3])
        try openDirectoryChain(
            URL(fileURLWithPath: CommandLine.arguments[0])
                .deletingLastPathComponent().path
        )
        try openDirectoryChain(inside.deletingLastPathComponent().path)
        for prefix in ["EasySplat-selected-lineage-", "EasySplat-finished-dataset-replay-"] {
            let replay = FileManager.default.temporaryDirectory.appendingPathComponent(
                "\(prefix)\(UUID().uuidString)",
                isDirectory: true
            )
            try FileManager.default.createDirectory(
                at: replay,
                withIntermediateDirectories: false
            )
            try Data("replay".utf8).write(
                to: replay.appendingPathComponent("frame.png")
            )
            try FileManager.default.removeItem(at: replay)
        }
        try Data("first".utf8).write(to: inside, options: .atomic)
        try Data("second".utf8).write(to: inside, options: .atomic)
        do {
            try Data("escape".utf8).write(to: outside, options: .atomic)
            exit(65)
        } catch {
            guard !FileManager.default.fileExists(atPath: outside.path) else { exit(66) }
        }
        do {
            _ = try Data(contentsOf: malformedScratch)
            exit(67)
        } catch {}
        do {
            try Data("escape".utf8).write(to: malformedScratch)
            exit(68)
        } catch {}
    }

    private static func openDirectoryChain(_ path: String) throws {
        var descriptor = Darwin.open(
            "/",
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard descriptor >= 0 else { throw POSIXError(.EACCES) }
        defer { Darwin.close(descriptor) }
        for component in path.split(separator: "/") {
            let next = component.withCString {
                Darwin.openat(
                    descriptor,
                    $0,
                    O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
                )
            }
            guard next >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno)!) }
            Darwin.close(descriptor)
            descriptor = next
        }
    }
}
SWIFT
xcrun swiftc -parse-as-library "$atomic_writer_source" -o "$atomic_writer"
atomic_home="$sandbox_test_root/atomic-home"
atomic_output_root="$sandbox_test_root/atomic-output"
atomic_cache_root="$sandbox_test_root/atomic-cache/Probe.app"
mkdir -p "$atomic_home" "$atomic_output_root" "$atomic_cache_root"
atomic_inside="$atomic_output_root/project.json"
atomic_outside="$sandbox_test_root/atomic-outside.json"
atomic_malformed_scratch="$(/usr/bin/getconf DARWIN_USER_TEMP_DIR)EasySplat-selected-lineage-audit-$RANDOM"
printf '%s' 'sealed' >"$atomic_malformed_scratch"
run_release_verifier deny "$atomic_home" "$atomic_output_root" "$atomic_cache_root" \
  "$atomic_writer" "$atomic_inside" "$atomic_outside" "$atomic_malformed_scratch"
test "$(cat "$atomic_inside")" = "second"
test ! -e "$atomic_outside"
test "$(cat "$atomic_malformed_scratch")" = "sealed"
rm -f "$atomic_malformed_scratch"
grep -Fq 'NSIRD_EasySplatReleaseVerifier_' "$atomic_home/release-verifier.sb"
grep -Fq 'EasySplat\-selected\-lineage\-' "$atomic_home/release-verifier.sb"
grep -Fq 'EasySplat\-video\-lineage\-' "$atomic_home/release-verifier.sb"
grep -Fq 'EasySplat\-finished\-dataset\-replay\-' "$atomic_home/release-verifier.sb"

declared_input_probe="$sandbox_test_root/declared-input-reader.py"
cat >"$declared_input_probe" <<'PY'
#!/usr/bin/python3
import hashlib
import sys
from pathlib import Path

if len(sys.argv) != 5 or sys.argv[1] != "--input-manifest":
    raise SystemExit(64)
declared_input = Path(sys.argv[2])
forbidden = Path(sys.argv[3])
output = Path(sys.argv[4])
digest = hashlib.sha256(declared_input.read_bytes()).hexdigest()
try:
    forbidden.read_bytes()
except OSError:
    pass
else:
    raise SystemExit("sandbox allowed an undeclared sibling read")
output.write_text(digest + "\n", encoding="ascii")
PY
chmod +x "$declared_input_probe"
declared_input_file="$sandbox_test_root/declared-input.json"
forbidden_input_sibling="$sandbox_test_root/forbidden-input-secret.txt"
printf '%s\n' '{"schemaVersion":1}' >"$declared_input_file"
printf '%s\n' 'private sibling' >"$forbidden_input_sibling"
declared_input_digest="$(shasum -a 256 "$declared_input_file" | awk '{ print $1 }')"
declared_input_output="$atomic_output_root/declared-input.sha256"
run_release_verifier deny "$atomic_home" "$atomic_output_root" "$atomic_cache_root" \
  "$declared_input_probe" \
  --input-manifest "$declared_input_file" \
  "$forbidden_input_sibling" \
  "$declared_input_output"
grep -Fxq "$declared_input_digest" "$declared_input_output"
grep -Fq -- '"--app-bundle": "input"' "$e2e_verifier_helpers"
grep -Fq "(literal \"$declared_input_file\")" "$atomic_home/release-verifier.sb"
if grep -Fq "$forbidden_input_sibling" "$atomic_home/release-verifier.sb"; then
  echo "Release-verifier sandbox authorized an undeclared sibling input." >&2
  exit 1
fi
# Helpers are executable only where the caller declared the bundle, so no
# colmap outside that read-only root may appear in the profile.
python3 - "$atomic_home/release-verifier.sb" "$atomic_cache_root" <<'PY'
import re
import sys
from pathlib import Path

profile = Path(sys.argv[1]).read_text(encoding="utf-8")
bundle_root = sys.argv[2].rstrip("/")
granted = re.findall(r'\(literal "([^"]+/bin/colmap)"\)', profile)
outside = [path for path in granted if not path.startswith(bundle_root + "/")]
if outside:
    raise SystemExit(
        f"Release-verifier sandbox granted colmap outside the declared bundle: {outside}"
    )
PY

timeout_home="$TMP_DIR/release-verifier-timeout-home"
timeout_output="$TMP_DIR/release-verifier-timeout-output"
timeout_cache="$TMP_DIR/release-verifier-timeout-cache/Probe.app"
timeout_error="$TMP_DIR/release-verifier-timeout.stderr"
mkdir -p "$timeout_output" "$timeout_cache"
timeout_started="$(python3 -c 'import time; print(time.monotonic_ns())')"
if EASYSPLAT_RELEASE_VERIFIER_TIMEOUT_SECONDS=1 \
  run_release_verifier allow "$timeout_home" "$timeout_output" "$timeout_cache" \
    /bin/sleep 30 >/dev/null 2>"$timeout_error"; then
  echo "Release verifier accepted a lane that exceeded its deadline." >&2
  exit 1
else
  timeout_status=$?
fi
timeout_finished="$(python3 -c 'import time; print(time.monotonic_ns())')"
if [ "$timeout_status" -ne 124 ]; then
  echo "Release-verifier timeout returned $timeout_status instead of 124." >&2
  exit 1
fi
grep -Fq '-second lane timeout' "$timeout_error"
python3 - "$timeout_started" "$timeout_finished" <<'PY'
import sys

elapsed = (int(sys.argv[2]) - int(sys.argv[1])) / 1_000_000_000
if not 0 < elapsed < 8:
    raise SystemExit(f"Release-verifier timeout cleanup was not bounded: {elapsed:.3f}s")
PY
test -z "$E2E_VERIFIER_TOKEN"
test -z "$E2E_VERIFIER_SUPERVISOR_PID"
test -z "$E2E_VERIFIER_GROUP_FILE"

# shellcheck source=../release/lib/token_process_cleanup.sh
source "$ROOT/scripts/release/lib/token_process_cleanup.sh"
(
  cleanup_token="easysplat-release-verify-11111111-2222-4333-8444-555555555555"
  unrelated_token="easysplat-release-verify-aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee"
  cleanup_release_one="$TMP_DIR/token-cleanup-one.release"
  cleanup_release_two="$TMP_DIR/token-cleanup-two.release"
  unrelated_release="$TMP_DIR/token-cleanup-unrelated.release"
  cleanup_pid_one=""
  cleanup_pid_two=""
  unrelated_pid=""
  cleanup_detection_processes() {
    touch "$cleanup_release_one" "$cleanup_release_two" "$unrelated_release"
    [ -z "$cleanup_pid_one" ] || wait "$cleanup_pid_one" 2>/dev/null || true
    [ -z "$cleanup_pid_two" ] || wait "$cleanup_pid_two" 2>/dev/null || true
    [ -z "$unrelated_pid" ] || wait "$unrelated_pid" 2>/dev/null || true
  }
  trap cleanup_detection_processes EXIT
  EASYSPLAT_RELEASE_VERIFY_TOKEN="$cleanup_token" \
    python3 - "$cleanup_release_one" <<'PY' &
import sys
import time
from pathlib import Path

release = Path(sys.argv[1])
deadline = time.monotonic() + 15
while not release.exists() and time.monotonic() < deadline:
    time.sleep(0.02)
PY
  cleanup_pid_one=$!
  EASYSPLAT_RELEASE_VERIFY_TOKEN="$cleanup_token" \
    python3 - "$cleanup_release_two" <<'PY' &
import sys
import time
from pathlib import Path

release = Path(sys.argv[1])
deadline = time.monotonic() + 15
while not release.exists() and time.monotonic() < deadline:
    time.sleep(0.02)
PY
  cleanup_pid_two=$!
  EASYSPLAT_RELEASE_VERIFY_TOKEN="$unrelated_token" \
    python3 - "$unrelated_release" <<'PY' &
import sys
import time
from pathlib import Path

release = Path(sys.argv[1])
deadline = time.monotonic() + 15
while not release.exists() and time.monotonic() < deadline:
    time.sleep(0.02)
PY
  unrelated_pid=$!
  sleep 0.1
  detected_pids="$(easysplat_token_process_ids "$cleanup_token" | sort -n)"
  expected_pids="$(printf '%s\n%s\n' "$cleanup_pid_one" "$cleanup_pid_two" | sort -n)"
  if [ "$detected_pids" != "$expected_pids" ]; then
    echo "Token inspection did not return the exact matching worker set." >&2
    exit 1
  fi
  if ! easysplat_cleanup_token_processes "$cleanup_token" >/dev/null 2>&1; then
    echo "Exact-token cleanup did not contain its residual workers." >&2
    exit 1
  fi
  wait "$cleanup_pid_one" 2>/dev/null || true
  wait "$cleanup_pid_two" 2>/dev/null || true
  cleanup_pid_one=""
  cleanup_pid_two=""
  if ! kill -0 "$unrelated_pid" 2>/dev/null; then
    echo "Exact-token cleanup signaled an unrelated worker." >&2
    exit 1
  fi
  if easysplat_cleanup_token_processes \
      "easysplat-release-verify-invalid" >/dev/null 2>&1; then
    echo "Token-scoped inspection accepted a malformed verification token." >&2
    exit 1
  fi
  cleanup_detection_processes
  trap - EXIT
)
grep -Fq -- '--toolchain-dir)' "$ROOT/scripts/release/build_app.sh"
if git -C "$ROOT" ls-files --error-unmatch \
  EasySplatApp/Resources/ToolchainBootstrap >/dev/null 2>&1 \
  || git -C "$ROOT" ls-files EasySplatApp/Resources/ToolchainBootstrap/ | grep -q .; then
  echo "Repository tracks a bundled toolchain bootstrap payload." >&2
  exit 1
fi

app_build_metadata_error="$TMP_DIR/build-app-metadata.stderr"
app_build_metadata_root="$TMP_DIR/build-app-metadata"
app_build_metadata_log="$TMP_DIR/build-app-metadata-xcodebuild.log"
if EASYSPLAT_XCODEBUILD_BIN="$mock_xcodebuild" \
  EASYSPLAT_TEST_XCODEBUILD_LOG="$app_build_metadata_log" \
  "$ROOT/scripts/release/build_app.sh" \
  --build-root "$app_build_metadata_root" \
  --toolchain-dir "$toolchain_tree" \
  --project-url "$project_url" \
  --version "0.2.0+build.7" \
  --development-unsigned >/dev/null 2>"$app_build_metadata_error"; then
  echo "Release app build accepted SemVer build metadata." >&2
  exit 1
fi
grep -Fq 'without build metadata' "$app_build_metadata_error"
if [ -e "$app_build_metadata_log" ] || [ -e "$app_build_metadata_root" ]; then
  echo "Release app build mutated output before rejecting build metadata." >&2
  exit 1
fi

missing_build_root_error="$TMP_DIR/missing-build-root.stderr"
if "$ROOT/scripts/release/build_app.sh" \
  --toolchain-dir "$toolchain_tree" \
  --version "0.2.0" \
  --development-unsigned \
  --build-root >/dev/null 2>"$missing_build_root_error"; then
  echo "Release app build accepted --build-root without a value" >&2
  exit 1
fi
grep -Fqi -- '--build-root requires an absolute path' "$missing_build_root_error"

assert_unsafe_build_root_rejected() {
  local candidate="$1"
  local expected_error="$2"
  local error_path="$3"
  if "$ROOT/scripts/release/build_app.sh" \
    --build-root "$candidate" \
    --toolchain-dir "$toolchain_tree" \
    --version "0.2.0" \
      --development-unsigned >/dev/null 2>"$error_path"; then
    echo "Release app build accepted unsafe build root: $candidate" >&2
    exit 1
  fi
  grep -Fqi "$expected_error" "$error_path"
}

assert_unsafe_build_root_rejected \
  "relative-build" "must be an absolute path" "$TMP_DIR/relative-build-root.stderr"
assert_unsafe_build_root_rejected \
  "/" "unsafe build root" "$TMP_DIR/filesystem-root.stderr"
assert_unsafe_build_root_rejected \
  "$ROOT" "unsafe build root" "$TMP_DIR/repository-root.stderr"
assert_unsafe_build_root_rejected \
  "$(dirname "$ROOT")" "unsafe build root" "$TMP_DIR/repository-parent.stderr"
assert_unsafe_build_root_rejected \
  "$TMP_DIR/app-build/../app-build" "must be normalized" \
  "$TMP_DIR/non-normalized-build-root.stderr"
root_build_link="$TMP_DIR/root-build-link"
ln -s / "$root_build_link"
assert_unsafe_build_root_rejected \
  "$root_build_link" "unsafe build root" "$TMP_DIR/symlinked-root.stderr"

x86_build_error="$TMP_DIR/build-app-x86.stderr"
if EASYSPLAT_XCODEBUILD_BIN="$mock_xcodebuild" \
  EASYSPLAT_TEST_BINARY_ARCH=x86_64 \
  "$ROOT/scripts/release/build_app.sh" \
  --build-root "$release_test_build_root" \
  --toolchain-dir "$toolchain_tree" \
  --project-url "$project_url" \
  --version "0.2.0" \
  --development-unsigned >/dev/null 2>"$x86_build_error"; then
  echo "Release app build accepted an x86_64-only executable" >&2
  exit 1
fi
if ! grep -Fqi 'Release app executable must contain exactly arm64' "$x86_build_error"; then
  cat "$x86_build_error" >&2
  exit 1
fi

profiled_build_error="$TMP_DIR/build-app-profiled.stderr"
if EASYSPLAT_XCODEBUILD_BIN="$mock_xcodebuild" \
  EASYSPLAT_TEST_ENABLE_COVERAGE=1 \
  "$ROOT/scripts/release/build_app.sh" \
  --build-root "$release_test_build_root" \
  --toolchain-dir "$toolchain_tree" \
  --project-url "$project_url" \
  --version "0.2.0" \
  --development-unsigned >/dev/null 2>"$profiled_build_error"; then
  echo "Release app build accepted a code-coverage-instrumented executable" >&2
  exit 1
fi
if ! grep -Fqi 'code-coverage instrumentation' "$profiled_build_error"; then
  cat "$profiled_build_error" >&2
  exit 1
fi

EASYSPLAT_XCODEBUILD_BIN="$mock_xcodebuild" \
EASYSPLAT_TEST_XCODEBUILD_LOG="$xcodebuild_log" \
  "$ROOT/scripts/release/build_app.sh" \
  --build-root "$release_test_build_root" \
  --toolchain-dir "$toolchain_tree" \
  --project-url "$project_url" \
  --version "0.2.0" \
  --development-unsigned
grep -Eq '(^| )ARCHS=arm64( |$)' "$xcodebuild_log"
grep -Eq '(^| )ONLY_ACTIVE_ARCH=YES( |$)' "$xcodebuild_log"
grep -Eq '(^| )ENABLE_CODE_COVERAGE=NO( |$)' "$xcodebuild_log"
grep -Eq '(^| )CLANG_ENABLE_CODE_COVERAGE=NO( |$)' "$xcodebuild_log"
grep -Eq '(^| )CLANG_COVERAGE_MAPPING=NO( |$)' "$xcodebuild_log"
grep -Eq '(^| )CLANG_COVERAGE_MAPPING_LINKER_ARGS=NO( |$)' "$xcodebuild_log"
grep -Eq '(^| )SDK_STAT_CACHE_ENABLE=NO( |$)' "$xcodebuild_log"

app_bundle="$release_test_build_root/Export/EasySplat.app"
app_dsym="$release_test_build_root/Export/EasySplat.app.dSYM"
resources_dir="$app_bundle/Contents/Resources"

test "$(cat "$ROOT/EasySplatApp/Resources/project_home_url.txt")" = "$project_before"

test "$(cat "$resources_dir/project_home_url.txt")" = "$project_url"

module_resources_dir="$resources_dir/EasySplat_EasySplatApp.bundle"
test "$(cat "$module_resources_dir/project_home_url.txt")" = "$project_url"

# The app carries the toolchain itself and names no download.
helpers_dir="$app_bundle/Contents/Helpers"
toolchain_res_dir="$resources_dir/Toolchain"
test -x "$helpers_dir/bin/colmap"
test -x "$helpers_dir/bin/easysplat-train"
test -f "$helpers_dir/lib/libomp.dylib"
test -s "$toolchain_res_dir/default.metallib"
test -s "$toolchain_res_dir/supply-chain/components.json"
# The build compares staged bytes against the source tree and then signs the
# helpers, so what survives here is the signature and the staged tool's own
# identity. The metallib is a sealed resource and stays byte-identical.
/usr/bin/codesign --verify --strict "$helpers_dir/bin/colmap"
/usr/bin/codesign --verify --strict "$helpers_dir/bin/easysplat-train"
LC_ALL=C grep -aq 'native-colmap' "$helpers_dir/bin/colmap"
LC_ALL=C grep -aq 'native-msplat' "$helpers_dir/bin/easysplat-train"
cmp -s "$toolchain_res_dir/default.metallib" "$toolchain_tree/bin/default.metallib"
test ! -e "$resources_dir/ToolchainBootstrap"
test ! -e "$resources_dir/public_key_ed25519.txt"
test ! -e "$resources_dir/toolchain_manifest_url.txt"
test ! -e "$module_resources_dir/public_key_ed25519.txt"
test ! -e "$module_resources_dir/toolchain_manifest_url.txt"

info_plist="$app_bundle/Contents/Info.plist"
test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$info_plist")" = "com.easysplat.app"
test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIconFile' "$info_plist")" = "EasySplatAppIcon"
test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$info_plist")" = "0.2.0"
test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$info_plist")" = "0.2.0"
test "$(/usr/libexec/PlistBuddy -c 'Print :NSPrincipalClass' "$info_plist")" = "NSApplication"
# The app hashes and verifies signatures and opens no connection, so it declares
# exempt encryption once rather than answering the store for every build.
test "$(/usr/libexec/PlistBuddy -c 'Print :ITSAppUsesNonExemptEncryption' "$info_plist")" = "false"
# App Store Connect refuses a CFBundleVersion it has already accepted, so a
# second upload of one marketing version needs a build number of its own. The
# default is the version, which is what the assertion above pins.
if ! /usr/bin/grep -A1 -F '<key>CFBundleVersion</key>' \
    "$ROOT/scripts/release/build_app.sh" | /usr/bin/grep -Fq '$BUILD_NUMBER'; then
  echo "CFBundleVersion is not driven by the build number." >&2
  exit 1
fi
if "$ROOT/scripts/release/build_app.sh" \
    --toolchain-dir "$toolchain_tree" \
    --version 0.2.0 \
    --build-number 1.2.3.4 \
    --development-unsigned >/dev/null 2>&1; then
  echo "A build number outside CFBundleVersion's shape was accepted." >&2
  exit 1
fi
# A quarantined file reaches App Store Connect and is rejected there
# (ITMS-91109), so both the build and the packaging step refuse one first.
grep -Fq 'com.apple.quarantine' "$ROOT/scripts/release/build_app.sh"
grep -Fq 'com.apple.quarantine' "$ROOT/scripts/release/build_mas_package.sh"
# install(1) preserves the attribute a browser download leaves behind.
grep -Fq '/usr/bin/ditto --noqtn "$PROVISIONING_PROFILE"' \
  "$ROOT/scripts/release/build_app.sh"
if grep -Fq 'install -m 0644 "$PROVISIONING_PROFILE"' \
    "$ROOT/scripts/release/build_app.sh"; then
  echo "The provisioning profile is staged with a command that keeps quarantine." >&2
  exit 1
fi
built_app_quarantine="$(
  /usr/bin/find "$app_bundle" -type f \
    -exec /usr/bin/xattr -p com.apple.quarantine {} \; -print 2>/dev/null \
    | /usr/bin/grep "^$app_bundle" || true
)"
if [ -n "$built_app_quarantine" ]; then
  echo "The built app carries quarantined files the store would reject." >&2
  printf '%s\n' "$built_app_quarantine" >&2
  exit 1
fi
if rg -n --glob '!Tools/**' --glob '!*Tests*' \
    'ChaChaPoly|AES\.GCM|SealedBox|SymmetricKey|Curve25519|sharedSecretFromKeyAgreement' \
    "$ROOT/EasySplatApp" "$ROOT/EasySplatCore/Sources" >/dev/null; then
  echo "The shipped app now uses encryption its export declaration denies." >&2
  exit 1
fi
test "$(/usr/libexec/PlistBuddy -c 'Print :EasySplatReleaseChannel' "$info_plist")" = "development-unsigned"
test -d "$app_dsym"
test -s "$resources_dir/EasySplatAppIcon.icns"
test -s "$resources_dir/Licenses/EasySplat-LICENSE.txt"
test -s "$resources_dir/Licenses/EasySplat-NOTICE.md"
test -s "$resources_dir/Licenses/MetalSplatter-LICENSE.txt"
test -d "$app_bundle/Contents/_CodeSignature"
/usr/bin/codesign --verify --deep --strict "$app_bundle"
/usr/bin/codesign --display --verbose=4 "$app_bundle" 2>&1 | grep -F 'Signature=adhoc' >/dev/null
test "$(cat "$resources_dir/release_channel.txt")" = "unsigned developer build"

signed_fingerprint="0123456789ABCDEF0123456789ABCDEF01234567"
signed_team_id="A1B2C3D4E5"
test_source_commit="$(git -C "$ROOT" rev-parse HEAD)"
assert_signed_app_override_rejected() {
  local mode_flag="$1"
  local expected_error="$2"
  local override_name="$3"
  local override_value="$4"
  local fixture_label="$5"
  local override_root="$TMP_DIR/${fixture_label}-root"
  local override_error="$TMP_DIR/${fixture_label}.stderr"
  local mode_args=(--source-commit "$test_source_commit")

  if [ "$mode_flag" = --production ]; then
    mode_args+=(
      --production
      --identity-fingerprint "$signed_fingerprint"
      --team-id "$signed_team_id"
    )
  else
    mode_args+=(--prepare-release)
  fi

  if env "$override_name=$override_value" \
    "$ROOT/scripts/release/build_app.sh" \
    --build-root "$override_root" \
    --toolchain-dir "$toolchain_tree" \
    --project-url "$project_url" \
    --version "0.2.0" \
      "${mode_args[@]}" >/dev/null 2>"$override_error"; then
    echo "$mode_flag app build accepted $override_name." >&2
    exit 1
  fi
  grep -Fxqi "$expected_error" "$override_error"
  test ! -e "$override_root/Export/EasySplat.app"
  test ! -e "$override_root/Export/EasySplat.app-signing.json"
}

for signed_override_mode in --production --prepare-release; do
  if [ "$signed_override_mode" = --production ]; then
    signed_override_error='Signed build command overrides are not permitted.'
    signed_override_label=signed
  else
    signed_override_error='Prepared production build command overrides are not permitted.'
    signed_override_label=prepared-signed
  fi
  assert_signed_app_override_rejected \
    "$signed_override_mode" "$signed_override_error" \
    EASYSPLAT_XCODEBUILD_BIN "$mock_xcodebuild" \
    "$signed_override_label-xcodebuild-override"
  assert_signed_app_override_rejected \
    "$signed_override_mode" "$signed_override_error" \
    EASYSPLAT_CODESIGN_BIN /usr/bin/codesign \
    "$signed_override_label-codesign-override"
  assert_signed_app_override_rejected \
    "$signed_override_mode" "$signed_override_error" \
    EASYSPLAT_SKIP_METAL_TOOLCHAIN_CHECK 1 \
    "$signed_override_label-metal-override"
done

early_exit_fixture="$TMP_DIR/early-exit-fixture"
mkdir -p "$early_exit_fixture"
cp -R "$app_bundle" "$early_exit_fixture/EasySplat.app"
xcrun dsymutil \
  "$early_exit_fixture/EasySplat.app/Contents/MacOS/EasySplatApp" \
  -o "$early_exit_fixture/EasySplat.app.dSYM"

smoke_fixture_source="$TMP_DIR/smoke-fixture.m"
cat >"$smoke_fixture_source" <<'EOF'
#import <AppKit/AppKit.h>

int main(void) {
    @autoreleasepool {
        NSApplication *application = [NSApplication sharedApplication];
        [application setActivationPolicy:NSApplicationActivationPolicyRegular];
        [application run];
    }
    return 0;
}
EOF
smoke_fixture_object="$TMP_DIR/smoke-fixture-arm64.o"
xcrun clang -arch arm64 -g -fobjc-arc -c \
  "$smoke_fixture_source" -o "$smoke_fixture_object"
xcrun clang -arch arm64 \
  "$smoke_fixture_object" \
  -framework AppKit \
  -o "$app_bundle/Contents/MacOS/EasySplatApp"
rm -rf "$app_dsym"
xcrun dsymutil \
  "$app_bundle/Contents/MacOS/EasySplatApp" \
  -o "$app_dsym"
/usr/bin/codesign --force --deep --sign - --timestamp=none "$app_bundle"

# Exercise the same packaged-bootstrap hook used by strict verification with a
# deterministic fake executable. The production helper separately proves that
# networking terminates the probing process and the fake proves that its
# stdin/stdout/stderr stay inside the isolated verifier home.
# shellcheck source=../release/lib/token_process_cleanup.sh
source "$ROOT/scripts/release/lib/token_process_cleanup.sh"
# shellcheck source=../release/lib/packaged_app_bootstrap_smoke.sh
# Resolved from ROOT at runtime and checked separately.
# shellcheck disable=SC1091
source "$ROOT/scripts/release/lib/packaged_app_bootstrap_smoke.sh"
eval "$(declare -f packaged_app_input_closure_snapshot \
  | sed '1s/packaged_app_input_closure_snapshot/packaged_app_input_closure_snapshot_original/')"
# Invoked indirectly by the packaged-app smoke helper.
# shellcheck disable=SC2329
packaged_app_input_closure_snapshot() {
  local snapshot=""
  snapshot="$(packaged_app_input_closure_snapshot_original "$@")" || return
  local corruption_flag="${INSTALLED_APP:-}/Contents/Resources/Toolchain/CorruptAttestationDuringPostChecks"
  # The fixture deliberately rebinds this global after earlier subshell probes.
  # shellcheck disable=SC2031
  local attestation="${SMOKE_INSTALL_ROOT:-}/ReleaseVerificationHome/packaged-app-attestation.md"
  if [ -e "$corruption_flag" ] && [ -f "$attestation" ]; then
    printf '%s\n' 'corrupted packaged attestation' >"$attestation"
    chmod 600 "$attestation"
    rm -f "$corruption_flag"
  fi
  printf '%s\n' "$snapshot"
}
SMOKE_INSTALL_ROOT="$TMP_DIR/packaged-bootstrap-hook-smoke"
INSTALLED_APP="$SMOKE_INSTALL_ROOT/Applications/EasySplat.app"
INSTALLED_EXECUTABLE="$INSTALLED_APP/Contents/MacOS/EasySplatApp"
APP_WIRING_PID=""
APP_WIRING_LOG=""
APP_WIRING_TOKEN=""
# Consumed by packaged_app_bootstrap_smoke.sh.
# shellcheck disable=SC2034
APP_WIRING_GROUP_FILE=""
PACKAGED_APP_ATTESTATION_PRESERVED=0
EVIDENCE_DIR="$TMP_DIR/packaged-hook-evidence"
mkdir -p "$EVIDENCE_DIR"
# Invoked by the sourced packaged-app smoke helper.
# shellcheck disable=SC2329
preserve_release_verification_log() {
  local source=$1
  local destination_name=$2
  python3 - "$source" "$EVIDENCE_DIR/$destination_name" <<'PY'
import os
import sys
import tempfile
from pathlib import Path

source = Path(sys.argv[1])
destination = Path(sys.argv[2])
payload = source.read_bytes()
descriptor, temporary = tempfile.mkstemp(prefix=f".{destination.name}.", dir=destination.parent)
try:
    os.fchmod(descriptor, 0o600)
    with os.fdopen(descriptor, "wb", closefd=True) as output:
        output.write(payload)
        output.flush()
        os.fsync(output.fileno())
    os.replace(temporary, destination)
    directory = os.open(destination.parent, os.O_RDONLY | os.O_DIRECTORY)
    try:
        os.fsync(directory)
    finally:
        os.close(directory)
except BaseException:
    try:
        os.close(descriptor)
    except OSError:
        pass
    try:
        os.unlink(temporary)
    except FileNotFoundError:
        pass
    raise
PY
}
packaged_project_verifier_stub="$TMP_DIR/packaged-project-verifier-stub"
cat >"$packaged_project_verifier_stub" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
test "$1" = "verify-packaged-project"
shift
project=""
input_manifest=""
input_root=""
marker=""
app_version=""
token_sha256=""
executable=""
executable_sha256=""
executable_bytes=""
evidence=""
option_count=0
while [ "$#" -gt 0 ]; do
  test "$#" -ge 2
  case "$1" in
    --project) test -z "$project"; project=$2 ;;
    --input-manifest) test -z "$input_manifest"; input_manifest=$2 ;;
    --input-root) test -z "$input_root"; input_root=$2 ;;
    --marker) test -z "$marker"; marker=$2 ;;
    --app-version) test -z "$app_version"; app_version=$2 ;;
    --expected-release-verification-token-sha256)
      test -z "$token_sha256"
      token_sha256=$2
      ;;
    --expected-executable) test -z "$executable"; executable=$2 ;;
    --expected-executable-sha256)
      test -z "$executable_sha256"
      executable_sha256=$2
      ;;
    --expected-executable-bytes)
      test -z "$executable_bytes"
      executable_bytes=$2
      ;;
    --evidence) test -z "$evidence"; evidence=$2 ;;
    *) exit 1 ;;
  esac
  option_count=$((option_count + 1))
  shift 2
done
test "$option_count" -eq 10
home="$(dirname "$marker")"
test "$project" = "$home/Documents/EasySplat Projects/Release Verification.easysplatproj"
test -f "$input_manifest"
test -d "$input_root"
test "$marker" = "$home/release-verification-pipeline-passed.json"
test -f "$project/project.json"
test -f "$project/Output/splat.ply"
test "$app_version" = "0.2.0"
[[ "$token_sha256" =~ ^[0-9a-f]{64}$ ]]
test "$(python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$executable")" \
  = "$(cd "$home/../Applications/EasySplat.app/Contents/MacOS" && pwd -P)/EasySplatApp"
test "$executable_sha256" = "$(shasum -a 256 "$executable" | awk '{print $1}')"
test "$executable_bytes" = "$(stat -f '%z' "$executable")"
# The app carries its toolchain, so the stub reads its test switches out of the
# sealed payload the executable sits beside rather than from a manifest option.
toolchain_data="$(cd "$(dirname "$executable")/../Resources/Toolchain" && pwd -P)"
if [ -e "$toolchain_data/MutateInputDuringVerification" ]; then
  mutation_target="$(find "$input_root" -type f \
    ! -name release-input-manifest.json -print -quit)"
  test -n "$mutation_target"
  printf '%s\n' 'mutated during independent verification' >>"$mutation_target"
fi
if [ ! -e "$toolchain_data/SkipPackagedAttestation" ]; then
  python3 - "$evidence" "$marker" "$project" "$input_root" \
    "$app_version" "$token_sha256" "$executable" \
    "$executable_sha256" "$executable_bytes" "$input_manifest" <<'PY'
import base64
import hashlib
import json
import sys
from pathlib import Path

(
    evidence_path,
    marker_path,
    project_path,
    input_path,
    app_version,
    token_sha256,
    executable_path,
    executable_sha256,
    executable_bytes,
    input_manifest_path,
) = sys.argv[1:]
evidence_path = Path(evidence_path)
marker_path = Path(marker_path)
project_path = Path(project_path)
input_path = Path(input_path)
executable_path = Path(executable_path)
input_manifest_path = Path(input_manifest_path)
marker_data = marker_path.read_bytes()
marker = json.loads(marker_data)
metadata_data = (project_path / "project.json").read_bytes()
closure_sha256 = "e" * 64
capabilities = ["geometry.colmap", "runtime.core", "training.msplat"]

def digest(payload):
    return hashlib.sha256(payload).hexdigest()

def canonical_json(value):
    return json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":"))

lines = [
    "# EasySplat Packaged-App Release Attestation",
    "Schema: 1",
    "Status: passed",
    f"App version: {app_version}",
    f"Release verification token SHA-256: {token_sha256}",
    f"Executable path SHA-256: {digest(str(executable_path.resolve()).encode())}",
    f"Executable bytes: {executable_bytes}",
    f"Executable SHA-256: {executable_sha256}",
    f"Marker SHA-256: {digest(marker_data)}",
    f"Project root path SHA-256: {digest(str(project_path.resolve()).encode())}",
    f"Project metadata SHA-256: {digest(metadata_data)}",
    f"Input path SHA-256: {digest(str(input_path.resolve()).encode())}",
    f"Input manifest SHA-256: {digest(input_manifest_path.read_bytes())}",
    f"Input digest: {'d' * 64}",
    f"Output path SHA-256: {digest(marker['outputPlyPath'].encode())}",
    f"Toolchain version JSON: {canonical_json(app_version)}",
    f"Installed closure SHA-256: {closure_sha256}",
    f"Installation identity SHA-256: {'f' * 64}",
    "Installed component JSON: " + canonical_json({
        "name": "bundled-helpers",
        "sha256": closure_sha256,
    }),
    f"Installed capabilities JSON: {canonical_json(capabilities)}",
    "Integrity policy: signedAppBundle",
    f"Output bytes: {marker['outputBytes']}",
    f"Output vertices: {marker['outputVertices']}",
    f"Output format: {marker['outputFormat']}",
    f"Output SHA-256: {marker['outputSHA256']}",
]
evidence_path.write_text("\n".join(lines) + "\n", encoding="utf-8")
evidence_path.chmod(0o600)
PY
fi
printf '%s\n' "independent verifier invoked" >"$home/independent-verifier-proof"
SH
chmod +x "$packaged_project_verifier_stub"
# Consumed by packaged_app_bootstrap_smoke.sh.
# shellcheck disable=SC2034
PACKAGED_PROJECT_VERIFIER="$packaged_project_verifier_stub"
# shellcheck disable=SC2034
EXPECTED_VERSION="0.2.0"
mkdir -p "$INSTALLED_APP/Contents/MacOS" \
  "$INSTALLED_APP/Contents/Helpers/bin" \
  "$INSTALLED_APP/Contents/Resources/Toolchain"
/usr/bin/ditto "$toolchain_tree/bin" "$INSTALLED_APP/Contents/Helpers/bin"
cat >"$INSTALLED_EXECUTABLE" <<'PY'
#!/usr/bin/python3
import datetime
import hashlib
import json
import os
import sys
import time
import zipfile
from pathlib import Path

home = Path(os.environ["HOME"]).resolve()
if Path(os.environ.get("CFFIXED_USER_HOME", "")).resolve() != home:
    raise SystemExit("CFFIXED_USER_HOME escaped the verifier home")
tmp = Path(os.environ.get("TMPDIR", "")).resolve()
if tmp.parent != home or tmp.name != "tmp":
    raise SystemExit("TMPDIR escaped the verifier home")
if os.read(0, 1) != b"":
    raise SystemExit("packaged hook stdin was not /dev/null")
log = home / "packaged-app-wiring.log"
log_metadata = log.stat()
if os.fstat(1).st_ino != log_metadata.st_ino or os.fstat(2).st_ino != log_metadata.st_ino:
    raise SystemExit("packaged hook stdio escaped the verifier home")
if log_metadata.st_mode & 0o777 != 0o600:
    raise SystemExit("packaged hook log was not private")

executable = Path(__file__).resolve()
sentinel_root = executable.parents[1] / "Resources" / "Toolchain"
# The toolchain the app runs is the one sealed in its own bundle.
toolchain = executable.parents[1] / "Helpers"
capabilities = ["geometry.colmap", "runtime.core", "training.msplat"]

if sys.argv[2] != "--input-manifest" or sys.argv[4] != "--input-root":
    raise SystemExit("packaged hook did not receive the strict manifest input contract")
input_manifest = Path(sys.argv[3]).resolve()
input_path = Path(sys.argv[5]).resolve()
input_document = json.loads(input_manifest.read_text(encoding="utf-8"))
selected_inputs = [input_path / relative for relative in input_document["videos"]]
if input_document["photoFolder"] is not None:
    selected_inputs.append(input_path / input_document["photoFolder"])
write_probe = next(
    selected if selected.is_file() else next(
        path for path in selected.rglob("*") if path.is_file()
    )
    for selected in selected_inputs
)
try:
    with write_probe.open("ab") as handle:
        handle.write(b"unexpected packaged-app input mutation")
except PermissionError:
    pass
else:
    raise SystemExit("packaged hook could write its staged release input")
project = home / "Documents" / "EasySplat Projects" / "Release Verification.easysplatproj"
output = project / "Output" / "splat.ply"
output.parent.mkdir(parents=True)
ply = (
    b"ply\n"
    b"format ascii 1.0\n"
    b"element vertex 1\n"
    b"property float x\n"
    b"property float y\n"
    b"property float z\n"
    b"end_header\n"
    b"0 0 0\n"
)
output.write_bytes(ply)
output.chmod(0o644)
(project / "project.json").write_text("{}\n", encoding="utf-8")
marker = {
    "schemaVersion": 3,
    "releaseVerificationTokenSHA256": hashlib.sha256(
        os.environ["EASYSPLAT_RELEASE_VERIFY_TOKEN"].encode("utf-8")
    ).hexdigest(),
    "appVersion": "0.2.0",
    "executablePath": str(executable),
    "executableBytes": executable.stat().st_size,
    "executableSHA256": hashlib.sha256(executable.read_bytes()).hexdigest(),
    "toolchainRoot": str(toolchain.resolve()),
    "inputPath": str(input_path),
    "inputManifestSHA256": hashlib.sha256(input_manifest.read_bytes()).hexdigest(),
    "requestedCapabilities": capabilities,
    "projectRoot": str(project.resolve()),
    "outputPlyPath": str(output.resolve()),
    "outputBytes": len(ply),
    "outputVertices": 1,
    "outputFormat": "ascii",
    "outputSHA256": hashlib.sha256(ply).hexdigest(),
}
marker_path = home / "release-verification-pipeline-passed.json"
marker_path.write_text(
    json.dumps(marker, sort_keys=True, separators=(",", ":")),
    encoding="utf-8",
)
marker_path.chmod(0o600)
if (sentinel_root / "CorruptCoreAfterMarker").exists():
    # Leave enough time for a pre-exit verifier to observe the valid marker,
    # then try to rewrite a helper. The bundle is read-only under the sandbox,
    # so the attempt must end the run rather than reach the product.
    time.sleep(0.5)
    with (toolchain / "bin" / "colmap").open("ab") as handle:
        handle.write(b"tampered-after-marker")
(home / "hook-proof.json").write_text(
    json.dumps({"stdioInHome": True}),
    encoding="utf-8",
)
PY
chmod +x "$INSTALLED_EXECUTABLE"
packaged_hook_fixture="$TMP_DIR/packaged-hook-fixture"
mkdir -p "$packaged_hook_fixture"
printf 'fixture\n' >"$packaged_hook_fixture/view-1.png"
run_packaged_app_bootstrap_smoke "$packaged_hook_fixture"
hook_home="$SMOKE_INSTALL_ROOT/ReleaseVerificationHome"
packaged_sandbox_profile="$hook_home/packaged-app-verifier.sb"
packaged_developer_root="$(
  /usr/bin/env -u DEVELOPER_DIR /usr/bin/xcode-select -p
)"
packaged_python_runtime="$(
  DEVELOPER_DIR="$packaged_developer_root" \
    PYTHONNOUSERSITE=1 \
    /usr/bin/python3 -I - <<'PY'
import os
import sys

print(os.path.realpath(sys.executable))
PY
)"
python3 - \
  "$packaged_sandbox_profile" \
  "$INSTALLED_EXECUTABLE" \
  "$packaged_python_runtime" \
  "$INSTALLED_APP" <<'PY'
import json
import os
import re
import sys
from pathlib import Path

profile_path = Path(sys.argv[1])
installed_executable = os.path.realpath(sys.argv[2])
python_runtime = os.path.realpath(sys.argv[3])
installed_app = os.path.realpath(sys.argv[4])

profile = profile_path.read_text(encoding="utf-8")

process_lines = [
    line for line in profile.splitlines()
    if line.startswith("(allow process-exec ")
]
if len(process_lines) != 1:
    raise SystemExit("Generated packaged-app profile has no unique process-exec rule.")
process_paths = [
    json.loads(value)
    for value in re.findall(r"\(literal (\"(?:\\.|[^\"\\])*\")\)", process_lines[0])
]
toolchain_bin = os.path.join(installed_app, "Contents", "Helpers", "bin")
expected_process_paths = [
    "/bin/cat",
    "/usr/bin/env",
    "/usr/bin/file",
    "/usr/bin/touch",
    installed_executable,
    python_runtime,
    *(os.path.join(toolchain_bin, name)
      for name in ("colmap", "ffmpeg", "easysplat-train")),
]
python_app_helper = Path(python_runtime).parent.parent / "Resources/Python.app/Contents/MacOS/Python"
if python_app_helper.is_file():
    expected_process_paths.append(os.path.realpath(python_app_helper))
if process_paths != expected_process_paths:
    raise SystemExit(
        "Generated packaged-app process allowlist does not exactly match "
        f"the authenticated core route. Expected {expected_process_paths!r}; "
        f"found {process_paths!r}."
    )
if profile.count("(allow process-fork)") != 1 or "(allow process*)" in profile:
    raise SystemExit("Generated packaged-app profile has unsafe process rights.")

fixed_broker_denies = (
    "com.apple.cfprefsd.agent",
    "com.apple.cfprefsd.daemon",
    "com.apple.coreservices.launchservicesd",
    "com.apple.lsd.mapdb",
    "com.apple.lsd.modifydb",
    "com.apple.runningboard",
    "com.apple.runningboardd",
)
for service in fixed_broker_denies:
    rule = f'(deny mach-lookup (global-name "{service}"))'
    if profile.count(rule) != 1:
        raise SystemExit(
            f"Generated packaged-app profile lacks the exact {service} broker deny."
        )
if len(re.findall(
    r'^\(deny mach-lookup \(global-name '
    r'"com\.easysplat\.releaseverify\.[0-9A-Fa-f-]+\.deny"\)\)$',
    profile,
    flags=re.MULTILINE,
)) != 1:
    raise SystemExit("Generated packaged-app profile lacks its token-bound broker deny.")
PY
python3 - "$hook_home/hook-proof.json" <<'PY'
import json
import sys
from pathlib import Path

proof = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
if proof != {"stdioInHome": True}:
    raise SystemExit("Packaged-bootstrap behavioral smoke did not prove stdio isolation.")
PY
test -s "$hook_home/release-verification-pipeline-passed.json"
test -s "$hook_home/packaged-app-attestation.md"
test -s "$hook_home/Documents/EasySplat Projects/Release Verification.easysplatproj/Output/splat.ply"
test "$(cat "$hook_home/independent-verifier-proof")" = "independent verifier invoked"
# The app runs the tools it carries, so a verified run installs nothing.
test ! -e "$hook_home/Library/Application Support/EasySplat/Toolchains"
test -z "$APP_WIRING_PID"
test -z "$APP_WIRING_LOG"
test -z "$APP_WIRING_TOKEN"

rm -rf "$hook_home" "$SMOKE_INSTALL_ROOT/ReleaseVerificationInput"
touch "$INSTALLED_APP/Contents/Resources/Toolchain/MutateInputDuringVerification"
input_mutation_error="$TMP_DIR/packaged-bootstrap-input-mutation.stderr"
if run_packaged_app_bootstrap_smoke "$packaged_hook_fixture" \
  >/dev/null 2>"$input_mutation_error"; then
  echo "Packaged-bootstrap smoke accepted an input mutated during independent verification." >&2
  exit 1
fi
grep -Fq 'The release fixture or staged input changed during packaged-app verification.' \
  "$input_mutation_error"
cleanup_packaged_app_verification_processes || true
APP_WIRING_TOKEN=""
APP_WIRING_LOG=""
rm -f "$INSTALLED_APP/Contents/Resources/Toolchain/MutateInputDuringVerification"

rm -rf "$hook_home" "$SMOKE_INSTALL_ROOT/ReleaseVerificationInput"
touch "$INSTALLED_APP/Contents/Resources/Toolchain/SkipPackagedAttestation"
missing_attestation_error="$TMP_DIR/packaged-bootstrap-missing-attestation.stderr"
if run_packaged_app_bootstrap_smoke "$packaged_hook_fixture" \
  >/dev/null 2>"$missing_attestation_error"; then
  echo "Packaged-bootstrap smoke accepted a missing independent attestation." >&2
  exit 1
fi
grep -Fq 'Independent packaged-app attestation is missing, unsafe, or unbound.' \
  "$missing_attestation_error"
test -d "$hook_home/Documents/EasySplat Projects/Release Verification.easysplatproj"
test -s "$hook_home/release-verification-pipeline-passed.json"
cleanup_packaged_app_verification_processes || true
APP_WIRING_TOKEN=""
APP_WIRING_LOG=""
rm -f "$INSTALLED_APP/Contents/Resources/Toolchain/SkipPackagedAttestation"

rm -rf "$hook_home" "$SMOKE_INSTALL_ROOT/ReleaseVerificationInput"
touch "$INSTALLED_APP/Contents/Resources/Toolchain/CorruptAttestationDuringPostChecks"
corrupt_attestation_error="$TMP_DIR/packaged-bootstrap-corrupt-attestation.stderr"
if run_packaged_app_bootstrap_smoke "$packaged_hook_fixture" \
  >/dev/null 2>"$corrupt_attestation_error"; then
  echo "Packaged-bootstrap smoke accepted an attestation replaced after verification." >&2
  exit 1
fi
grep -Fq 'Independent packaged-app attestation changed after verification.' \
  "$corrupt_attestation_error"
test -d "$hook_home/Documents/EasySplat Projects/Release Verification.easysplatproj"
test -s "$hook_home/release-verification-pipeline-passed.json"
cleanup_packaged_app_verification_processes || true
APP_WIRING_TOKEN=""
APP_WIRING_LOG=""
rm -f "$INSTALLED_APP/Contents/Resources/Toolchain/CorruptAttestationDuringPostChecks"

swift build --package-path "$ROOT" -c release --product EasySplatReleaseVerifier
repository_packaged_project_verifier="$(
  swift build --package-path "$ROOT" -c release --show-bin-path
)/EasySplatReleaseVerifier"
fabricated_project_error="$TMP_DIR/fabricated-packaged-project.stderr"
fabricated_project_evidence="$TMP_DIR/fabricated-packaged-project-evidence.md"
fabricated_marker_token_sha256="$(python3 - "$hook_home/release-verification-pipeline-passed.json" <<'PY'
import json
import sys
from pathlib import Path

print(json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))["releaseVerificationTokenSHA256"])
PY
)"
newline_project_path="$TMP_DIR/project"$'\nStatus: passed'
newline_project_error="$TMP_DIR/newline-packaged-project.stderr"
newline_project_evidence="$TMP_DIR/newline-packaged-project-evidence.md"
if "$repository_packaged_project_verifier" verify-packaged-project \
  --project "$newline_project_path" \
  --input-manifest "$SMOKE_INSTALL_ROOT/ReleaseVerificationInput/release-input-manifest.json" \
  --input-root "$SMOKE_INSTALL_ROOT/ReleaseVerificationInput" \
  --marker "$hook_home/release-verification-pipeline-passed.json" \
  --app-version "0.2.0" \
  --expected-release-verification-token-sha256 "$fabricated_marker_token_sha256" \
  --expected-executable "$INSTALLED_EXECUTABLE" \
  --expected-executable-sha256 "$(shasum -a 256 "$INSTALLED_EXECUTABLE" | awk '{print $1}')" \
  --expected-executable-bytes "$(stat -f '%z' "$INSTALLED_EXECUTABLE")" \
  --evidence "$newline_project_evidence" \
  >/dev/null 2>"$newline_project_error"; then
  echo "Independent packaged-project verification accepted a control character in a path." >&2
  exit 1
fi
grep -Fq 'Usage: EasySplatReleaseVerifier verify-packaged-project' \
  "$newline_project_error"
test ! -e "$newline_project_evidence"
if "$repository_packaged_project_verifier" verify-packaged-project \
  --project "$hook_home/Documents/EasySplat Projects/Release Verification.easysplatproj" \
  --input-manifest "$SMOKE_INSTALL_ROOT/ReleaseVerificationInput/release-input-manifest.json" \
  --input-root "$SMOKE_INSTALL_ROOT/ReleaseVerificationInput" \
  --marker "$hook_home/release-verification-pipeline-passed.json" \
  --app-version "0.2.0" \
  --expected-release-verification-token-sha256 "$fabricated_marker_token_sha256" \
  --expected-executable "$INSTALLED_EXECUTABLE" \
  --expected-executable-sha256 "$(shasum -a 256 "$INSTALLED_EXECUTABLE" | awk '{print $1}')" \
  --expected-executable-bytes "$(stat -f '%z' "$INSTALLED_EXECUTABLE")" \
  --evidence "$fabricated_project_evidence" \
  >/dev/null 2>"$fabricated_project_error"; then
  echo "Independent packaged-project verification accepted fabricated metadata and a non-splat PLY." >&2
  exit 1
fi
grep -Fq 'Packaged project verification failed:' "$fabricated_project_error"

rm -rf "$hook_home" "$SMOKE_INSTALL_ROOT/ReleaseVerificationInput"
touch "$INSTALLED_APP/Contents/Resources/Toolchain/CorruptCoreAfterMarker"
corrupt_hook_error="$TMP_DIR/packaged-bootstrap-corrupt-core.stderr"
if run_packaged_app_bootstrap_smoke "$packaged_hook_fixture" \
  >/dev/null 2>"$corrupt_hook_error"; then
  echo "Packaged app rewrote the toolchain sealed inside its own bundle." >&2
  exit 1
fi
grep -Fq 'Installed app exited unsuccessfully after writing its pipeline marker.' \
  "$corrupt_hook_error"
grep -Fq 'Packaged-app wiring smoke failed.' "$corrupt_hook_error"
cleanup_packaged_app_verification_processes || true
APP_WIRING_TOKEN=""
rm -f "$APP_WIRING_LOG"
APP_WIRING_LOG=""
rm -f "$INSTALLED_APP/Contents/Resources/Toolchain/CorruptCoreAfterMarker"
rm -rf "$hook_home" "$SMOKE_INSTALL_ROOT/ReleaseVerificationInput"
inspection_failure_error="$TMP_DIR/packaged-bootstrap-inspection.stderr"
# Overrides the sourced inspector for this fail-closed fixture.
# shellcheck disable=SC2329
easysplat_audit_and_drain_verification_processes() {
  return 73
}
if run_packaged_app_bootstrap_smoke "$packaged_hook_fixture" \
  >/dev/null 2>"$inspection_failure_error"; then
  echo "Packaged-bootstrap smoke accepted a failed residual-process inspection." >&2
  exit 1
fi
grep -Fq 'could not prove residual-process quiescence' "$inspection_failure_error"
# Restore the real process inspector before cleaning the failed proof attempt.
# shellcheck source=../release/lib/token_process_cleanup.sh
source "$ROOT/scripts/release/lib/token_process_cleanup.sh"
easysplat_cleanup_token_processes "$APP_WIRING_TOKEN"
APP_WIRING_TOKEN=""
APP_WIRING_LOG=""
if remove_packaged_app_smoke_installation 2>/dev/null; then
  echo "Packaged smoke cleanup deleted project evidence before attestation preservation." >&2
  exit 1
fi
test -n "$SMOKE_INSTALL_ROOT"
test -e "$hook_home/release-verification-pipeline-passed.json"
# Consumed by remove_packaged_app_smoke_installation.
# shellcheck disable=SC2034
PACKAGED_APP_ATTESTATION_PRESERVED=1
remove_packaged_app_smoke_installation
test -z "$SMOKE_INSTALL_ROOT"
test ! -e "$hook_home"
unset -f preserve_release_verification_log
EVIDENCE_DIR=""

production_error="$TMP_DIR/production.stderr"
production_xcodebuild_log="$TMP_DIR/production-xcodebuild.log"
rm -f "$production_xcodebuild_log"
if EASYSPLAT_XCODEBUILD_BIN="$mock_xcodebuild" \
  EASYSPLAT_TEST_XCODEBUILD_LOG="$production_xcodebuild_log" \
  "$ROOT/scripts/release/build_app.sh" \
  --build-root "$release_test_build_root" \
  --toolchain-dir "$toolchain_tree" \
  --project-url "$project_url" \
  --version "1.0.0" \
  --source-commit "$test_source_commit" \
  --identity-fingerprint "$signed_fingerprint" \
  --team-id "$signed_team_id" \
  --production >/dev/null 2>"$production_error"; then
  echo "Production app build accepted a command override." >&2
  exit 1
fi
grep -Fqi 'Signed build command overrides are not permitted' "$production_error"
if [ -e "$production_xcodebuild_log" ]; then
  echo "Production app build executed an overridden xcodebuild binary." >&2
  exit 1
fi

production_dmg_command_fixture="$TMP_DIR/production-dmg-command-fixture"
production_dmg_command_log="$TMP_DIR/production-dmg-command.log"
cat >"$production_dmg_command_fixture" <<'EOF'
#!/bin/bash
set -eu
umask 077
: "${EASYSPLAT_TEST_PRODUCTION_DMG_COMMAND_LOG:?}"
/usr/bin/printf '%s\n' "$0" "$@" >>"$EASYSPLAT_TEST_PRODUCTION_DMG_COMMAND_LOG"
exit 97
EOF
chmod 700 "$production_dmg_command_fixture"
production_dmg_build_root="$TMP_DIR/production-dmg-build"
production_dmg_output="$TMP_DIR/production-dmg-output"
production_dmg_error="$TMP_DIR/production-dmg.stderr"
if EASYSPLAT_TEST_PRODUCTION_DMG_COMMAND_LOG="$production_dmg_command_log" \
  EASYSPLAT_XCODEBUILD_BIN="$production_dmg_command_fixture" \
  EASYSPLAT_CODESIGN_BIN="$production_dmg_command_fixture" \
  EASYSPLAT_HDIUTIL_BIN="$production_dmg_command_fixture" \
  EASYSPLAT_NOTARY_TEST_MODE=1 \
  "$ROOT/scripts/release/build_dmg.sh" \
  --app-version "0.2.0" \
  --toolchain-version "2.0.0" \
  --toolchain-dir "$toolchain_tree" \
  --build-root "$production_dmg_build_root" \
  --output-dir "$production_dmg_output" \
  --production \
  --identity-fingerprint "$signed_fingerprint" \
  --team-id "$signed_team_id" \
  --notary-keychain-profile easysplat-release \
  >/dev/null 2>"$production_dmg_error"; then
  echo "Production DMG build accepted command or notarization overrides." >&2
  exit 1
fi
grep -Fq 'Production build command overrides are not permitted.' "$production_dmg_error"
if [ -e "$production_dmg_command_log" ] \
    || [ -e "$production_dmg_build_root" ] \
    || [ -e "$production_dmg_output" ]; then
  echo "Rejected production overrides reached build, signing, or notarization work." >&2
  exit 1
fi

missing_signed_identity_error="$TMP_DIR/missing-signed-identity.stderr"
if "$ROOT/scripts/release/build_app.sh" \
  --build-root "$release_test_build_root" \
  --toolchain-dir "$toolchain_tree" \
  --version "0.2.0" \
  --source-commit "$test_source_commit" \
  --production >/dev/null 2>"$missing_signed_identity_error"; then
  echo "Production app build accepted a missing Developer ID identity." >&2
  exit 1
fi
grep -Fqi 'exact 40-hex signing identity fingerprint' "$missing_signed_identity_error"

unsigned_signing_argument_error="$TMP_DIR/unsigned-signing-argument.stderr"
if "$ROOT/scripts/release/build_app.sh" \
  --build-root "$release_test_build_root" \
  --toolchain-dir "$toolchain_tree" \
  --version "0.2.0" \
  --development-unsigned \
  --identity-fingerprint "$signed_fingerprint" >/dev/null 2>"$unsigned_signing_argument_error"; then
  echo "Unsigned developer app build accepted a signing identity." >&2
  exit 1
fi
grep -Fqi 'require --production' "$unsigned_signing_argument_error"

mode_error="$TMP_DIR/mode.stderr"
if "$ROOT/scripts/release/build_app.sh" \
  --build-root "$release_test_build_root" \
  --toolchain-dir "$toolchain_tree" \
  --version "0.2.0" \
  --development-unsigned \
  --production >/dev/null 2>"$mode_error"; then
  echo "App build accepted conflicting release modes" >&2
  exit 1
fi
grep -Fqi 'exactly one release mode' "$mode_error"

missing_release_mode_error="$TMP_DIR/missing-release-mode.stderr"
if "$ROOT/scripts/release/build_dmg.sh" \
  --app-version "0.2.0" \
  --toolchain-version "2.0.0" \
  --toolchain-dir "$toolchain_tree" >/dev/null 2>"$missing_release_mode_error"; then
  echo "Packaging accepted a missing release mode" >&2
  exit 1
fi
grep -Fq 'Usage: build_dmg.sh' "$missing_release_mode_error"

missing_signed_dmg_identity_error="$TMP_DIR/missing-signed-dmg-identity.stderr"
if "$ROOT/scripts/release/build_dmg.sh" \
  --app-version "0.2.0" \
  --toolchain-version "2.0.0" \
  --toolchain-dir "$toolchain_tree" \
  --production >/dev/null 2>"$missing_signed_dmg_identity_error"; then
  echo "Production packaging accepted a missing Developer ID identity." >&2
  exit 1
fi
grep -Fqi 'exact 40-hex Developer ID fingerprint' "$missing_signed_dmg_identity_error"

unsafe_notary_profile_error="$TMP_DIR/unsafe-notary-profile.stderr"
if "$ROOT/scripts/release/build_dmg.sh" \
  --app-version "0.2.0" \
  --toolchain-version "2.0.0" \
  --toolchain-dir "$toolchain_tree" \
  --production \
  --identity-fingerprint "$signed_fingerprint" \
  --team-id "$signed_team_id" \
  --notary-keychain-profile 'unsafe profile' \
  >/dev/null 2>"$unsafe_notary_profile_error"; then
  echo "Production packaging accepted an unsafe notary profile name." >&2
  exit 1
fi
grep -Fqi 'safe 1-64 character notary keychain profile' "$unsafe_notary_profile_error"

unsigned_notary_argument_error="$TMP_DIR/unsigned-notary-argument.stderr"
if "$ROOT/scripts/release/build_dmg.sh" \
  --app-version "0.2.0" \
  --toolchain-version "2.0.0" \
  --toolchain-dir "$toolchain_tree" \
  --development-unsigned \
  --notary-keychain-profile easysplat-release \
  >/dev/null 2>"$unsigned_notary_argument_error"; then
  echo "Unsigned developer packaging accepted a notary profile." >&2
  exit 1
fi
grep -Fqi 'require --production' "$unsigned_notary_argument_error"

dmg_build_metadata_error="$TMP_DIR/build-dmg-metadata.stderr"
if "$ROOT/scripts/release/build_dmg.sh" \
  --app-version "0.2.0+build.7" \
  --toolchain-version "2.0.0+build.7" \
  --toolchain-dir "$toolchain_tree" \
  --development-unsigned >/dev/null 2>"$dmg_build_metadata_error"; then
  echo "Unsigned developer packaging accepted SemVer build metadata." >&2
  exit 1
fi
grep -Fq 'without build metadata' "$dmg_build_metadata_error"

signed_dmg_fixture="$TMP_DIR/signed-dmg-fixture"
mkdir -p \
  "$signed_dmg_fixture/scripts/release/lib" \
  "$signed_dmg_fixture/ThirdParty/MetalSplatter" \
  "$signed_dmg_fixture/prepared/toolchain/out/bin" \
  "$signed_dmg_fixture/prepared/toolchain/out/lib" \
  "$signed_dmg_fixture/prepared/toolchain/out/supply-chain" \
  "$signed_dmg_fixture/prepared/product/EasySplat.app/Contents/MacOS" \
  "$signed_dmg_fixture/prepared/product/EasySplat.app/Contents/Helpers/bin" \
  "$signed_dmg_fixture/prepared/product/EasySplat.app/Contents/Helpers/lib" \
  "$signed_dmg_fixture/prepared/product/EasySplat.app/Contents/Resources/Toolchain" \
  "$signed_dmg_fixture/prepared/product/EasySplat.app.dSYM/Contents/Resources/DWARF" \
  "$signed_dmg_fixture/mock-bin"
cp "$ROOT/scripts/release/build_dmg.sh" \
  "$signed_dmg_fixture/scripts/release/build_dmg.sh"
cp "$ROOT/scripts/release/publish_release_files.py" \
  "$signed_dmg_fixture/scripts/release/publish_release_files.py"
cp "$ROOT/scripts/release/prepared_release.py" \
  "$signed_dmg_fixture/scripts/release/prepared_release.py"
cp "$ROOT/scripts/release/verify_notarization_receipt.py" \
  "$signed_dmg_fixture/scripts/release/verify_notarization_receipt.py"
cp "$ROOT/scripts/release/lib/strict_semver.sh" \
  "$signed_dmg_fixture/scripts/release/lib/strict_semver.sh"
# A prepared release carries the built toolchain tree and the copy already
# sealed inside the app, so the fixture stages both instead of archives.
# Packaging reads the tree from the prepared root, which is why it is the whole
# tree rather than the handful of files the manifest requires.
rm -rf "$signed_dmg_fixture/prepared/toolchain/out"
/usr/bin/ditto "$toolchain_tree" "$signed_dmg_fixture/prepared/toolchain/out"
prepared_app_contents="$signed_dmg_fixture/prepared/product/EasySplat.app/Contents"
cp "$toolchain_tree/bin/colmap" "$prepared_app_contents/Helpers/bin/colmap"
cp "$toolchain_tree/bin/easysplat-train" "$prepared_app_contents/Helpers/bin/easysplat-train"
cp "$toolchain_tree/lib/libomp.dylib" "$prepared_app_contents/Helpers/lib/libomp.dylib"
cp "$toolchain_tree/bin/default.metallib" \
  "$prepared_app_contents/Resources/Toolchain/default.metallib"
printf '%s\n' 'fixture license' >"$signed_dmg_fixture/LICENSE"
printf '%s\n' 'fixture notice' >"$signed_dmg_fixture/NOTICE.md"
printf '%s\n' 'fixture viewer license' \
  >"$signed_dmg_fixture/ThirdParty/MetalSplatter/LICENSE"
printf '%s' 'prepared app' \
  >"$signed_dmg_fixture/prepared/product/EasySplat.app/Contents/MacOS/EasySplatApp"
chmod 0755 \
  "$signed_dmg_fixture/prepared/product/EasySplat.app/Contents/MacOS/EasySplatApp"
printf '%s' 'prepared symbols' \
  >"$signed_dmg_fixture/prepared/product/EasySplat.app.dSYM/Contents/Resources/DWARF/EasySplatApp"
cat >"$signed_dmg_fixture/prepared/product/EasySplat.app/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>EasySplatReleaseChannel</key><string>prepare-release</string>
</dict></plist>
EOF
printf '%s' 'prepared release candidate' \
  >"$signed_dmg_fixture/prepared/product/EasySplat.app/Contents/Resources/release_channel.txt"
/usr/bin/python3 -I "$signed_dmg_fixture/scripts/release/prepared_release.py" create \
  --root "$signed_dmg_fixture/prepared" \
  --source-repository dud8/EasySplat \
  --source-commit 0123456789abcdef0123456789abcdef01234567 \
  --app-version 0.2.0 \
  --toolchain-version 2.0.0 \
  --run-id 1 \
  --run-attempt 1 \
  --builder-environment github-hosted \
  --xcode-version 16.4 \
  --xcode-build 16F6 \
  --macos-sdk-version 15.5

cat >"$signed_dmg_fixture/scripts/release/build_app.sh" <<'PY'
#!/usr/bin/env python3
import hashlib
import json
import os
import stat
import struct
import sys
from pathlib import Path

def artifact_digest(root: Path) -> str:
    digest = hashlib.sha256()
    paths = [
        root,
        *sorted(
            root.rglob("*"),
            key=lambda path: path.relative_to(root).as_posix(),
        ),
    ]
    for path in paths:
        metadata = path.lstat()
        relative = "." if path == root else path.relative_to(root).as_posix()
        relative_bytes = relative.encode("utf-8", errors="surrogateescape")
        digest.update(b"D" if stat.S_ISDIR(metadata.st_mode) else b"F")
        digest.update(struct.pack(">Q", len(relative_bytes)))
        digest.update(relative_bytes)
        digest.update(struct.pack(">I", stat.S_IMODE(metadata.st_mode)))
        if stat.S_ISREG(metadata.st_mode):
            data = path.read_bytes()
            digest.update(struct.pack(">Q", len(data)))
            digest.update(hashlib.sha256(data).digest())
    return digest.hexdigest()

arguments = sys.argv[1:]
values = {}
for index, value in enumerate(arguments):
    if value.startswith("--") and index + 1 < len(arguments) and not arguments[index + 1].startswith("--"):
        values[value] = arguments[index + 1]
with Path(os.environ["FAKE_RELEASE_LOG"]).open("a", encoding="utf-8") as handle:
    handle.write(json.dumps(["build-app", *arguments], separators=(",", ":")) + "\n")
build_root = Path(values["--build-root"])
export = build_root / "Export"
app = export / "EasySplat.app"
(app / "Contents/MacOS").mkdir(parents=True)
(app / "Contents/MacOS/EasySplatApp").write_bytes(b"signed app")
dsym = export / "EasySplat.app.dSYM/Contents/Resources/DWARF"
dsym.mkdir(parents=True)
(dsym / "EasySplatApp").write_bytes(b"symbols")
fingerprint = values["--identity-fingerprint"].upper()
team_id = values["--team-id"]
codesign = {
    "hardenedRuntime": True,
    "leafCertificateSHA1": fingerprint,
    "teamIdentifier": team_id,
    "timestamp": "Jul 18, 2026 at 11:45:00 PM",
}
app_post_sign_sha256 = artifact_digest(app)
receipt = {
    "schemaVersion": 1,
    "rootKind": "app",
    "identityFingerprintSHA1": fingerprint,
    "teamID": team_id,
    "artifactDigest": {
        "format": "sha256-tree-v1",
        "postSignSHA256": app_post_sign_sha256,
    },
    "tree": {"postSignManifestSHA256": "a" * 64},
    "entries": [{
        "kind": "appBundle",
        "relativePath": ".",
        "postSignSHA256": "a" * 64,
        "identityFingerprintSHA1": fingerprint,
        "teamID": team_id,
        "codesign": codesign,
    }],
}
(export / "EasySplat.app-signing.json").write_text(
    json.dumps(receipt), encoding="utf-8"
)
PY
cat >"$signed_dmg_fixture/scripts/release/create_dmg.sh" <<'PY'
#!/usr/bin/env python3
import json
import os
import sys
from pathlib import Path

arguments = sys.argv[1:]
values = dict(zip(arguments[::2], arguments[1::2]))
with Path(os.environ["FAKE_RELEASE_LOG"]).open("a", encoding="utf-8") as handle:
    handle.write(json.dumps(["create-dmg", *arguments], separators=(",", ":")) + "\n")
Path(values["--out"]).write_bytes(b"unsigned disk image")
PY
cat >"$signed_dmg_fixture/scripts/release/sign_macos_distribution.py" <<'PY'
#!/usr/bin/env python3
import hashlib
import json
import os
import re
import stat
import struct
import sys
from pathlib import Path


def artifact_digest(root: Path) -> str:
    if root.is_file():
        return hashlib.sha256(root.read_bytes()).hexdigest()
    digest = hashlib.sha256()
    paths = [
        root,
        *sorted(
            root.rglob("*"),
            key=lambda path: path.relative_to(root).as_posix(),
        ),
    ]
    for path in paths:
        metadata = path.lstat()
        relative = "." if path == root else path.relative_to(root).as_posix()
        relative_bytes = relative.encode("utf-8", errors="surrogateescape")
        digest.update(b"D" if stat.S_ISDIR(metadata.st_mode) else b"F")
        digest.update(struct.pack(">Q", len(relative_bytes)))
        digest.update(relative_bytes)
        digest.update(struct.pack(">I", stat.S_IMODE(metadata.st_mode)))
        if stat.S_ISREG(metadata.st_mode):
            data = path.read_bytes()
            digest.update(struct.pack(">Q", len(data)))
            digest.update(hashlib.sha256(data).digest())
    return digest.hexdigest()

arguments = sys.argv[1:]
values = {}
verify_only = False
bind_receipt_to_current_artifact = False
index = 0
while index < len(arguments):
    argument = arguments[index]
    if argument == "--verify-only":
        verify_only = True
        index += 1
        continue
    if argument == "--bind-receipt-to-current-artifact":
        bind_receipt_to_current_artifact = True
        index += 1
        continue
    if not argument.startswith("--") or index + 1 >= len(arguments):
        raise SystemExit("invalid fake signer arguments")
    values[argument] = arguments[index + 1]
    index += 2

artifact = Path(values["--root"])
fingerprint = values["--identity-fingerprint"].upper()
team_id = values["--team-id"]
kind = values["--kind"]
receipt_path = Path(values["--receipt"])
with Path(os.environ["FAKE_RELEASE_LOG"]).open("a", encoding="utf-8") as handle:
    event = "verify-signature" if verify_only else "sign"
    handle.write(json.dumps([event, *arguments], separators=(",", ":")) + "\n")


def validate_receipt() -> None:
    payload = json.loads(receipt_path.read_text(encoding="utf-8"))
    if (
        payload.get("schemaVersion") != 1
        or payload.get("rootKind") != kind
        or payload.get("identityFingerprintSHA1") != fingerprint
        or payload.get("teamID") != team_id
    ):
        raise SystemExit("fake signing receipt has the wrong root identity")
    entries = payload.get("entries")
    if not isinstance(entries, list) or not entries:
        raise SystemExit("fake signing receipt has no entries")
    for entry in entries:
        codesign = entry.get("codesign")
        if (
            entry.get("identityFingerprintSHA1") != fingerprint
            or entry.get("teamID") != team_id
            or not isinstance(codesign, dict)
            or codesign.get("leafCertificateSHA1") != fingerprint
            or codesign.get("teamIdentifier") != team_id
            or not codesign.get("timestamp")
            or (kind != "dmg" and codesign.get("hardenedRuntime") is not True)
        ):
            raise SystemExit("fake signing receipt has invalid codesign evidence")
    if kind == "app":
        tree = payload.get("tree")
        if (
            not isinstance(tree, dict)
            or re.fullmatch(
                r"[0-9a-f]{64}", str(tree.get("postSignManifestSHA256", ""))
            )
            is None
            or not any(
                entry.get("kind") == "appBundle"
                and entry.get("relativePath") == "."
                for entry in entries
            )
        ):
            raise SystemExit("fake app signing receipt has invalid tree evidence")
    elif len(entries) != 1 or entries[0].get("kind") != "diskImage":
        raise SystemExit("fake DMG signing receipt has invalid entries")


if verify_only:
    validate_receipt()
    if bind_receipt_to_current_artifact:
        receipt = json.loads(receipt_path.read_text(encoding="utf-8"))
        current_digest = artifact_digest(artifact)
        if receipt.get("artifactDigest", {}).get("postSignSHA256") != current_digest:
            raise SystemExit("fake signing receipt does not bind current bytes")
    raise SystemExit(0)
if kind == "app" and artifact.is_dir():
    signature = artifact / "Contents/_CodeSignature/CodeResources"
    signature.parent.mkdir(parents=True, exist_ok=True)
    signature.write_bytes(b"signed")
    post_sign_sha256 = artifact_digest(artifact)
    payload = {
        "schemaVersion": 1,
        "rootKind": kind,
        "identityFingerprintSHA1": fingerprint,
        "teamID": team_id,
        "artifactDigest": {
            "format": "sha256-tree-v1",
            "postSignSHA256": post_sign_sha256,
        },
        "tree": {"postSignManifestSHA256": "a" * 64},
        "entries": [{
            "kind": "appBundle",
            "relativePath": ".",
            "postSignSHA256": "a" * 64,
            "identityFingerprintSHA1": fingerprint,
            "teamID": team_id,
            "codesign": {
                "hardenedRuntime": True,
                "leafCertificateSHA1": fingerprint,
                "teamIdentifier": team_id,
                "timestamp": "Jul 18, 2026 at 11:45:00 PM",
            },
        }],
    }
    receipt_path.write_text(json.dumps(payload), encoding="utf-8")
    validate_receipt()
    raise SystemExit(0)
if kind != "dmg" or not artifact.is_file():
    raise SystemExit("the fake signer requires an app or disk image")
artifact.write_bytes(artifact.read_bytes() + b"\nsigned")
post_sign_sha256 = hashlib.sha256(artifact.read_bytes()).hexdigest()
payload = {
    "schemaVersion": 1,
    "rootKind": kind,
    "identityFingerprintSHA1": fingerprint,
    "teamID": team_id,
    "artifactDigest": {
        "format": "sha256-file-v1",
        "postSignSHA256": post_sign_sha256,
    },
    "entries": [{
        "kind": "diskImage",
        "postSignSHA256": post_sign_sha256,
        "identityFingerprintSHA1": fingerprint,
        "teamID": team_id,
        "codesign": {
            "hardenedRuntime": False,
            "leafCertificateSHA1": fingerprint,
            "teamIdentifier": team_id,
            "timestamp": "Jul 18, 2026 at 11:45:00 PM",
        },
    }],
}
receipt_path.write_text(json.dumps(payload), encoding="utf-8")
validate_receipt()
PY
cat >"$signed_dmg_fixture/scripts/release/notarize_artifact.sh" <<'PY'
#!/usr/bin/env python3
import hashlib
import json
import os
import stat
import struct
import sys
from pathlib import Path


def artifact_digest(root: Path) -> str:
    if root.is_file():
        return hashlib.sha256(root.read_bytes()).hexdigest()
    digest = hashlib.sha256()
    paths = [
        root,
        *sorted(
            root.rglob("*"),
            key=lambda path: path.relative_to(root).as_posix(),
        ),
    ]
    for path in paths:
        metadata = path.lstat()
        relative = "." if path == root else path.relative_to(root).as_posix()
        relative_bytes = relative.encode("utf-8", errors="surrogateescape")
        digest.update(b"D" if stat.S_ISDIR(metadata.st_mode) else b"F")
        digest.update(struct.pack(">Q", len(relative_bytes)))
        digest.update(relative_bytes)
        digest.update(struct.pack(">I", stat.S_IMODE(metadata.st_mode)))
        if stat.S_ISREG(metadata.st_mode):
            data = path.read_bytes()
            digest.update(struct.pack(">Q", len(data)))
            digest.update(hashlib.sha256(data).digest())
    return digest.hexdigest()


arguments = sys.argv[1:]
values = dict(zip(arguments[::2], arguments[1::2]))
artifact_type = values["--type"]
with Path(os.environ["FAKE_RELEASE_LOG"]).open("a", encoding="utf-8") as handle:
    handle.write(json.dumps(["notarize", *arguments], separators=(",", ":")) + "\n")
if os.environ.get("FAKE_FAIL_NOTARY_TYPE") == artifact_type:
    raise SystemExit(9)
artifact = Path(values["--artifact"])
pre_digest = artifact_digest(artifact)
if artifact.is_dir():
    ticket = artifact / "Contents/_CodeSignature/notary-ticket"
    ticket.parent.mkdir(parents=True, exist_ok=True)
    ticket.write_bytes(b"ticket")
else:
    artifact.write_bytes(artifact.read_bytes() + b"\nticket")
post_digest = artifact_digest(artifact)
if post_digest == pre_digest:
    raise SystemExit("fake stapling did not change the artifact")
verification = {
    "codesign": "passed",
    "systemPolicy": "passed" if artifact_type == "app" else "notApplicable",
    "stapler": "passed",
    "gatekeeper": "passed",
}
Path(values["--receipt"]).write_text(
    json.dumps({
        "schemaVersion": 1,
        "artifactType": artifact_type,
        "artifactDigestFormat": (
            "sha256-tree-v1" if artifact_type == "app" else "sha256-file-v1"
        ),
        "submissionID": "a2a4ed8f-4d52-47d5-bf09-0c682d8146c9",
        "status": "Accepted",
        "preStapleSHA256": pre_digest,
        "postStapleSHA256": post_digest,
        "stapled": True,
        "verification": verification,
        "downstreamChecksums": "generate-after-notarization",
    }),
    encoding="utf-8",
)
PY
cat >"$signed_dmg_fixture/scripts/release/generate_release_metadata.py" <<'PY'
#!/usr/bin/env python3
import json
import os
import sys
from pathlib import Path

command = sys.argv[1]
arguments = sys.argv[2:]
with Path(os.environ["FAKE_RELEASE_LOG"]).open("a", encoding="utf-8") as handle:
    handle.write(json.dumps(["metadata", command, *arguments], separators=(",", ":")) + "\n")
if command == "generate":
    values = dict(zip(arguments[::2], arguments[1::2]))
    Path(values["--provenance-out"]).write_text("{}\n", encoding="utf-8")
    Path(values["--spdx-out"]).write_text("{}\n", encoding="utf-8")
    Path(values["--licenses-out"]).write_bytes(b"license fixture")
PY
cat >"$signed_dmg_fixture/mock-bin/ManifestTool" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
test "$1" = verify-release
EOF
cat >"$signed_dmg_fixture/mock-bin/swift" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
cat >"$signed_dmg_fixture/mock-bin/xcodebuild" <<'EOF'
#!/usr/bin/env bash
test "$*" = "-license check"
EOF
cat >"$signed_dmg_fixture/mock-bin/git" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' '0123456789abcdef0123456789abcdef01234567'
EOF
cat >"$signed_dmg_fixture/mock-bin/hdiutil" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
test "$1" = verify
test -s "$2"
EOF
chmod +x \
  "$signed_dmg_fixture/scripts/release/build_app.sh" \
  "$signed_dmg_fixture/scripts/release/create_dmg.sh" \
  "$signed_dmg_fixture/scripts/release/sign_macos_distribution.py" \
  "$signed_dmg_fixture/scripts/release/notarize_artifact.sh" \
  "$signed_dmg_fixture/scripts/release/generate_release_metadata.py" \
  "$signed_dmg_fixture/scripts/release/prepared_release.py" \
  "$signed_dmg_fixture/mock-bin/ManifestTool" \
  "$signed_dmg_fixture/mock-bin/swift" \
  "$signed_dmg_fixture/mock-bin/xcodebuild" \
  "$signed_dmg_fixture/mock-bin/git" \
  "$signed_dmg_fixture/mock-bin/hdiutil"

/usr/bin/python3 -I - \
  "$signed_dmg_fixture/scripts/release/build_dmg.sh" \
  "$signed_dmg_fixture/mock-bin/xcodebuild" \
  "$signed_dmg_fixture/mock-bin/swift" \
  "$signed_dmg_fixture/mock-bin/git" \
  "$signed_dmg_fixture/mock-bin/hdiutil" <<'PY'
import shlex
import sys
from pathlib import Path

script_path = Path(sys.argv[1])
xcodebuild, _swift, git, hdiutil = map(shlex.quote, sys.argv[2:])
source = script_path.read_text(encoding="utf-8")
replacements = {
    "if command -v xcodebuild >/dev/null 2>&1; then": (
        f"if [ -x {xcodebuild} ]; then"
    ),
    "if ! xcodebuild -license check >/dev/null 2>&1; then": (
        f"if ! {xcodebuild} -license check >/dev/null 2>&1; then"
    ),
    'SOURCE_COMMIT="$(git -C "$ROOT" rev-parse HEAD)"': (
        f'SOURCE_COMMIT="$({git} -C "$ROOT" rev-parse HEAD)"'
    ),
    '/usr/bin/hdiutil verify "$DMG_PATH"': (
        f'{hdiutil} verify "$DMG_PATH"'
    ),
}
for original, replacement in replacements.items():
    if source.count(original) != 1:
        raise SystemExit(f"fixture patch target drifted: {original}")
    source = source.replace(original, replacement)
script_path.write_text(source, encoding="utf-8")
PY

signed_dmg_log="$TMP_DIR/signed-dmg-release.jsonl"
signed_dmg_build_root="$signed_dmg_fixture/build-output"
signed_dmg_prepared_root="$signed_dmg_fixture/prepared"
signed_dmg_prepared_manifest_sha256="$(
  shasum -a 256 "$signed_dmg_prepared_root/prepared-release.json" | awk '{print $1}'
)"
signed_dmg_source_commit=0123456789abcdef0123456789abcdef01234567
signed_dmg_tampered_root="$TMP_DIR/signed-dmg-tampered-prepared"
/usr/bin/ditto --noqtn "$signed_dmg_prepared_root" "$signed_dmg_tampered_root"
printf '%s' 'tamper' \
  >>"$signed_dmg_tampered_root/product/EasySplat.app/Contents/MacOS/EasySplatApp"
if /usr/bin/python3 -I \
  "$signed_dmg_fixture/scripts/release/prepared_release.py" verify \
  --root "$signed_dmg_tampered_root" \
  --authority-from-manifest \
  --expected-manifest-sha256 "$signed_dmg_prepared_manifest_sha256" \
  --source-commit "$signed_dmg_source_commit" \
  --app-version 0.2.0 \
  --toolchain-version 2.0.0 >/dev/null 2>&1; then
  echo "Prepared release verifier accepted a changed app." >&2
  exit 1
fi
PATH="$signed_dmg_fixture/mock-bin:$PATH" \
FAKE_RELEASE_LOG="$signed_dmg_log" \
  "$signed_dmg_fixture/scripts/release/build_dmg.sh" \
  --app-version 0.2.0 \
  --toolchain-version 2.0.0 \
  --project-url https://example.com/EasySplat \
  --build-root "$signed_dmg_build_root" \
  --prepared-release-root "$signed_dmg_prepared_root" \
  --prepared-manifest-sha256 "$signed_dmg_prepared_manifest_sha256" \
  --source-commit "$signed_dmg_source_commit" \
  --production \
  --identity-fingerprint "$signed_fingerprint" \
  --team-id "$signed_team_id" \
  --notary-keychain-profile easysplat-release
signed_dmg_output="$signed_dmg_fixture/release/DMG"
test -f "$signed_dmg_output/EasySplat-0.2.0.dmg"
test ! -e "$signed_dmg_output/EasySplat-0.2.0-unsigned.dmg"
test -f "$signed_dmg_output/EasySplat-0.2.0.dmg.sha256"
test -f "$signed_dmg_output/EasySplat-0.2.0.app-signing.json"
test -f "$signed_dmg_output/EasySplat-0.2.0.app-notarization.json"
test -f "$signed_dmg_output/EasySplat-0.2.0.dmg-signing.json"
test -f "$signed_dmg_output/EasySplat-0.2.0.dmg-notarization.json"
/usr/bin/python3 -I - \
  "$signed_dmg_output/EasySplat-0.2.0-release-notes.txt" <<'PY'
import sys
from pathlib import Path

expected = (
    "EasySplat 0.2.0 is a Developer ID-signed and notarized release.\n"
    "Install the Developer ID-signed, notarized, and stapled DMG on an Apple "
    "Silicon Mac running macOS 15 or later.\n"
    "\n"
    "EasySplat turns video, photo folders, or mixed inputs into static 3D "
    "Gaussian splats locally. Input media stays on your Mac. Capture-aware "
    "native COLMAP reconstruction uses FAISS matching, and the native Metal "
    "trainer writes a validated PLY. When the geometry is conclusive, "
    "EasySplat aligns the scene upright. The viewer supports orbit, pan, zoom, "
    "fit, reset, export, and system Share. Work can stop and resume at durable "
    "stages. EasySplat has no cloud processing, telemetry, or analytics.\n"
    "\n"
    "One reconstruction runs at a time. PLY is the only export format. Moving "
    "subjects, reflections, water, foliage, and large lighting changes can "
    "leave artifacts.\n"
    "\n"
    "Release files include the DMG SHA-256 checksum, provenance record, SPDX "
    "SBOM, third-party license bundle, and dSYM archive.\n"
).encode("utf-8")
actual = Path(sys.argv[1]).read_bytes()
if actual != expected:
    raise SystemExit("Production release notes differ from the stable contract.")
PY
grep -Fq 'Developer ID-signed and notarized release' \
  "$signed_dmg_output/EasySplat-0.2.0-release-notes.txt"
if grep -Fqi 'production' \
  "$signed_dmg_output/EasySplat-0.2.0-release-notes.txt"; then
  echo "Production release notes claim production status." >&2
  exit 1
fi
python3 - \
  "$signed_dmg_log" \
  "$signed_fingerprint" \
  "$signed_team_id" \
  "$signed_dmg_build_root" <<'PY'
import json
import sys
from pathlib import Path

rows = [json.loads(line) for line in Path(sys.argv[1]).read_text(encoding="utf-8").splitlines()]
events = [row[0:2] for row in rows]
assert events == [
    ["sign", "--root"],
    ["verify-signature", "--verify-only"],
    ["notarize", "--type"],
    ["verify-signature", "--verify-only"],
    ["create-dmg", "--app-path"],
    ["sign", "--root"],
    ["verify-signature", "--verify-only"],
    ["notarize", "--type"],
    ["verify-signature", "--verify-only"],
    ["metadata", "generate"],
]
app_sign_arguments = rows[0][1:]
dmg_sign_arguments = rows[5][1:]
verification_arguments = [row[1:] for row in rows if row[0] == "verify-signature"]
assert all(row[0] != "build-app" for row in rows)
for sign_arguments in (app_sign_arguments, dmg_sign_arguments):
    assert sign_arguments[sign_arguments.index("--identity-fingerprint") + 1] == sys.argv[2]
    assert sign_arguments[sign_arguments.index("--team-id") + 1] == sys.argv[3]
build_root = Path(sys.argv[4])
assert build_root.is_dir()
assert not any(build_root.iterdir())
assert len(verification_arguments) == 4
assert all("--receipt" in arguments for arguments in verification_arguments)
assert sum(
    "--bind-receipt-to-current-artifact" in arguments
    for arguments in verification_arguments
) == 2
assert "--deep" not in app_sign_arguments + dmg_sign_arguments
assert rows[2][rows[2].index("--type") + 1] == "app"
assert rows[7][rows[7].index("--type") + 1] == "dmg"
assert rows[9][rows[9].index("--release-mode") + 1] == "production"
PY

rm -rf "$signed_dmg_output"
failed_signed_dmg_log="$TMP_DIR/failed-signed-dmg-release.jsonl"
if PATH="$signed_dmg_fixture/mock-bin:$PATH" \
  FAKE_RELEASE_LOG="$failed_signed_dmg_log" \
  FAKE_FAIL_NOTARY_TYPE=dmg \
  "$signed_dmg_fixture/scripts/release/build_dmg.sh" \
  --app-version 0.2.0 \
  --toolchain-version 2.0.0 \
  --build-root "$signed_dmg_build_root" \
  --prepared-release-root "$signed_dmg_prepared_root" \
  --prepared-manifest-sha256 "$signed_dmg_prepared_manifest_sha256" \
  --source-commit "$signed_dmg_source_commit" \
  --production \
  --identity-fingerprint "$signed_fingerprint" \
  --team-id "$signed_team_id" \
  --notary-keychain-profile easysplat-release >/dev/null 2>&1; then
  echo "Production packaging accepted failed DMG notarization." >&2
  exit 1
fi
if find "$signed_dmg_output" -mindepth 1 -print -quit 2>/dev/null | grep -q .; then
  echo "Failed production packaging published partial release output." >&2
  exit 1
fi

mock_hdiutil="$TMP_DIR/mock-hdiutil.sh"
cat >"$mock_hdiutil" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"$EASYSPLAT_TEST_HDIUTIL_LOG"
case "$1" in
  create)
    out="${!#}"
    printf '%s' 'mock dmg' >"$out"
    ;;
  verify) test -f "$2" ;;
  attach)
    mountpoint=""
    shift
    while [[ $# -gt 0 ]]; do
      case "$1" in
        -mountpoint)
          mountpoint="$2"
          shift 2
          ;;
        *) shift ;;
      esac
    done
    test -n "$mountpoint"
    test -d "$mountpoint"
    test -d "$EASYSPLAT_TEST_APP_PATH"
    cp -R "$EASYSPLAT_TEST_APP_PATH" "$mountpoint/EasySplat.app"
    case "${EASYSPLAT_TEST_HDIUTIL_ATTACH_OUTPUT:-none}" in
      canonical)
        printf '/dev/disk42\tGUID_partition_scheme\n'
        printf '/dev/disk42s1\tApple_HFS\t%s\n' "$mountpoint"
        ;;
      unrelated)
        printf '/dev/disk98\tGUID_partition_scheme\n'
        printf '/dev/disk98s1\tApple_HFS\t/Volumes/Not-EasySplat\n'
        ;;
      none) ;;
      *) exit 2 ;;
    esac
    ;;
  detach)
    if [[ "$2" == /dev/disk* ]]; then
      if [[ -n "${EASYSPLAT_TEST_EXPECTED_DETACH_DEVICE:-}" ]]; then
        test "$2" = "$EASYSPLAT_TEST_EXPECTED_DETACH_DEVICE"
      fi
    else
      test -d "$2"
    fi
    if [[ -n "${EASYSPLAT_TEST_HDIUTIL_PID_FILE:-}" ]]; then
      printf '%s\n' "$$" >"$EASYSPLAT_TEST_HDIUTIL_PID_FILE"
    fi
    if [[ "${EASYSPLAT_TEST_HDIUTIL_DETACH_ALWAYS_FAIL:-}" == "1" ]]; then
      exit 1
    fi
    if [[ "${EASYSPLAT_TEST_HDIUTIL_DETACH_BLOCK:-}" == "1" ]]; then
      sleep 30
      exit 1
    fi
    if [[ "${EASYSPLAT_TEST_HDIUTIL_DETACH_DELAY:-}" == "1" ]]; then
      sleep 2
    fi
    if [[ "${EASYSPLAT_TEST_HDIUTIL_DETACH_FAIL_ONCE:-}" == "1" ]]; then
      test -n "${EASYSPLAT_TEST_HDIUTIL_DETACH_STATE:-}"
      if [[ ! -e "$EASYSPLAT_TEST_HDIUTIL_DETACH_STATE" ]]; then
        : >"$EASYSPLAT_TEST_HDIUTIL_DETACH_STATE"
        exit 1
      fi
    fi
    if [[ "${EASYSPLAT_TEST_HDIUTIL_LOCK_MOUNT_PARENT:-}" == "1" ]]; then
      chmod a-w "$(dirname "$2")"
    fi
    ;;
  *) exit 2 ;;
esac
EOF
chmod +x "$mock_hdiutil"
hdiutil_log="$TMP_DIR/hdiutil.log"
EASYSPLAT_NOTARY_TEST_MODE=1 \
EASYSPLAT_NOTARY_CODESIGN_BIN=/usr/bin/codesign \
EASYSPLAT_NOTARY_XCRUN_BIN=/usr/bin/xcrun \
EASYSPLAT_NOTARY_SPCTL_BIN=/usr/sbin/spctl \
EASYSPLAT_NOTARY_SYSPOLICY_BIN=/usr/bin/syspolicy_check \
EASYSPLAT_HDIUTIL_BIN="$mock_hdiutil" \
EASYSPLAT_TEST_HDIUTIL_LOG="$hdiutil_log" \
  "$ROOT/scripts/release/create_dmg.sh" \
  --app-path "$app_bundle" \
  --out "$TMP_DIR/EasySplat-0.2.0-unsigned.dmg" \
  --volname "EasySplat"
grep -q '^create ' "$hdiutil_log"
grep -q '^verify ' "$hdiutil_log"

test -x "$ROOT/scripts/release/verify_release.sh"
release_verifier_help="$TMP_DIR/verify-release-help.txt"
"$ROOT/scripts/release/verify_release.sh" --help >"$release_verifier_help"
grep -F 'Usage: verify_release.sh' "$release_verifier_help" >/dev/null
grep -F 'The app carries its own toolchain' "$release_verifier_help" >/dev/null
for retired_flag in \
  --release-manifest \
  --core-archive \
  --manifest-url \
  --toolchain-root \
  --offline-cache-root; do
  if grep -F -- "$retired_flag" "$release_verifier_help" >/dev/null; then
    echo "verify_release.sh still advertises the retired option $retired_flag" >&2
    exit 1
  fi
done
legacy_fixture_error="$TMP_DIR/legacy-release-fixture.stderr"
if EASYSPLAT_RELEASE_FIXTURE="$TMP_DIR/untrusted-release-fixture" \
  "$ROOT/scripts/release/verify_release.sh" --help \
  >/dev/null 2>"$legacy_fixture_error"; then
  echo "Release verifier accepted caller-provided EASYSPLAT_RELEASE_FIXTURE." >&2
  exit 1
fi
grep -Fq 'EASYSPLAT_RELEASE_FIXTURE is forbidden' "$legacy_fixture_error"
build_metadata_error="$TMP_DIR/release-verifier-build-metadata.stderr"
if EASYSPLAT_HDIUTIL_BIN="$mock_hdiutil" \
  EASYSPLAT_TEST_HDIUTIL_LOG="$hdiutil_log" \
  EASYSPLAT_TEST_APP_PATH="$app_bundle" \
    "$ROOT/scripts/release/verify_release.sh" \
    --app "$app_bundle" \
    --dmg "$TMP_DIR/EasySplat-0.2.0-unsigned.dmg" \
    --expected-version "0.2.0+build.7" \
    --allow-incomplete \
    --skip-packaged-app-smoke \
    >/dev/null 2>"$build_metadata_error"; then
  echo "Release verifier accepted SemVer build metadata." >&2
  exit 1
fi
grep -Fq 'without build metadata' "$build_metadata_error"
for malformed_version in \
  00.2.0 \
  0.02.0-beta.1 \
  0.2.00-beta.1 \
  0.2.0-.. \
  0.2.0-beta..1 \
  0.2.0-beta.01; do
  malformed_version_error="$TMP_DIR/release-verifier-malformed-version.stderr"
  if EASYSPLAT_HDIUTIL_BIN="$mock_hdiutil" \
    EASYSPLAT_TEST_HDIUTIL_LOG="$hdiutil_log" \
    EASYSPLAT_TEST_APP_PATH="$app_bundle" \
      "$ROOT/scripts/release/verify_release.sh" \
      --app "$app_bundle" \
      --dmg "$TMP_DIR/EasySplat-0.2.0-unsigned.dmg" \
      --expected-version "$malformed_version" \
      --allow-incomplete \
      --skip-packaged-app-smoke \
      >/dev/null 2>"$malformed_version_error"; then
    echo "Release verifier accepted malformed SemVer: $malformed_version" >&2
    exit 1
  fi
  grep -Fq 'strict semantic versioning without build metadata' \
    "$malformed_version_error"
done
incomplete_evidence="$TMP_DIR/release-verifier-incomplete-evidence"
EASYSPLAT_HDIUTIL_BIN="$mock_hdiutil" \
EASYSPLAT_TEST_HDIUTIL_LOG="$hdiutil_log" \
EASYSPLAT_TEST_APP_PATH="$app_bundle" \
  "$ROOT/scripts/release/verify_release.sh" \
  --app "$app_bundle" \
  --dmg "$TMP_DIR/EasySplat-0.2.0-unsigned.dmg" \
  --expected-version "0.2.0" \
  --allow-incomplete \
  --evidence-dir "$incomplete_evidence" \
  --skip-packaged-app-smoke
grep -Fxq 'Status: incomplete' \
  "$incomplete_evidence/release-verification-status.txt"
if grep -Fxq 'Status: passed' \
  "$incomplete_evidence/release-verification-status.txt"; then
  echo "Incomplete release inspection published passed release evidence." >&2
  exit 1
fi

mount_device_log="$TMP_DIR/hdiutil-mount-device.log"
mount_device_tmp="$TMP_DIR/hdiutil mount device tmp"
mkdir -p "$mount_device_tmp"
TMPDIR="$mount_device_tmp" \
EASYSPLAT_HDIUTIL_BIN="$mock_hdiutil" \
EASYSPLAT_TEST_HDIUTIL_LOG="$mount_device_log" \
EASYSPLAT_TEST_HDIUTIL_ATTACH_OUTPUT=canonical \
EASYSPLAT_TEST_EXPECTED_DETACH_DEVICE=/dev/disk42s1 \
EASYSPLAT_TEST_APP_PATH="$app_bundle" \
  "$ROOT/scripts/release/verify_release.sh" \
  --app "$app_bundle" \
  --dmg "$TMP_DIR/EasySplat-0.2.0-unsigned.dmg" \
  --expected-version "0.2.0" \
  --allow-incomplete \
  --skip-packaged-app-smoke >/dev/null
if [[ "$(grep -c '^detach /dev/disk42s1$' "$mount_device_log")" -ne 1 ]]; then
  echo "Release verifier did not detach the device mounted at its exact mount point" >&2
  exit 1
fi

unrelated_device_log="$TMP_DIR/hdiutil-unrelated-device.log"
unrelated_device_tmp="$TMP_DIR/hdiutil-unrelated-device-tmp"
mkdir -p "$unrelated_device_tmp"
TMPDIR="$unrelated_device_tmp" \
EASYSPLAT_HDIUTIL_BIN="$mock_hdiutil" \
EASYSPLAT_TEST_HDIUTIL_LOG="$unrelated_device_log" \
EASYSPLAT_TEST_HDIUTIL_ATTACH_OUTPUT=unrelated \
EASYSPLAT_TEST_APP_PATH="$app_bundle" \
  "$ROOT/scripts/release/verify_release.sh" \
  --app "$app_bundle" \
  --dmg "$TMP_DIR/EasySplat-0.2.0-unsigned.dmg" \
  --expected-version "0.2.0" \
  --allow-incomplete \
  --skip-packaged-app-smoke >/dev/null
if grep -q '^detach /dev/disk' "$unrelated_device_log"; then
  echo "Release verifier detached a device that was not tied to its mount point" >&2
  exit 1
fi
unrelated_detach_target="$(awk '$1 == "detach" { sub(/^detach /, ""); print; exit }' \
  "$unrelated_device_log")"
case "$unrelated_detach_target" in
  "$unrelated_device_tmp"/easysplat-release-mount.*) ;;
  *)
    echo "Release verifier did not fall back to its own mount point" >&2
    exit 1
    ;;
esac

python3 - "$ROOT/scripts/release/verify_release.sh" "$e2e_verifier_helpers" <<'PY'
import sys
from pathlib import Path

source = Path(sys.argv[1]).read_text(encoding="utf-8")
helper = Path(sys.argv[2]).read_text(encoding="utf-8")
if 'SMOKE_APPLICATIONS_DIR="$SMOKE_INSTALL_ROOT/Applications"' not in source:
    raise SystemExit(
        "Release verifier does not create a unique temporary Applications directory"
    )
for forbidden in (
    "NSWorkspace",
    "CGWindowListCopyWindowInfo",
    "EASYSPLAT_SMOKE_SECONDS",
    "launch-smoke.log",
):
    if forbidden in source:
        raise SystemExit(
            f"Ordinary release verification retains foreground launch code: {forbidden}"
        )
if 'run_packaged_app_bootstrap_smoke "$E2E_FIXTURE_MEDIA"' not in source:
    raise SystemExit("Strict release verification lost its headless packaged-app smoke")
PY

focus_stealing_pattern='activateIgnoringOther''Apps|makeKeyAndOrder''Front'
if rg -n "$focus_stealing_pattern" \
    "$ROOT/scripts/ci/test_release_scripts.sh" >/dev/null; then
  echo "Ordinary release-script tests retain foreground activation code." >&2
  exit 1
fi
test ! -e "$ROOT/Tools/UIVerifier"
test ! -e "$ROOT/scripts/release/verify_ui.sh"

detach_retry_log="$TMP_DIR/hdiutil-detach-retry.log"
detach_retry_state="$TMP_DIR/hdiutil-detach-retry.state"
detach_retry_tmp="$TMP_DIR/hdiutil-detach-retry-tmp"
mkdir -p "$detach_retry_tmp"
TMPDIR="$detach_retry_tmp" \
EASYSPLAT_HDIUTIL_BIN="$mock_hdiutil" \
EASYSPLAT_TEST_HDIUTIL_LOG="$detach_retry_log" \
EASYSPLAT_TEST_HDIUTIL_DETACH_FAIL_ONCE=1 \
EASYSPLAT_TEST_HDIUTIL_DETACH_STATE="$detach_retry_state" \
EASYSPLAT_TEST_APP_PATH="$app_bundle" \
  "$ROOT/scripts/release/verify_release.sh" \
  --app "$app_bundle" \
  --dmg "$TMP_DIR/EasySplat-0.2.0-unsigned.dmg" \
  --expected-version "0.2.0" \
  --allow-incomplete \
  --skip-packaged-app-smoke >/dev/null
if [[ "$(grep -c '^detach ' "$detach_retry_log")" -ne 2 ]]; then
  echo "Release verifier did not retry a transient disk-image detach failure" >&2
  exit 1
fi
if find "$detach_retry_tmp" -maxdepth 1 -name 'easysplat-release-mount.*' -print -quit | grep -q .; then
  echo "Release verifier left a mount directory after detach retry" >&2
  exit 1
fi

detach_delay_log="$TMP_DIR/hdiutil-detach-delay.log"
detach_delay_tmp="$TMP_DIR/hdiutil-detach-delay-tmp"
mkdir -p "$detach_delay_tmp"
TMPDIR="$detach_delay_tmp" \
EASYSPLAT_HDIUTIL_BIN="$mock_hdiutil" \
EASYSPLAT_TEST_HDIUTIL_LOG="$detach_delay_log" \
EASYSPLAT_TEST_HDIUTIL_DETACH_DELAY=1 \
EASYSPLAT_TEST_APP_PATH="$app_bundle" \
  "$ROOT/scripts/release/verify_release.sh" \
  --app "$app_bundle" \
  --dmg "$TMP_DIR/EasySplat-0.2.0-unsigned.dmg" \
  --expected-version "0.2.0" \
  --allow-incomplete \
  --skip-packaged-app-smoke >/dev/null
if [[ "$(grep -c '^detach ' "$detach_delay_log")" -ne 1 ]]; then
  echo "Release verifier killed a healthy slow disk-image detach" >&2
  exit 1
fi
if find "$detach_delay_tmp" -maxdepth 1 -name 'easysplat-release-mount.*' -print -quit | grep -q .; then
  echo "Release verifier left a mount directory after a healthy slow detach" >&2
  exit 1
fi

detach_failure_log="$TMP_DIR/hdiutil-detach-failure.log"
detach_failure_error="$TMP_DIR/hdiutil-detach-failure.stderr"
detach_failure_output="$TMP_DIR/hdiutil-detach-failure.stdout"
detach_failure_tmp="$TMP_DIR/hdiutil-detach-failure-tmp"
mkdir -p "$detach_failure_tmp"
if TMPDIR="$detach_failure_tmp" \
  EASYSPLAT_HDIUTIL_BIN="$mock_hdiutil" \
  EASYSPLAT_TEST_HDIUTIL_LOG="$detach_failure_log" \
  EASYSPLAT_TEST_HDIUTIL_DETACH_ALWAYS_FAIL=1 \
  EASYSPLAT_TEST_APP_PATH="$app_bundle" \
  "$ROOT/scripts/release/verify_release.sh" \
  --app "$app_bundle" \
  --dmg "$TMP_DIR/EasySplat-0.2.0-unsigned.dmg" \
  --expected-version "0.2.0" \
  --allow-incomplete \
  --skip-packaged-app-smoke >"$detach_failure_output" 2>"$detach_failure_error"; then
  echo "Release verifier accepted a persistent disk-image detach failure" >&2
  exit 1
fi
grep -Fq 'could not detach release verification disk image' "$detach_failure_error"
if grep -Eiq 'Verified unsigned developer build|Inspection only|static checks completed' \
  "$detach_failure_output"; then
  echo "Release verifier claimed success before a persistent detach failure" >&2
  exit 1
fi
if [[ "$(grep -c '^detach ' "$detach_failure_log")" -ne 3 ]]; then
  echo "Release verifier did not exhaust its bounded detach retries" >&2
  exit 1
fi
detach_failure_mount_count=$(find "$detach_failure_tmp" -maxdepth 1 \
  -name 'easysplat-release-mount.*' -type d | wc -l | tr -d ' ')
if [[ "$detach_failure_mount_count" -ne 1 ]]; then
  echo "Release verifier removed or duplicated a mount directory after detach failure" >&2
  exit 1
fi
detach_failure_mount=$(find "$detach_failure_tmp" -maxdepth 1 \
  -name 'easysplat-release-mount.*' -type d -print -quit)
if [[ ! -d "$detach_failure_mount/EasySplat.app" ]]; then
  echo "Release verifier removed mounted contents after detach failure" >&2
  exit 1
fi

detach_block_log="$TMP_DIR/hdiutil-detach-block.log"
detach_block_error="$TMP_DIR/hdiutil-detach-block.stderr"
detach_block_output="$TMP_DIR/hdiutil-detach-block.stdout"
detach_block_tmp="$TMP_DIR/hdiutil-detach-block-tmp"
mkdir -p "$detach_block_tmp"
detach_block_started=$(python3 -c 'import time; print(time.monotonic())')
if TMPDIR="$detach_block_tmp" \
  EASYSPLAT_HDIUTIL_BIN="$mock_hdiutil" \
  EASYSPLAT_TEST_HDIUTIL_LOG="$detach_block_log" \
  EASYSPLAT_TEST_HDIUTIL_DETACH_BLOCK=1 \
  EASYSPLAT_TEST_APP_PATH="$app_bundle" \
  "$ROOT/scripts/release/verify_release.sh" \
  --app "$app_bundle" \
  --dmg "$TMP_DIR/EasySplat-0.2.0-unsigned.dmg" \
  --expected-version "0.2.0" \
  --allow-incomplete \
  --skip-packaged-app-smoke >"$detach_block_output" 2>"$detach_block_error"; then
  echo "Release verifier accepted a hung disk-image detach" >&2
  exit 1
fi
detach_block_finished=$(python3 -c 'import time; print(time.monotonic())')
python3 - "$detach_block_started" "$detach_block_finished" <<'PY'
import sys

elapsed = float(sys.argv[2]) - float(sys.argv[1])
if not 0 < elapsed < 28:
    raise SystemExit(f"Release verifier detach timeout was not bounded: {elapsed:.3f}s")
PY
grep -Fq 'could not detach release verification disk image' "$detach_block_error"
if [[ "$(grep -c '^detach ' "$detach_block_log")" -ne 3 ]]; then
  echo "Release verifier did not bound every hung detach attempt" >&2
  exit 1
fi
if grep -Eiq 'Verified unsigned developer build|Inspection only|static checks completed' \
  "$detach_block_output"; then
  echo "Release verifier claimed success after a hung detach" >&2
  exit 1
fi
detach_block_mount_count=$(find "$detach_block_tmp" -maxdepth 1 \
  -name 'easysplat-release-mount.*' -type d | wc -l | tr -d ' ')
if [[ "$detach_block_mount_count" -ne 1 ]]; then
  echo "Release verifier removed or duplicated a mount directory after a hung detach" >&2
  exit 1
fi
detach_block_mount=$(find "$detach_block_tmp" -maxdepth 1 \
  -name 'easysplat-release-mount.*' -type d -print -quit)
if [[ ! -d "$detach_block_mount/EasySplat.app" ]]; then
  echo "Release verifier removed mounted contents after a hung detach" >&2
  exit 1
fi

detach_signal_tmp="$TMP_DIR/hdiutil-detach-signal-tmp"
detach_signal_pid="$TMP_DIR/hdiutil-detach-signal.pid"
mkdir -p "$detach_signal_tmp"
python3 - \
  "$ROOT/scripts/release/verify_release.sh" \
  "$mock_hdiutil" \
  "$app_bundle" \
  "$TMP_DIR/EasySplat-0.2.0-unsigned.dmg" \
  "$detach_signal_tmp" \
  "$detach_signal_pid" <<'PY'
import os
import signal
import subprocess
import sys
import time
from pathlib import Path

verifier, hdiutil, app, dmg, temp_dir, pid_path_raw = sys.argv[1:]
pid_path = Path(pid_path_raw)
environment = os.environ.copy()
environment.update(
    {
        "TMPDIR": temp_dir,
        "EASYSPLAT_HDIUTIL_BIN": hdiutil,
        "EASYSPLAT_TEST_HDIUTIL_DETACH_BLOCK": "1",
        "EASYSPLAT_TEST_HDIUTIL_LOG": f"{pid_path}.log",
        "EASYSPLAT_TEST_HDIUTIL_PID_FILE": str(pid_path),
        "EASYSPLAT_TEST_APP_PATH": app,
    }
)
process = subprocess.Popen(
    [
        verifier,
        "--app",
        app,
        "--dmg",
        dmg,
        "--expected-version",
        "0.2.0",
        "--allow-incomplete",
        "--skip-packaged-app-smoke",
    ],
    env=environment,
    stdout=subprocess.DEVNULL,
    stderr=subprocess.DEVNULL,
    start_new_session=True,
)
mock_pid = None
try:
    deadline = time.monotonic() + 10
    while time.monotonic() < deadline and not pid_path.exists():
        if process.poll() is not None:
            raise SystemExit("Release verifier exited before its detach helper started")
        time.sleep(0.05)
    if not pid_path.exists():
        raise SystemExit("Release verifier did not start its detach helper")
    mock_pid = int(pid_path.read_text(encoding="utf-8").strip())

    os.killpg(process.pid, signal.SIGTERM)
    try:
        return_code = process.wait(timeout=5)
    except subprocess.TimeoutExpired:
        raise SystemExit("Interrupted release verifier did not exit promptly")
    if return_code == 0:
        raise SystemExit("Interrupted release verifier reported success")

    deadline = time.monotonic() + 2
    while time.monotonic() < deadline:
        try:
            os.kill(mock_pid, 0)
        except ProcessLookupError:
            break
        time.sleep(0.05)
    else:
        os.killpg(mock_pid, signal.SIGKILL)
        raise SystemExit("Interrupted release verifier orphaned its hdiutil process group")
finally:
    if process.poll() is None:
        os.killpg(process.pid, signal.SIGKILL)
        process.wait()
    if mock_pid is not None:
        try:
            os.killpg(mock_pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
PY

cleanup_failure_log="$TMP_DIR/hdiutil-cleanup-failure.log"
cleanup_failure_error="$TMP_DIR/hdiutil-cleanup-failure.stderr"
cleanup_failure_output="$TMP_DIR/hdiutil-cleanup-failure.stdout"
cleanup_failure_tmp="$TMP_DIR/hdiutil-cleanup-failure-tmp"
mkdir -p "$cleanup_failure_tmp"
if TMPDIR="$cleanup_failure_tmp" \
  EASYSPLAT_HDIUTIL_BIN="$mock_hdiutil" \
  EASYSPLAT_TEST_HDIUTIL_LOG="$cleanup_failure_log" \
  EASYSPLAT_TEST_HDIUTIL_LOCK_MOUNT_PARENT=1 \
  EASYSPLAT_TEST_APP_PATH="$app_bundle" \
  "$ROOT/scripts/release/verify_release.sh" \
  --app "$app_bundle" \
  --dmg "$TMP_DIR/EasySplat-0.2.0-unsigned.dmg" \
  --expected-version "0.2.0" \
  --allow-incomplete \
  --skip-packaged-app-smoke >"$cleanup_failure_output" 2>"$cleanup_failure_error"; then
  chmod u+w "$cleanup_failure_tmp"
  echo "Release verifier accepted a mount-directory cleanup failure" >&2
  exit 1
fi
chmod u+w "$cleanup_failure_tmp"
grep -Fq 'could not remove release verification mount directory' "$cleanup_failure_error"
if grep -Eiq 'Verified unsigned developer build|Inspection only|static checks completed' \
  "$cleanup_failure_output"; then
  echo "Release verifier claimed success after a cleanup failure" >&2
  exit 1
fi

bundled_contract_only_output="$TMP_DIR/release-verifier-bundled-contract-only.stdout"
EASYSPLAT_HDIUTIL_BIN="$mock_hdiutil" \
EASYSPLAT_TEST_HDIUTIL_LOG="$hdiutil_log" \
EASYSPLAT_TEST_APP_PATH="$app_bundle" \
  "$ROOT/scripts/release/verify_release.sh" \
  --app "$app_bundle" \
  --dmg "$TMP_DIR/EasySplat-0.2.0-unsigned.dmg" \
  --expected-version "0.2.0" \
  --allow-incomplete \
  --skip-packaged-app-smoke >"$bundled_contract_only_output"
grep -Fq 'INCOMPLETE TEST MODE: end-to-end splat not supplied.' "$bundled_contract_only_output"
grep -Fq 'INCOMPLETE TEST MODE: packaged-app smoke disabled.' "$bundled_contract_only_output"
grep -Fq 'Inspection only:' "$bundled_contract_only_output"
grep -Fq 'release verification is incomplete' "$bundled_contract_only_output"
if grep -Eiq 'Verified unsigned developer build|usable|distributable' "$bundled_contract_only_output"; then
  echo "Incomplete release inspection made a release-readiness claim" >&2
  exit 1
fi

x86_fixture_object="$TMP_DIR/smoke-fixture-x86_64.o"
x86_fixture_binary="$TMP_DIR/EasySplatApp-x86_64"
xcrun clang -arch x86_64 -g -fobjc-arc -c \
  "$smoke_fixture_source" -o "$x86_fixture_object"
xcrun clang -arch x86_64 "$x86_fixture_object" \
  -framework AppKit -o "$x86_fixture_binary"
x86_app_fixture="$TMP_DIR/x86-app-fixture"
mkdir -p "$x86_app_fixture"
cp -R "$app_bundle" "$x86_app_fixture/EasySplat.app"
cp "$x86_fixture_binary" "$x86_app_fixture/EasySplat.app/Contents/MacOS/EasySplatApp"
xcrun dsymutil "$x86_fixture_binary" -o "$x86_app_fixture/EasySplat.app.dSYM"
/usr/bin/codesign --force --deep --sign - --timestamp=none \
  "$x86_app_fixture/EasySplat.app"
x86_app_error="$TMP_DIR/release-verifier-x86-app.stderr"
if EASYSPLAT_MANIFEST_TOOL_BIN=/usr/bin/true \
  EASYSPLAT_HDIUTIL_BIN="$mock_hdiutil" \
  EASYSPLAT_TEST_HDIUTIL_LOG="$hdiutil_log" \
  EASYSPLAT_TEST_APP_PATH="$x86_app_fixture/EasySplat.app" \
  "$ROOT/scripts/release/verify_release.sh" \
  --app "$x86_app_fixture/EasySplat.app" \
  --dmg "$TMP_DIR/EasySplat-0.2.0-unsigned.dmg" \
  --expected-version "0.2.0" \
  --allow-incomplete \
  --skip-packaged-app-smoke >/dev/null 2>"$x86_app_error"; then
  echo "Release verification accepted an x86_64-only app executable" >&2
  exit 1
fi
grep -Fqi 'must contain exactly arm64' "$x86_app_error"

universal_fixture="$TMP_DIR/universal-fixture"
mkdir -p "$universal_fixture"
cp -R "$app_bundle" "$universal_fixture/EasySplat.app"
/usr/bin/lipo -create \
  "$app_bundle/Contents/MacOS/EasySplatApp" \
  "$x86_fixture_binary" \
  -output "$universal_fixture/EasySplat.app/Contents/MacOS/EasySplatApp"
/usr/bin/codesign --force --deep --sign - --timestamp=none \
  "$universal_fixture/EasySplat.app"
universal_error="$TMP_DIR/release-verifier-universal.stderr"
if EASYSPLAT_HDIUTIL_BIN="$mock_hdiutil" \
  EASYSPLAT_TEST_HDIUTIL_LOG="$hdiutil_log" \
  EASYSPLAT_TEST_APP_PATH="$universal_fixture/EasySplat.app" \
  "$ROOT/scripts/release/verify_release.sh" \
  --app "$app_bundle" \
  --dmg "$TMP_DIR/EasySplat-0.2.0-unsigned.dmg" \
  --expected-version "0.2.0" \
  --allow-incomplete \
  --skip-packaged-app-smoke >/dev/null 2>"$universal_error"; then
  echo "Release verification accepted a universal app executable" >&2
  exit 1
fi
grep -Fqi 'must contain exactly arm64' "$universal_error"

mismatched_dsym_fixture="$TMP_DIR/mismatched-dsym-fixture"
mkdir -p "$mismatched_dsym_fixture"
cp -R "$app_bundle" "$mismatched_dsym_fixture/EasySplat.app"
xcrun dsymutil "$x86_fixture_binary" \
  -o "$mismatched_dsym_fixture/EasySplat.app.dSYM"
mismatched_dsym_error="$TMP_DIR/release-verifier-mismatched-dsym.stderr"
if EASYSPLAT_HDIUTIL_BIN="$mock_hdiutil" \
  EASYSPLAT_TEST_HDIUTIL_LOG="$hdiutil_log" \
  EASYSPLAT_TEST_APP_PATH="$mismatched_dsym_fixture/EasySplat.app" \
  "$ROOT/scripts/release/verify_release.sh" \
  --app "$mismatched_dsym_fixture/EasySplat.app" \
  --dmg "$TMP_DIR/EasySplat-0.2.0-unsigned.dmg" \
  --expected-version "0.2.0" \
  --allow-incomplete \
  --skip-packaged-app-smoke >/dev/null 2>"$mismatched_dsym_error"; then
  echo "Release verification accepted a dSYM from another executable" >&2
  exit 1
fi
grep -Fqi 'Exported dSYM UUID does not match app executable' "$mismatched_dsym_error"

mismatched_distributed_error="$TMP_DIR/release-verifier-mismatched-distributed.stderr"
if EASYSPLAT_HDIUTIL_BIN="$mock_hdiutil" \
  EASYSPLAT_TEST_HDIUTIL_LOG="$hdiutil_log" \
  EASYSPLAT_TEST_APP_PATH="$early_exit_fixture/EasySplat.app" \
  "$ROOT/scripts/release/verify_release.sh" \
  --app "$app_bundle" \
  --dmg "$TMP_DIR/EasySplat-0.2.0-unsigned.dmg" \
  --expected-version "0.2.0" \
  --allow-incomplete \
  --skip-packaged-app-smoke >/dev/null 2>"$mismatched_distributed_error"; then
  echo "Release verification accepted a DMG executable that differed from the release app" >&2
  exit 1
fi
grep -Fqi 'Mounted app executable SHA-256 does not match release app executable' \
  "$mismatched_distributed_error"

missing_distributed_principal_fixture="$TMP_DIR/missing-distributed-principal-fixture"
mkdir -p "$missing_distributed_principal_fixture"
cp -R "$app_bundle" "$missing_distributed_principal_fixture/EasySplat.app"
/usr/libexec/PlistBuddy -c 'Delete :NSPrincipalClass' \
  "$missing_distributed_principal_fixture/EasySplat.app/Contents/Info.plist"
/usr/bin/codesign --force --deep --sign - --timestamp=none \
  "$missing_distributed_principal_fixture/EasySplat.app"
missing_distributed_principal_error="$TMP_DIR/release-verifier-missing-distributed-principal.stderr"
if EASYSPLAT_HDIUTIL_BIN="$mock_hdiutil" \
  EASYSPLAT_TEST_HDIUTIL_LOG="$hdiutil_log" \
  EASYSPLAT_TEST_APP_PATH="$missing_distributed_principal_fixture/EasySplat.app" \
  "$ROOT/scripts/release/verify_release.sh" \
  --app "$app_bundle" \
  --dmg "$TMP_DIR/EasySplat-0.2.0-unsigned.dmg" \
  --expected-version "0.2.0" \
  --allow-incomplete \
  --skip-packaged-app-smoke >/dev/null 2>"$missing_distributed_principal_error"; then
  echo "Release verification accepted a distributed app without NSPrincipalClass" >&2
  exit 1
fi
if ! grep -Fqi 'NSPrincipalClass' "$missing_distributed_principal_error"; then
  cat "$missing_distributed_principal_error" >&2
  exit 1
fi

# The app carries helpers instead of a download authority, so the payload
# contract is what verification refuses to accept as missing.
missing_helper_fixture="$TMP_DIR/missing-helper-fixture"
mkdir -p "$missing_helper_fixture"
cp -R "$app_bundle" "$missing_helper_fixture/EasySplat.app"
rm "$missing_helper_fixture/EasySplat.app/Contents/Helpers/bin/colmap"
/usr/bin/codesign --force --deep --sign - --timestamp=none \
  "$missing_helper_fixture/EasySplat.app"
cp -R "$app_dsym" "$missing_helper_fixture/EasySplat.app.dSYM"
missing_helper_error="$TMP_DIR/release-verifier-missing-helper.stderr"
if EASYSPLAT_HDIUTIL_BIN="$mock_hdiutil" \
  EASYSPLAT_TEST_HDIUTIL_LOG="$hdiutil_log" \
  EASYSPLAT_TEST_APP_PATH="$missing_helper_fixture/EasySplat.app" \
  "$ROOT/scripts/release/verify_release.sh" \
  --app "$missing_helper_fixture/EasySplat.app" \
  --dmg "$TMP_DIR/EasySplat-0.2.0-unsigned.dmg" \
  --expected-version "0.2.0" \
  --allow-incomplete \
  --skip-packaged-app-smoke >/dev/null 2>"$missing_helper_error"; then
  echo "Release verification accepted an app missing a bundled helper" >&2
  exit 1
fi
grep -Fq 'Bundled helper bin/colmap is missing' "$missing_helper_error"

symlinked_helper_fixture="$TMP_DIR/symlinked-helper-fixture"
mkdir -p "$symlinked_helper_fixture"
cp -R "$app_bundle" "$symlinked_helper_fixture/EasySplat.app"
symlinked_helper_target="$symlinked_helper_fixture/EasySplat.app/Contents/Helpers/bin/linked-colmap"
ln -s colmap "$symlinked_helper_target"
/usr/bin/codesign --force --deep --sign - --timestamp=none \
  "$symlinked_helper_fixture/EasySplat.app" 2>/dev/null || true
cp -R "$app_dsym" "$symlinked_helper_fixture/EasySplat.app.dSYM"
symlinked_helper_error="$TMP_DIR/release-verifier-symlinked-helper.stderr"
if EASYSPLAT_HDIUTIL_BIN="$mock_hdiutil" \
  EASYSPLAT_TEST_HDIUTIL_LOG="$hdiutil_log" \
  EASYSPLAT_TEST_APP_PATH="$symlinked_helper_fixture/EasySplat.app" \
  "$ROOT/scripts/release/verify_release.sh" \
  --app "$symlinked_helper_fixture/EasySplat.app" \
  --dmg "$TMP_DIR/EasySplat-0.2.0-unsigned.dmg" \
  --expected-version "0.2.0" \
  --allow-incomplete \
  --skip-packaged-app-smoke >/dev/null 2>"$symlinked_helper_error"; then
  echo "Release verification accepted a symlink inside the sealed helper tree" >&2
  exit 1
fi
grep -Fqi 'symbolic link' "$symlinked_helper_error"

grep -Fq -- '--development-unsigned)' "$ROOT/scripts/release/build_dmg.sh"
grep -Fq -- '--production)' "$ROOT/scripts/release/build_dmg.sh"
grep -Fq -- '--production)' "$ROOT/scripts/release/build_dmg.sh"
grep -Fq 'EasySplat-$APP_VERSION-unsigned.dmg' "$ROOT/scripts/release/build_dmg.sh"
grep -Fq 'DMG_PATH="$ARTIFACT_STEM.dmg"' "$ROOT/scripts/release/build_dmg.sh"
grep -Fq '.sha256' "$ROOT/scripts/release/build_dmg.sh"
grep -Fq '.provenance.json' "$ROOT/scripts/release/build_dmg.sh"
grep -Fq '.spdx.json' "$ROOT/scripts/release/build_dmg.sh"
grep -Fq -- '-licenses.zip' "$ROOT/scripts/release/build_dmg.sh"

metadata_fixture="$TMP_DIR/release-metadata"
mkdir -p "$metadata_fixture/core/licenses/example"
printf 'Apache-2.0 test license\n' >"$metadata_fixture/core/licenses/example/LICENSE"
ln -s LICENSE "$metadata_fixture/core/licenses/example/LICENSE-link"
python3 "$ROOT/scripts/release/tests/create_toolchain_fixture.py" "$metadata_fixture"
python3 - \
  "$ROOT/scripts/release/tests/create_toolchain_fixture.py" \
  "$metadata_fixture/core/supply-chain/components.json" <<'PY'
import importlib.util
import json
import sys
from pathlib import Path

fixture_path = Path(sys.argv[1])
spec = importlib.util.spec_from_file_location("toolchain_fixture", fixture_path)
fixture = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = fixture
spec.loader.exec_module(fixture)
payload = json.loads(Path(sys.argv[2]).read_text(encoding="utf-8"))
by_path = {row["path"]: row for row in payload["files"]}
assert by_path["bin/default.metallib"]["kind"] == "file"
assert "dependencies" not in by_path["bin/default.metallib"]
assert {
    path for path, row in by_path.items() if row["kind"] == "mach-o"
} == fixture.MACHO_FIXTURE_PATHS
try:
    fixture.fixture_file_kind("bin/arbitrary-data")
except RuntimeError:
    pass
else:
    raise AssertionError("fixture classification accepted an untyped root-bin payload")
PY
(cd "$metadata_fixture/core" && zip -qDr "$metadata_fixture/core.zip" .)
(cd "$metadata_fixture/base" && zip -qDr "$metadata_fixture/base.zip" .)
(cd "$metadata_fixture/small" && zip -qDr "$metadata_fixture/small.zip" .)
python3 - "$metadata_fixture/core.zip" <<'PY'
import stat
import sys
import zipfile

with zipfile.ZipFile(sys.argv[1]) as archive:
    assert not any(stat.S_ISLNK(info.external_attr >> 16) for info in archive.infolist())
    assert archive.read("licenses/example/LICENSE-link") == archive.read("licenses/example/LICENSE")
PY
/usr/bin/codesign --force --deep --sign - --timestamp=none "$app_bundle"

development_dmg="$TMP_DIR/EasySplat-0.2.0-unsigned.dmg"
development_stem="${development_dmg%-unsigned.dmg}"
metadata_tool="$ROOT/scripts/release/generate_release_metadata.py"
python3 - "$metadata_tool" "$TMP_DIR" <<'PY'
import hashlib
import importlib.util
import re
import shutil
import struct
import sys
from pathlib import Path

spec = importlib.util.spec_from_file_location("release_metadata", Path(sys.argv[1]))
module = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = module
spec.loader.exec_module(module)
module.validate_bundled_toolchain_size(module.MAX_BUNDLED_TOOLCHAIN_BYTES)
try:
    module.validate_bundled_toolchain_size(module.MAX_BUNDLED_TOOLCHAIN_BYTES + 1)
except module.MetadataError:
    pass
else:
    raise AssertionError("bundled toolchain size gate accepted an oversized payload")
# A payload this gate accepts must still fit under the whole-app ceiling the
# publication verifier enforces, or the release fails after it is built.
publication = Path(sys.argv[1]).parent / "verify_publication_bundle.py"
app_limits = re.findall(
    r"validate_regular_tree\(app, maximum_bytes=([0-9_]+(?:\s*\*\s*[0-9_]+)*)\)",
    publication.read_text(encoding="utf-8"),
)
if len(app_limits) != 1:
    raise AssertionError("publication verifier no longer states one app size ceiling")
app_ceiling = 1
for factor in app_limits[0].split("*"):
    app_ceiling *= int(factor.strip().replace("_", ""))
if module.MAX_BUNDLED_TOOLCHAIN_BYTES >= app_ceiling:
    raise AssertionError("bundled toolchain budget exceeds the published app ceiling")

wheel_url = "https://files.pythonhosted.org/packages/addict-2.4.0-py3-none-any.whl"
assert module.validate_https_url(wheel_url, "wheel URL") == wheel_url
protobuf_path = "torch/include/google/protobuf/unknown_field_set.h"
assert module.require_text(protobuf_path, "runtime path") == protobuf_path
for placeholder in ("unknown", "NOASSERTION", "none"):
    try:
        module.validate_https_url(placeholder, "placeholder URL")
    except module.MetadataError:
        pass
    else:
        raise AssertionError(f"release metadata accepted placeholder URL: {placeholder}")

arm64 = b"\xcf\xfa\xed\xfe" + struct.pack("<II", module.CPU_TYPE_ARM64, 0) + b"payload"
module.validate_thin_arm64_macho_header(arm64[:12], "bin/native")
for label, header in {
    "x86_64": b"\xcf\xfa\xed\xfe" + struct.pack("<II", 0x01000007, 3),
    "arm64e": b"\xcf\xfa\xed\xfe" + struct.pack("<II", module.CPU_TYPE_ARM64, 2),
    "universal": b"\xca\xfe\xba\xbe" + b"\x00" * 8,
}.items():
    try:
        module.validate_thin_arm64_macho_header(header, label)
    except module.MetadataError:
        pass
    else:
        raise AssertionError(f"accepted {label} Mach-O header")

tree_root = Path(sys.argv[2]) / "arm64-tree-contract"
row = {
    "path": "bin/native",
    "component": "fixture",
    "kind": "mach-o",
    "size": len(arm64),
    "sha256": hashlib.sha256(arm64).hexdigest(),
    "dependencies": [],
}

def stage(payload):
    if tree_root.exists():
        shutil.rmtree(tree_root)
    (tree_root / "bin").mkdir(parents=True)
    (tree_root / "bin/native").write_bytes(payload)
    components = tree_root / module.COMPONENTS_PATH
    components.parent.mkdir(parents=True, exist_ok=True)
    components.write_text("{}", encoding="utf-8")
    row["size"] = len(payload)
    row["sha256"] = hashlib.sha256(payload).hexdigest()

stage(arm64)
module.inspect_toolchain_tree(tree_root, {row["path"]: row}, set())
stage(b"\xcf\xfa\xed\xfe" + struct.pack("<II", 0x01000007, 3) + b"payload")
try:
    module.inspect_toolchain_tree(tree_root, {row["path"]: row}, set())
except module.MetadataError:
    pass
else:
    raise AssertionError("staged toolchain inspection accepted an x86_64 Mach-O")

stage(b"not-a-mach-o")
try:
    module.inspect_toolchain_tree(tree_root, {row["path"]: row}, set())
except module.MetadataError as error:
    assert "not a thin 64-bit binary" in str(error)
else:
    raise AssertionError("staged toolchain inspection accepted non-Mach-O bytes as Mach-O")
PY
python3 "$metadata_tool" generate \
  --app-version 0.2.0 \
  --toolchain-version 2.0.0 \
  --release-mode development-unsigned \
  --source-url https://example.com/EasySplat \
  --source-commit deadbeef \
  --dmg "$development_dmg" \
  --toolchain-dir "$metadata_fixture/core" \
  --app-license "$ROOT/LICENSE" \
  --notice "$ROOT/NOTICE.md" \
  --viewer-license "$ROOT/ThirdParty/MetalSplatter/LICENSE" \
  --provenance-out "$development_stem.provenance.json" \
  --spdx-out "$development_stem.spdx.json" \
  --licenses-out "$development_stem-licenses.zip"
signed_metadata_stem="$TMP_DIR/EasySplat-0.2.0-signed-metadata"
python3 "$metadata_tool" generate \
  --app-version 0.2.0 \
  --toolchain-version 2.0.0 \
  --release-mode production \
  --source-url https://example.com/EasySplat \
  --source-commit deadbeef \
  --dmg "$development_dmg" \
  --toolchain-dir "$metadata_fixture/core" \
  --app-license "$ROOT/LICENSE" \
  --notice "$ROOT/NOTICE.md" \
  --viewer-license "$ROOT/ThirdParty/MetalSplatter/LICENSE" \
  --provenance-out "$signed_metadata_stem.provenance.json" \
  --spdx-out "$signed_metadata_stem.spdx.json" \
  --licenses-out "$signed_metadata_stem-licenses.zip"
python3 - "$signed_metadata_stem.provenance.json" <<'PY'
import json
import sys
from pathlib import Path

payload = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
assert payload["releaseMode"] == "production"
PY
metadata_verify_args=(
  --app-version 0.2.0 \
  --toolchain-version 2.0.0 \
  --release-mode development-unsigned \
  --dmg "$development_dmg" \
  --toolchain-dir "$metadata_fixture/core" \
  --app-license "$ROOT/LICENSE" \
  --notice "$ROOT/NOTICE.md" \
  --viewer-license "$ROOT/ThirdParty/MetalSplatter/LICENSE" \
  --provenance "$development_stem.provenance.json" \
  --spdx "$development_stem.spdx.json" \
  --licenses "$development_stem-licenses.zip"
)
python3 "$metadata_tool" verify \
  "${metadata_verify_args[@]}" \
  --source-url https://example.com/EasySplat \
  --source-commit deadbeef

mismatched_source_commit_error="$TMP_DIR/mismatched-source-commit.stderr"
if python3 "$metadata_tool" verify \
  "${metadata_verify_args[@]}" \
  --source-url https://example.com/EasySplat \
  --source-commit cafebabe >/dev/null 2>"$mismatched_source_commit_error"; then
  echo "Release metadata accepted provenance for a different source commit" >&2
  exit 1
fi
grep -Fqi 'release provenance does not match the built artifacts' \
  "$mismatched_source_commit_error"

mismatched_source_url_error="$TMP_DIR/mismatched-source-url.stderr"
if python3 "$metadata_tool" verify \
  "${metadata_verify_args[@]}" \
  --source-url https://example.com/AnotherRepository \
  --source-commit deadbeef >/dev/null 2>"$mismatched_source_url_error"; then
  echo "Release metadata accepted provenance for a different source repository" >&2
  exit 1
fi
grep -Fqi 'release provenance does not match the built artifacts' \
  "$mismatched_source_url_error"
python3 -m json.tool "$development_stem.provenance.json" >/dev/null
python3 -m json.tool "$development_stem.spdx.json" >/dev/null
python3 - "$development_stem.provenance.json" "$development_stem.spdx.json" <<'PY'
import json
import sys
from pathlib import Path

provenance = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
spdx = json.loads(Path(sys.argv[2]).read_text(encoding="utf-8"))
viewer = provenance["sourceDependencies"]["MetalSplatter"]
assert provenance["source"]["buildCommand"] == "./scripts/release/build_app.sh"
assert viewer["source"] == "https://github.com/scier/MetalSplatter"
assert viewer["basedOnRevision"] == "c0f066fb7146d46d9b68e5c76d7d0a6154facc5e"
assert viewer["buildCommand"] == "./scripts/release/build_app.sh"
assert len(viewer["vendoredTreeSHA256"]) == 64

packages = {package["SPDXID"]: package for package in spdx["packages"]}
viewer_package = packages["SPDXRef-Package-MetalSplatter"]
assert viewer_package["licenseDeclared"] == "MIT"
assert viewer_package["checksums"] == [
    {"algorithm": "SHA256", "checksumValue": viewer["vendoredTreeSHA256"]}
]
assert {
    "spdxElementId": "SPDXRef-Package-EasySplat",
    "relationshipType": "STATIC_LINK",
    "relatedSpdxElement": "SPDXRef-Package-MetalSplatter",
} in spdx["relationships"]
PY
unzip -tq "$development_stem-licenses.zip" >/dev/null
unzip -Z1 "$development_stem-licenses.zip" | grep -Fx 'toolchain-closure.json' >/dev/null
(cd "$TMP_DIR" && shasum -a 256 "$(basename "$development_dmg")" >"$(basename "$development_dmg").sha256")
(cd "$release_test_build_root/Export" && zip -qry "$development_stem-dSYM.zip" EasySplat.app.dSYM)
printf '%s\n' 'EasySplat 0.2.0 is an unsigned developer build.' >"$development_stem-release-notes.txt"
release_metadata_args=(--toolchain-dir "$metadata_fixture/core")
release_source_args=(
  --source-url https://example.com/EasySplat
  --source-commit deadbeef
)

missing_release_source_error="$TMP_DIR/release-verifier-missing-source.stderr"
if EASYSPLAT_HDIUTIL_BIN="$mock_hdiutil" \
  EASYSPLAT_TEST_HDIUTIL_LOG="$hdiutil_log" \
  EASYSPLAT_TEST_APP_PATH="$app_bundle" \
  "$ROOT/scripts/release/verify_release.sh" \
  --app "$app_bundle" \
  --dmg "$development_dmg" \
  --expected-version "0.2.0" \
  --artifacts \
  "${release_metadata_args[@]}" \
  --allow-incomplete \
  --skip-packaged-app-smoke >/dev/null 2>"$missing_release_source_error"; then
  echo "Release verification accepted artifacts without trusted source identity" >&2
  exit 1
fi
grep -Fqi 'requires --source-url and --source-commit' "$missing_release_source_error"

EASYSPLAT_HDIUTIL_BIN="$mock_hdiutil" \
EASYSPLAT_TEST_HDIUTIL_LOG="$hdiutil_log" \
EASYSPLAT_TEST_APP_PATH="$app_bundle" \
  "$ROOT/scripts/release/verify_release.sh" \
  --app "$app_bundle" \
  --dmg "$development_dmg" \
  --expected-version "0.2.0" \
  --artifacts \
  "${release_metadata_args[@]}" \
  "${release_source_args[@]}" \
  --allow-incomplete \
  --skip-packaged-app-smoke

python3 "$metadata_tool" generate \
  --app-version 0.2.0 \
  --toolchain-version 2.0.0 \
  --release-mode development-unsigned \
  --source-url https://example.com/EasySplat \
  --source-commit deadbeef \
  --dmg "$development_dmg" \
  --toolchain-dir "$metadata_fixture/core" \
  --app-license "$ROOT/LICENSE" \
  --notice "$ROOT/NOTICE.md" \
  --viewer-license "$ROOT/ThirdParty/MetalSplatter/LICENSE" \
  --provenance-out "$development_stem.provenance.json" \
  --spdx-out "$development_stem.spdx.json" \
  --licenses-out "$development_stem-licenses.zip"

# The app carries its toolchain, so there is no cache to seed, no signed
# manifest to fetch, and no installation policy to choose. The single lane is
# exercised end to end by verify_release.sh itself; what remains here is the
# runner contract that lane depends on.
strict_runner="$(swift build --package-path "$ROOT" -c release --show-bin-path)/EasySplatReleaseVerifier"
test -x "$strict_runner"
strict_usage_error="$TMP_DIR/release-verifier-usage.stderr"
if "$strict_runner" --toolchain-root "$TMP_DIR" >/dev/null 2>"$strict_usage_error"; then
  echo "Release verifier accepted the retired --toolchain-root option." >&2
  exit 1
fi
grep -Fq -- 'Unknown or incomplete option: --toolchain-root' "$strict_usage_error"
strict_usage_text="$TMP_DIR/release-verifier-usage.txt"
if "$strict_runner" >/dev/null 2>"$strict_usage_text"; then
  echo "Release verifier accepted an empty argument list." >&2
  exit 1
fi
grep -Fq -- '--app-bundle <EasySplat.app>' "$strict_usage_text"

grep -q '^attach ' "$hdiutil_log"
grep -q '^detach ' "$hdiutil_log"

grep -Fq 'detailProfile: .balanced,' "$ROOT/Tools/ReleaseVerifier/main.swift"
grep -Fq 'resourcePolicy: .automatic,' "$ROOT/Tools/ReleaseVerifier/main.swift"
grep -Fq 'SecStaticCodeCheckValidity' \
  "$ROOT/EasySplatCore/Sources/EasySplatCore/Tools/BundledToolchainLocator.swift"
grep -Fq 'kSecCSCheckNestedCode' \
  "$ROOT/EasySplatCore/Sources/EasySplatCore/Tools/BundledToolchainLocator.swift"
grep -Fq 'BundledToolchainLocator(bundleURL: arguments.appBundle)' \
  "$ROOT/Tools/ReleaseVerifier/main.swift"
grep -Fq 'integrityPolicy: toolchain.integrityPolicy' \
  "$ROOT/Tools/ReleaseVerifier/main.swift"
grep -Fq 'ProjectDiagnosticBundle.build(' "$ROOT/Tools/ReleaseVerifier/main.swift"
grep -Fq 'includeNotes: false' "$ROOT/Tools/ReleaseVerifier/main.swift"
grep -Fq 'ProjectDiagnosticBundle.sanitizeForSharing(' \
  "$ROOT/Tools/ReleaseVerifier/main.swift"
grep -Fq 'successfulEvidence: successfulEvidence,' \
  "$ROOT/Tools/ReleaseVerifier/main.swift"
grep -Fq 'Integrity policy:' "$ROOT/Tools/ReleaseVerifier/main.swift"
grep -Fq 'Installed closure SHA-256:' "$ROOT/Tools/ReleaseVerifier/main.swift"
grep -Fq 'Installation identity SHA-256:' "$ROOT/Tools/ReleaseVerifier/main.swift"
grep -Fq 'Installed component:' "$ROOT/Tools/ReleaseVerifier/main.swift"
grep -Fq 'run_release_verifier "$@" >"$raw_log" 2>&1' \
  "$ROOT/scripts/release/verify_release.sh"
grep -Fq 'VERIFIED_TOOLCHAIN_CLOSURE_SHA256=' "$ROOT/scripts/release/verify_release.sh"
grep -Fq -- '--app-bundle "$E2E_APP_BUNDLE"' "$ROOT/scripts/release/verify_release.sh"
grep -Fq 'validate_bundled_toolchain_payload' "$ROOT/scripts/release/verify_release.sh"
if rg -n 'cat "\$APP_WIRING_LOG"' \
  "$ROOT/scripts/release/verify_release.sh" >/dev/null; then
  echo "Strict release verification can print an unsanitized app log." >&2
  exit 1
fi
python3 - "$ROOT/scripts/release/verify_release.sh" "$packaged_smoke" <<'PY'
import sys
from pathlib import Path

verifier = Path(sys.argv[1]).read_text(encoding="utf-8")
packaged = Path(sys.argv[2]).read_text(encoding="utf-8")
active_raw = verifier.index('ACTIVE_LANE_RAW_LOG="$raw_log"')
run_lane = verifier.index('run_release_verifier "$@" >"$raw_log" 2>&1', active_raw)
if active_raw >= run_lane:
    raise SystemExit("Release verifier does not bind active-lane evidence before launch.")
cleanup = verifier.index("cleanup() {")
preserve_active = verifier.index("preserve_active_release_verifier_evidence", cleanup)
remove_e2e = verifier.index('rm -rf "$E2E_DIR"', preserve_active)
if not cleanup < preserve_active < remove_e2e:
    raise SystemExit("Release verifier removes active-lane evidence before preserving it.")
preserve = verifier.index('"$lane_diagnostic" "$lane-diagnostic.md" required')
remove_work = verifier.index(
    '&& [ -n "$E2E_DIR" ] && ! rm -rf "$E2E_DIR"; then',
    preserve,
)
if preserve >= remove_work:
    raise SystemExit("Release verifier removes raw project work before preserving diagnostics.")
runner_build = verifier.index(
    'swift build --package-path "$ROOT" -c release --product EasySplatReleaseVerifier'
)
project_verifier_binding = verifier.index(
    'PACKAGED_PROJECT_VERIFIER="$EXPECTED_RELEASE_RUNNER"',
    runner_build,
)
packaged_pipeline = verifier.index(
    'run_packaged_app_bootstrap_smoke "$E2E_FIXTURE_MEDIA"',
    project_verifier_binding,
)
if not runner_build < project_verifier_binding < packaged_pipeline:
    raise SystemExit("Packaged-app smoke is not pinned to the built repository verifier.")
cleanup_residual_process_check = packaged.index(
    'easysplat_audit_and_drain_verification_processes "$APP_WIRING_TOKEN"'
)
residual_process_check = packaged.index(
    'easysplat_audit_and_drain_verification_processes "$APP_WIRING_TOKEN"',
    cleanup_residual_process_check + 1,
)
self_attestation_check = packaged.index(
    'validate_packaged_app_bootstrap_result',
    residual_process_check,
)
independent_project_check = packaged.index(
    '"$PACKAGED_PROJECT_VERIFIER" verify-packaged-project',
    self_attestation_check,
)
preserve_packaged_attestation = packaged.index(
    '"$packaged_attestation" "packaged-app-attestation.md" required verbatim',
    independent_project_check,
)
preserve_wiring = packaged.index(
    '"$APP_WIRING_LOG" "packaged-app-wiring.log"',
    preserve_packaged_attestation,
)
final_residual_process_check = packaged.index(
    'easysplat_audit_and_drain_verification_processes "$APP_WIRING_TOKEN"',
    residual_process_check + 1,
)
normal_token_clear = packaged.index(
    '\n  APP_WIRING_TOKEN=""\n',
    final_residual_process_check,
)
remove_wiring = packaged.index('rm -f "$APP_WIRING_LOG"', preserve_wiring)
if not (
    preserve_wiring
    < final_residual_process_check
    < normal_token_clear
    < remove_wiring
):
    raise SystemExit(
        "Packaged-app smoke does not prove final quiescence after preserving evidence."
    )
if not (
    residual_process_check
    < self_attestation_check
    < independent_project_check
    < preserve_packaged_attestation
):
    raise SystemExit(
        "Packaged preflight, independent verification, and attestation preservation are misordered."
    )
PY
python3 - "$ROOT/Tools/ReleaseVerifier/main.swift" <<'PY'
import sys
from pathlib import Path

source = Path(sys.argv[1]).read_text(encoding="utf-8")
required_arguments = (
    'let appBundle = values["--app-bundle"]',
    'BundledToolchainLocator(bundleURL: arguments.appBundle)',
    'integrityPolicy: toolchain.integrityPolicy',
)
for required in required_arguments:
    if required not in source:
        raise SystemExit(f"Release verifier is missing its app-bundle binding: {required}")
for retired in ('--expected-manifest', '--toolchain-root', 'publicKeyBase64'):
    if retired in source:
        raise SystemExit(f"Release verifier retains a retired download binding: {retired}")

publication = source.index("private static func publishEvidence(")
stage_sync = source.index("try synchronizeEvidenceDescriptor(temporary)", publication)
validate_before = source.index("try await validateBeforePublication()", stage_sync)
rename = source.index("renameatx_np(", validate_before)
post_rename_readback = source.index("try evidenceDescriptorData(", rename)
payload_comparison = source.index(") == payload", post_rename_readback)
post_read_identity = source.index("var contentValidatedIdentity = stat()", payload_comparison)
directory_sync = source.index("try synchronizeEvidenceDescriptor(directory)", rename)
final_descriptor = source.index("var finalDescriptorIdentity = stat()", directory_sync)
if not (
    publication
    < stage_sync
    < validate_before
    < rename
    < post_rename_readback
    < payload_comparison
    < post_read_identity
    < directory_sync
    < final_descriptor
):
    raise SystemExit(
        "Packaged attestation is not fully validated before atomic publication."
    )

locate = source.index("locator: BundledToolchainLocator(bundleURL: arguments.appBundle)")
before = source.index("let toolchainEvidenceBeforeRun = try manager.installedTreeEvidence(", locate)
pipeline = source.index("try await runner.run", before)
after = source.index("let toolchainEvidenceAfterRun = try manager.installedTreeEvidence(", pipeline)
unchanged = source.index("guard toolchainEvidenceAfterRun == toolchainEvidenceBeforeRun", after)
publish = source.index("let outputEvidence = try ProjectArtifactValidator.publishValidatedPly(", unchanged)
returned = source.index("return SuccessfulRunEvidence(", publish)
if not locate < before < pipeline < after < unchanged < publish < returned:
    raise SystemExit(
        "Release verifier does not resolve the bundled toolchain, attest the full "
        "closure before and after the pipeline, then publish output."
    )
PY
python3 - "$ROOT/scripts/release/verify_release.sh" "$e2e_verifier_helpers" <<'PY'
import sys
from pathlib import Path

source = Path(sys.argv[1]).read_text(encoding="utf-8")
helper = Path(sys.argv[2]).read_text(encoding="utf-8")
lane = source.index(
    '  run_captured_release_verifier bundled "$BUNDLED_LANE_ROOT" "$E2E_OUTPUT" \\\n'
)
# One lane, and it must deny the network: the app carries every tool it runs.
if 'deny "$BUNDLED_LANE_ROOT/home" "$BUNDLED_LANE_ROOT/work" "$E2E_APP_BUNDLE"' not in source[lane:]:
    raise SystemExit("Bundled verification lane does not deny network access.")
if '--app-bundle "$E2E_APP_BUNDLE"' not in source[lane:]:
    raise SystemExit("Bundled verification lane does not attest the packaged app.")
if source.count("run_captured_release_verifier ") != 1:
    raise SystemExit("Release verification no longer runs exactly one lane.")
for retired in ("OFFLINE_CACHE_ROOT", "CACHED_CACHE_ROOT", "--installation-policy"):
    if retired in source:
        raise SystemExit(f"Release verification retains a retired lane surface: {retired}")
if "(deny network* (with send-signal SIGKILL))" not in helper:
    raise SystemExit("Release-verifier sandbox cannot fail closed on network use.")
if "Contents\", \"Helpers\", \"bin\"" not in helper.replace("'", '"'):
    raise SystemExit("Release-verifier sandbox does not name the bundled helper path.")
PY
app_workflow="$ROOT/.github/workflows/release-app.yml"
grep -Fq 'workflow_dispatch:' "$app_workflow"
grep -Fq 'RUNNER_ENVIRONMENT: ${{ runner.environment }}' "$app_workflow"
grep -Fq 'runs-on: [self-hosted, macOS, ARM64, easysplat-signing, easysplat-ephemeral]' "$app_workflow"
grep -Fq 'runs-on: ubuntu-24.04' "$app_workflow"
grep -Fq 'runs-on: macos-15' "$app_workflow"
grep -Fq 'test "$(uname -m)" = "arm64"' "$app_workflow"
grep -Fq 'environment: release-verification' "$app_workflow"
grep -Fq 'environment: release-publication' "$app_workflow"
grep -Fq 'timeout-minutes: 240' "$app_workflow"
grep -Fq 'EASYSPLAT_RELEASE_VERIFIER_TIMEOUT_SECONDS: "3600"' "$app_workflow"
grep -Fq 'uses: actions/checkout@9c091bb21b7c1c1d1991bb908d89e4e9dddfe3e0' "$app_workflow"
grep -Fq 'uses: actions/setup-python@ece7cb06caefa5fff74198d8649806c4678c61a1' "$app_workflow"
grep -Fq 'python-version: "3.12"' "$app_workflow"
grep -Fq -- '--toolchain-dir "$PREPARED_ROOT/toolchain/out"' "$app_workflow"
grep -Fq -- '--e2e-runner "$EASYSPLAT_TRUSTED_RELEASE_VERIFIER"' "$app_workflow"
grep -Fq -- '--evidence-dir "$EVIDENCE/full-verification"' "$app_workflow"
if grep -Eq -- '--(offline|cached)-cache-root|--toolchain-root|--manifest-url' "$app_workflow"; then
  echo "Release workflow still passes a retired verification lane option." >&2
  exit 1
fi
grep -Fq 'name: easysplat-live-release-authority-${{ github.run_id }}-${{ github.run_attempt }}' "$app_workflow"
grep -Fq 'name: easysplat-quarantined-install-${{ github.sha }}' "$app_workflow"
grep -Fq 'EXACT_HEAD_CHECKS = REQUIRED_CHECKS - {"Pull request dependency review"}' "$app_workflow"
grep -Fq '"check_runs",' "$app_workflow"
grep -Fq '?filter=latest&app_id={GITHUB_ACTIONS_APP_ID}&per_page=100' "$app_workflow"
test "$(grep -Fc -- '--source-commit "$GITHUB_SHA"' "$app_workflow")" -ge 2
python3 - "$app_workflow" <<'PY'
import sys
from pathlib import Path

workflow = Path(sys.argv[1]).read_text(encoding="utf-8")
for required in (
    'len(candidates) == 1',
    'latest.get("head_sha") == source_commit',
    'app.get("id") == GITHUB_ACTIONS_APP_ID',
    'latest.get("status") == "completed"',
    'datetime.strptime(',
    'latest.get("conclusion") == "success"',
):
    if required not in workflow:
        raise SystemExit(f"Exact-head release evidence is missing: {required}")
job_markers = [
    "  live-policy-preflight:\n",
    "  minimum-macos-compatibility:\n",
    "  prepare-release:\n",
    "  sign-and-notarize:\n",
    "  quarantined-install:\n",
    "  macos15-signed-compatibility:\n",
    "  verify-publication:\n",
    "  publish:\n",
]
positions = [workflow.index(marker) for marker in job_markers]
if positions != sorted(positions):
    raise SystemExit("Release authority jobs are not ordered from hosted policy through publication.")
preflight = workflow[positions[0]:positions[1]]
prepare = workflow[positions[2]:positions[3]]
signing = workflow[positions[3]:positions[4]]
if "actions/checkout@" in preflight or "actions/setup-python@" in preflight or "scripts/" in preflight:
    raise SystemExit("Hosted live-policy preflight executes repository code.")
for required in (
    "environment: release-verification",
    "release-authority.json",
    "authority_artifact_id:",
    "authority_artifact_digest:",
    "repos/$GITHUB_REPOSITORY/branches/main",
    "repos/$GITHUB_REPOSITORY/commits/main",
):
    if required not in preflight:
        raise SystemExit(f"Hosted live-policy preflight is missing: {required}")
for required in (
    "needs: [live-policy-preflight, minimum-macos-compatibility]",
    "runs-on: macos-26",
    "RUNNER_ENVIRONMENT: ${{ runner.environment }}",
    'test "$RUNNER_ENVIRONMENT" = "github-hosted"',
    "ref: ${{ github.sha }}",
    "0valididentitiesfound",
):
    if required not in prepare:
        raise SystemExit(f"Identity-free build authority is missing: {required}")
for required in (
    "needs: [live-policy-preflight, prepare-release]",
    "runs-on: [self-hosted, macOS, ARM64, easysplat-signing, easysplat-ephemeral]",
    'test "$RUNNER_ENVIRONMENT" = "self-hosted"',
    "Prepare protected-main signing authority",
    '"$GITHUB_WORKSPACE/scripts/release/build_dmg.sh"',
    '--prepared-release-root "$PREPARED_ROOT"',
):
    if required not in signing:
        raise SystemExit(f"Isolated signing authority is missing: {required}")
fresh = signing.index("      - name: Reverify live protected main immediately before signing\n")
credentialed = signing.index("      - name: Sign, notarize, and staple official artifacts\n")
between = signing[fresh:credentialed]
if not fresh < credentialed or "\n      - name:" in between[len("      - name: Reverify live protected main immediately before signing\n"):]:
    raise SystemExit("Live protected-main freshness is not checked directly before signing.")
if any(forbidden in between for forbidden in ("scripts/", "python", "secrets.", "actions/checkout@")):
    raise SystemExit("Last-moment signing freshness executes repository code or receives signing secrets.")

create_start = workflow.index("      - name: Reverify policy, create or resume draft, and upload exact assets\n")
create_end = workflow.index("\n      - name:", create_start + 1)
create_block = workflow[create_start:create_end]
create_call = create_block.index('--method POST "repos/$GITHUB_REPOSITORY/releases"')
for required in (
    'test "$GITHUB_REF" = "refs/heads/main"',
    'test "$DEFAULT_BRANCH" = "main"',
    'repos/$GITHUB_REPOSITORY/branches/main',
    'repos/$GITHUB_REPOSITORY/commits/main',
    'repos/$GITHUB_REPOSITORY/commits/$DEFAULT_BRANCH',
    'repos/$GITHUB_REPOSITORY/commits/$TAG',
):
    if required not in create_block[:create_call]:
        raise SystemExit(f"Draft publication lacks a last-moment source recheck: {required}")
for required in (
    'DRAFT_OWNER_FILE="$RUNNER_TEMP/easysplat-draft-owner"',
    'DRAFT_RELEASE_ID_FILE="$RUNNER_TEMP/easysplat-draft-release-id"',
    'easysplat-release-owner:v3:${GITHUB_REPOSITORY}:${TAG}:${GITHUB_SHA}',
    "printf '\\n\\n<!-- %s -->\\n' \"$DRAFT_OWNER\"",
    '--paginate --slurp',
    'DRAFT_MODE="$(cat "$DRAFT_MODE_FILE")"',
    'existing asset differs from the publication manifest',
    'done <"$PENDING_ASSETS_FILE"',
    '-f target_commitish="$GITHUB_SHA"',
    '-F body="@$DRAFT_NOTES_FILE"',
    'https://uploads.github.com/repos/$GITHUB_REPOSITORY/releases/$RELEASE_ID/assets?name=$asset_name',
):
    if required not in create_block:
        raise SystemExit(f"Draft publication lacks run-owned release identity: {required}")
if 'easysplat-release-owner:v2:' in create_block:
    raise SystemExit("Draft publication is still owned by one workflow run.")
resolve_existing = create_block.index('mode = "resume"', 0, create_call)
validate_response = create_block.index('owned draft source identity differs', create_call)
plan_assets = create_block.index('existing asset differs from the publication manifest', validate_response)
upload_assets = create_block.index('while IFS= read -r asset_name', plan_assets)
if not resolve_existing < create_call < validate_response < plan_assets < upload_assets:
    raise SystemExit("Draft resume/create validation is not complete before missing-asset upload.")

report_start = workflow.index("      - name: Report the preserved owned draft\n")
report_block = workflow[report_start:]
for required in (
    '"repos/$GITHUB_REPOSITORY/releases/$STORED_RELEASE_ID"',
    'release.get("id") != int(expected_id)',
    'release.get("tag_name") != expected_tag',
    'release.get("target_commitish") != expected_commit',
    'release.get("body") != expected_body',
    'release.get("draft") is not True',
    'release.get("prerelease") is not False',
    'release.get("immutable") is not False',
    'Owned draft preserved for manual review or cleanup.',
):
    if required not in report_block:
        raise SystemExit(f"Incomplete-draft reporting lacks exact ownership evidence: {required}")
if "--method DELETE" in workflow or "gh release delete" in workflow:
    raise SystemExit("Failure handling must never race an owned-draft check with destructive cleanup.")

publish_start = workflow.index("      - name: Attest draft for manual publication\n")
publish_end = workflow.index("\n      - name:", publish_start + 1)
publish_step = workflow[publish_start:publish_end]
if "--method PATCH" in workflow or "gh release edit" in workflow:
    raise SystemExit("Release workflow must not auto-publish without an API lease or compare-and-swap.")
local_evidence = publish_step.index('LOCAL_ASSET_EVIDENCE="$RUNNER_TEMP/easysplat-final-local-assets.json"')
final_policy = publish_step.index('FINAL_POLICY_ROOT="$RUNNER_TEMP/easysplat-final-draft-policy"')
final_fetch = publish_step.index('"repos/$GITHUB_REPOSITORY/releases/$RELEASE_ID" >"$VERIFIED_DRAFT_JSON"')
final_validation = publish_step.index('validate_owned_release "$VERIFIED_DRAFT_JSON" true false')
ready = publish_step.index("Verified stable release draft")
if not local_evidence < final_policy < final_fetch < final_validation < ready:
    raise SystemExit("Manual-publication evidence is not bound after the final policy and draft checks.")
for required in (
    'DRAFT_RELEASE_ID_FILE="$RUNNER_TEMP/easysplat-draft-release-id"',
    'LOCAL_ASSET_EVIDENCE="$RUNNER_TEMP/easysplat-final-local-assets.json"',
    'os.O_NOFOLLOW',
    'os.fsync(output_descriptor)',
    'release.get("id") != evidence["release_id"]',
    'release.get("body")',
    'len(expected_assets) not in {7, 8}',
    'asset.get("digest") != expected["digest"]',
    '"api_has_compare_and_swap": False',
    '"draft": False',
    '"github_app_inventory": "not_authoritatively_queryable_by_release_pat"',
    '"make_latest": "false"',
    '"name": f"EasySplat {version}"',
    '"publication_boundary": "independent_human_exact_id_refetch"',
    '"publication_requires_asset_id_size_digest_match": True',
    '"publication_requires_draft_identity_match": True',
    '"prerelease": False',
    '"tag_name": tag',
    '"target_commitish": commit',
    'easysplat-manual-publication-evidence',
):
    if required not in publish_step:
        raise SystemExit(f"Exact-ID manual-publication evidence is missing: {required}")
if '--method DELETE' in workflow[create_start:] or 'gh release delete' in workflow[create_start:]:
    raise SystemExit("Publication must never delete a tag or release while recovering a partial upload.")
if "/installations" in workflow:
    raise SystemExit("Release policy claims an unavailable authoritative GitHub App inventory.")
for limitation in (
    "Another contents writer can mutate the draft after this attestation.",
    "every asset ID, size, and SHA-256 digest",
):
    if limitation not in publish_step:
        raise SystemExit(f"Manual-publication limitation is missing: {limitation}")
PY
if grep -Fq 'softprops/action-gh-release' "$app_workflow"; then
  echo "App release workflow restored an unaudited release action." >&2
  exit 1
fi
grep -Fq "CURRENT_HEAD=\"\$(gh api -H 'X-GitHub-Api-Version: 2026-03-10' \\" \
  "$app_workflow"
grep -Fq 'test "$CURRENT_HEAD" = "$GITHUB_SHA"' "$app_workflow"
grep -Fq -- '-F prerelease=false' "$app_workflow"
grep -Fq 'scripts/release/verify_release.sh' "$app_workflow"
grep -Fq -- '--toolchain-dir "$PREPARED_ROOT/toolchain/out"' "$app_workflow"
grep -Fq 'scripts/benchmark/aggregate_evidence.py' "$app_workflow"
grep -Fq 'closure_args=(' "$app_workflow"
grep -Fq 'create-build-closure' "$app_workflow"
grep -Fq 'verify_args=(' "$app_workflow"
grep -Fq 'verify-build' "$app_workflow"
grep -Fq 'benchmark_run_id:' "$app_workflow"
grep -Fq 'artifact-ids: ${{ steps.bind-authority.outputs.benchmark_artifact_id }}' "$app_workflow"
grep -Fq 'artifact-ids: ${{ needs.prepare-release.outputs.benchmark_artifact_id }}' "$app_workflow"
grep -Fq 'secrets.EASYSPLAT_RELEASE_ADMIN_TOKEN' "$app_workflow"
grep -Fq 'repos/$GITHUB_REPOSITORY/immutable-releases' "$app_workflow"
if grep -Fq 'EASYSPLAT_IMMUTABLE_RELEASES_ENABLED' "$app_workflow"; then
  echo "App release workflow trusts a variable instead of the live immutable-release policy." >&2
  exit 1
fi
if grep -Fq 'BENCHMARK_EVIDENCE_PRIVATE_KEY_BASE64' "$app_workflow"; then
  echo "App release workflow must never receive the benchmark private key." >&2
  exit 1
fi
python3 - "$app_workflow" <<'PY'
import re
import sys
from pathlib import Path

workflow = Path(sys.argv[1]).read_text(encoding="utf-8")
if "semver_re=" in workflow:
    raise SystemExit("Release workflow duplicates the strict shared SemVer policy.")
preflight_marker = "  live-policy-preflight:"
prepare_marker = "  prepare-release:"
signing_marker = "  sign-and-notarize:"
quarantine_marker = "  quarantined-install:"
compatibility_marker = "  macos15-signed-compatibility:"
verify_marker = "  verify-publication:"
publish_marker = "  publish:"
positions = [
    workflow.index(marker)
    for marker in (
        preflight_marker,
        prepare_marker,
        signing_marker,
        quarantine_marker,
        compatibility_marker,
        verify_marker,
        publish_marker,
    )
]
assert positions == sorted(positions)
preflight_block = workflow.split(preflight_marker, 1)[1].split("  minimum-macos-compatibility:", 1)[0]
prepare_block = workflow.split(prepare_marker, 1)[1].split(signing_marker, 1)[0]
signing_block = workflow.split(signing_marker, 1)[1].split(quarantine_marker, 1)[0]
quarantine_block = workflow.split(quarantine_marker, 1)[1].split(compatibility_marker, 1)[0]
compatibility_block = workflow.split(compatibility_marker, 1)[1].split(verify_marker, 1)[0]
verify_block = workflow.split(verify_marker, 1)[1].split(publish_marker, 1)[0]
publish_block = workflow.split(publish_marker, 1)[1]
assert "runs-on: ubuntu-24.04" in preflight_block
assert "environment: release-verification" in preflight_block
assert "actions/checkout@" not in preflight_block
assert "scripts/" not in preflight_block
assert "release-authority.json" in preflight_block
assert "runs-on: macos-26" in prepare_block
assert "environment:" not in prepare_block
assert 'test "$RUNNER_ENVIRONMENT" = "github-hosted"' in prepare_block
assert "0valididentitiesfound" in prepare_block
assert "runs-on: [self-hosted, macOS, ARM64, easysplat-signing, easysplat-ephemeral]" in signing_block
assert "environment: release-signing" in signing_block
assert signing_block.count("secrets.EASYSPLAT_DEVELOPER_ID_APPLICATION_SHA1") == 1
assert signing_block.count("secrets.EASYSPLAT_DEVELOPER_TEAM_ID") == 1
assert signing_block.count("secrets.EASYSPLAT_NOTARY_KEYCHAIN_PROFILE") == 1
assert '"$GITHUB_WORKSPACE/scripts/release/build_dmg.sh"' in signing_block
assert '--prepared-release-root "$PREPARED_ROOT"' in signing_block
assert "$PREPARED_ROOT/source/" not in signing_block
assert "runs-on: macos-26" in quarantine_block
assert "scripts/release/verify_release.sh" in quarantine_block
assert "secrets." not in quarantine_block
assert "runs-on: macos-15" in compatibility_block
assert "secrets." not in compatibility_block
assert "runs-on: macos-26" in verify_block
assert "signed_artifact_id: ${{ needs.sign-and-notarize.outputs.signed_artifact_id }}" in verify_block
assert "signed_artifact_digest: ${{ needs.sign-and-notarize.outputs.signed_artifact_digest }}" in verify_block
assert "environment:" not in verify_block
assert "contents: write" not in verify_block
assert "EASYSPLAT_RELEASE_ADMIN_TOKEN" not in verify_block
assert "scripts/release/verify_release.sh" not in verify_block
assert re.search(r"^[ \t]+contents: write[ \t]*$", publish_block, re.MULTILINE) is None
assert "environment: release-publication" in publish_block
assert "SIGNED_ARTIFACT_ID: ${{ needs.verify-publication.outputs.signed_artifact_id }}" in publish_block
assert "SIGNED_ARTIFACT_DIGEST: ${{ needs.verify-publication.outputs.signed_artifact_digest }}" in publish_block
assert 'SIGNED_API="repos/$GITHUB_REPOSITORY/actions/artifacts/$SIGNED_ARTIFACT_ID"' in publish_block
assert '"artifact_id": os.environ["SIGNED_ARTIFACT_ID"]' in publish_block
assert '"artifact_digest": os.environ["SIGNED_ARTIFACT_DIGEST"]' in publish_block
assert '"workflow_run_id": os.environ["GITHUB_RUN_ID"]' in publish_block
assert '"workflow_run_attempt": os.environ["GITHUB_RUN_ATTEMPT"]' in publish_block
assert publish_block.count("secrets.EASYSPLAT_RELEASE_ADMIN_TOKEN") == 2
assert "actions/checkout@" not in publish_block
assert "scripts/" not in publish_block
assert re.search(r"^[ \t]+contents: write[ \t]*$", workflow, re.MULTILINE) is None
assert workflow.count("secrets.BENCHMARK_EVIDENCE_PRIVATE_KEY_BASE64") == 0
assert "signed_artifact_id:" in workflow and "signed_artifact_digest:" in workflow
assert "publication_artifact_id:" in workflow and "publication_artifact_digest:" in workflow
assert "DRAFT_OWNER_FILE=\"$RUNNER_TEMP/easysplat-draft-owner\"" in publish_block
assert "easysplat-release-owner:v3:${GITHUB_REPOSITORY}:${TAG}:${GITHUB_SHA}" in publish_block
assert "easysplat-release-owner:v2:" not in publish_block
assert "<!-- %s -->" in publish_block
assert "Report the preserved owned draft" in publish_block
assert "Owned draft preserved for manual review or cleanup." in publish_block
assert "--method DELETE" not in publish_block
assert "gh release delete" not in publish_block
assert '-f target_commitish="$GITHUB_SHA"' in publish_block
assert 'DRAFT_RELEASE_ID_FILE="$RUNNER_TEMP/easysplat-draft-release-id"' in publish_block
assert 'repos/$GITHUB_REPOSITORY/releases/$RELEASE_ID' in publish_block
assert '--paginate --slurp' in publish_block
assert 'existing asset differs from the publication manifest' in publish_block
assert 'done <"$PENDING_ASSETS_FILE"' in publish_block
assert "dismiss_stale_reviews" in publish_block
assert "require_last_push_approval" in publish_block
assert "bypass_pull_request_allowances" in publish_block
assert "required_status_checks" in publish_block
assert "required_linear_history" in publish_block
assert "required_conversation_resolution" in publish_block
assert "can_admins_bypass" in publish_block
assert "prevent_self_review" in publish_block
assert 'tag_ruleset.get("bypass_actors") == []' in publish_block
assert '{"update", "deletion"}.issubset(rule_types)' in publish_block
assert 'actions.get("default_workflow_permissions") == "read"' in publish_block
assert publish_block.count('"$RELEASE_POLICY_CHECKER" live') == 2
assert 'LOCAL_ASSET_EVIDENCE="$RUNNER_TEMP/easysplat-final-local-assets.json"' in publish_block
assert "os.O_NOFOLLOW" in publish_block
assert "os.fsync(output_descriptor)" in publish_block
assert 'validate_owned_release "$VERIFIED_DRAFT_JSON" true false' in publish_block
assert "Verified stable release draft" in publish_block
assert "--method PATCH" not in publish_block
upload_count = workflow.count("uses: actions/upload-artifact@")
assert upload_count > 0
assert workflow.count("if-no-files-found: error") == upload_count
assert "if-no-files-found: warn" not in workflow
expected_assets = (
    'f"{stem}.dmg"',
    'f"{stem}.dmg.sha256"',
    'f"{stem}.provenance.json"',
    'f"{stem}.spdx.json"',
    'f"{stem}-licenses.zip"',
    'f"{stem}-dSYM.zip"',
    'f"{stem}-benchmark.json"',
    'f"{stem}-release-notes.txt"',
)
for asset in expected_assets:
    assert asset in publish_block, f"publication allowlist omits {asset}"
assert "Validate inert publication manifest" in publish_block
assert "Verify remote draft assets without executing them" in publish_block
assert "Attest draft for manual publication" in publish_block
assert 'while IFS= read -r asset_name' in publish_block
assert 'done <"$PENDING_ASSETS_FILE"' in publish_block
PY
python3 - "$app_workflow" <<'PY'
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import textwrap

workflow = Path(sys.argv[1]).read_text(encoding="utf-8")


def embedded(start: str, end: str) -> str:
    body = workflow.split(start, 1)[1].split(end, 1)[0]
    return textwrap.dedent(body)


resolver = embedded(
    "          # BEGIN TRUSTED DRAFT RESOLVER\n",
    "          # END TRUSTED DRAFT RESOLVER\n",
)
planner = embedded(
    "          # BEGIN TRUSTED DRAFT ASSET PLAN\n",
    "          # END TRUSTED DRAFT ASSET PLAN\n",
)
with tempfile.TemporaryDirectory(prefix="easysplat-draft-resume.") as raw:
    root = Path(raw)
    listing = root / "releases.json"
    identifier = root / "release-id"
    mode = root / "mode"
    tag = "v0.2.0"

    listing.write_text("[[]]\n", encoding="utf-8")
    subprocess.run(
        [sys.executable, "-c", resolver, listing, identifier, mode, tag],
        check=True,
    )
    assert mode.read_text(encoding="ascii") == "create\n"
    assert not identifier.exists()

    mode.unlink()
    listing.write_text(json.dumps([[{"id": 73, "tag_name": tag}]]) + "\n", encoding="utf-8")
    subprocess.run(
        [sys.executable, "-c", resolver, listing, identifier, mode, tag],
        check=True,
    )
    assert mode.read_text(encoding="ascii") == "resume\n"
    assert identifier.read_text(encoding="ascii") == "73\n"

    listing.write_text(
        json.dumps([[{"id": 73, "tag_name": tag}, {"id": 74, "tag_name": tag}]]) + "\n",
        encoding="utf-8",
    )
    failed = subprocess.run(
        [sys.executable, "-c", resolver, listing, root / "other-id", root / "other-mode", tag],
        check=False,
        capture_output=True,
        text=True,
    )
    assert failed.returncode != 0 and "multiple releases claim" in failed.stderr

    publication = root / "publication"
    publication.mkdir()
    records = [
        {"name": f"asset-{index}", "sha256": f"{index:064x}", "size_bytes": index + 1}
        for index in range(8)
    ]
    (publication / "publication-manifest.json").write_text(
        json.dumps({"files": records}) + "\n",
        encoding="utf-8",
    )
    notes = root / "notes"
    notes.write_text(
        "notes\n\n<!-- easysplat-release-owner:v3:dud8/EasySplat:"
        + tag
        + ":"
        + "a" * 40
        + " -->\n",
        encoding="utf-8",
    )
    response = root / "draft.json"
    pending = root / "pending"
    release = {
        "id": 73,
        "tag_name": tag,
        "target_commitish": "a" * 40,
        "name": "EasySplat 0.2.0",
        "draft": True,
        "prerelease": False,
        "immutable": False,
        "body": notes.read_text(encoding="utf-8"),
        "assets": [
            {
                "name": row["name"],
                "state": "uploaded",
                "size": row["size_bytes"],
                "digest": f"sha256:{row['sha256']}",
            }
            for row in records[:3]
        ],
    }
    response.write_text(json.dumps(release) + "\n", encoding="utf-8")
    environment = dict(os.environ, PUBLICATION_ROOT=os.fspath(publication))
    subprocess.run(
        [
            sys.executable,
            "-c",
            planner,
            response,
            notes,
            identifier,
            pending,
            tag,
            "a" * 40,
            "0.2.0",
        ],
        check=True,
        env=environment,
    )
    assert pending.read_text(encoding="utf-8").splitlines() == [row["name"] for row in records[3:]]

    release["assets"][0]["digest"] = "sha256:" + "f" * 64
    response.write_text(json.dumps(release) + "\n", encoding="utf-8")
    pending.unlink()
    failed = subprocess.run(
        [
            sys.executable,
            "-c",
            planner,
            response,
            notes,
            identifier,
            pending,
            tag,
            "a" * 40,
            "0.2.0",
        ],
        check=False,
        capture_output=True,
        text=True,
        env=environment,
    )
    assert failed.returncode != 0
    assert "existing asset differs from the publication manifest" in failed.stderr
PY
if rg -n '^  push:|uses: [^ ]+@(v[0-9]+|main|master)$' "$app_workflow" >/dev/null; then
  echo "App release workflow must be manual and pin actions to commit SHAs" >&2
  exit 1
fi

python3 -I - "$ROOT/README.md" "$ROOT/ONBOARDING.md" <<'PY'
import sys
from pathlib import Path

markers = (
    "merge the reviewed release commit",
    "make the repository public",
    "manually dispatch codeql",
    "create the immutable version tag",
    "run release app",
)
for raw_path in sys.argv[1:]:
    path = Path(raw_path)
    text = path.read_text(encoding="utf-8").lower()
    positions = [text.find(marker) for marker in markers]
    if any(position < 0 for position in positions):
        raise SystemExit(f"{path.name} omits the stable release order")
    if positions != sorted(positions) or len(set(positions)) != len(positions):
        raise SystemExit(f"{path.name} states the stable release order ambiguously")
PY

benchmark_workflow="$ROOT/.github/workflows/benchmark-release.yml"
grep -Fq 'workflow_dispatch:' "$benchmark_workflow"
grep -Fq 'runs-on: [self-hosted, macOS, ARM64, easysplat-benchmark-reference, easysplat-ephemeral]' "$benchmark_workflow"
grep -Fq 'runs-on: [self-hosted, macOS, ARM64, easysplat-benchmark-constrained, easysplat-ephemeral]' "$benchmark_workflow"
grep -Fq 'runs-on: [self-hosted, macOS, ARM64, easysplat-benchmark-8gb, easysplat-ephemeral]' "$benchmark_workflow"
grep -Fq 'environment: benchmark-release' "$benchmark_workflow"
grep -Fq 'scripts/benchmark/run_lane.py' "$benchmark_workflow"
grep -Fq -- '--lane reference_m4_max' "$benchmark_workflow"
grep -Fq -- '--lane constrained_14_16gb' "$benchmark_workflow"
grep -Fq -- '--lane eight_gb_fast' "$benchmark_workflow"
grep -Fq 'runs-on: macos-15' "$benchmark_workflow"
grep -Fq 'scripts/benchmark/prepare_evidence.py' "$benchmark_workflow"
grep -Fq 'scripts/benchmark/aggregate_evidence.py' "$benchmark_workflow"
if rg -n 'BENCHMARK_EVIDENCE_(PRIVATE|PUBLIC)_KEY|benchmark-evidence-signing|seal_evidence\.py|signing-requirements|benchmark/public_key_ed25519\.txt|--private-key-stdin|--sealed-root' "$benchmark_workflow" >/dev/null; then
  echo "Benchmark workflow contains a misleading signing authority." >&2
  exit 1
fi
if rg -n 'EASYSPLAT_BENCHMARK_(REFERENCE|CONSTRAINED|8GB)_RUNNER' "$benchmark_workflow" >/dev/null; then
  echo "Benchmark workflow must build its measurement runner from protected source" >&2
  exit 1
fi
grep -Fq -- '--product EasySplatMeasurementRunner' "$benchmark_workflow"
grep -Fq 'measurement_runner_closure.py build' "$benchmark_workflow"
grep -Fq 'measurement_runner_closure.py verify' "$benchmark_workflow"
grep -Fq 'easysplat-measurement-runner-${{ github.sha }}' "$benchmark_workflow"
test "$(grep -Fc 'artifact-ids: ${{ needs.prepare.outputs.measurement_runner_artifact_id }}' "$benchmark_workflow")" -eq 3
grep -Fq 'artifact-ids: ${{ needs.prepare.outputs.requests_artifact_id }}' "$benchmark_workflow"
grep -Fq 'artifact-ids: ${{ needs.derive-reference.outputs.prepared_artifact_id }}' "$benchmark_workflow"
grep -Fq 'artifact-ids: ${{ needs.derive-constrained.outputs.prepared_artifact_id }}' "$benchmark_workflow"
grep -Fq 'artifact-ids: ${{ needs.derive-eight-gb.outputs.prepared_artifact_id }}' "$benchmark_workflow"
grep -Fq '${{ needs.derive-reference.outputs.prepared_artifact_digest }}' "$benchmark_workflow"
grep -Fq '${{ needs.derive-constrained.outputs.prepared_artifact_digest }}' "$benchmark_workflow"
grep -Fq '${{ needs.derive-eight-gb.outputs.prepared_artifact_digest }}' "$benchmark_workflow"
grep -Fq 'actions/artifacts/$artifact_id' "$benchmark_workflow"
test "$(grep -Fc -- '--prepared-root' "$benchmark_workflow")" -eq 3
grep -Fq 'name: easysplat-benchmark-${{ github.sha }}' "$benchmark_workflow"
grep -Fq 'verified-suite.json' "$benchmark_workflow"
grep -Fq 'scripts/release/toolchain_publication.py verify-authority' "$benchmark_workflow"
grep -Fq 'scripts/release/toolchain_publication.py install' "$benchmark_workflow"
test "$(grep -Fc 'secrets.EASYSPLAT_RELEASE_POLICY_TOKEN' "$benchmark_workflow")" -eq 1
grep -Fq 'uses: actions/upload-artifact@043fb46d1a93c77aae656e7c1c64a875d1fc6a0a' "$benchmark_workflow"
grep -Fq 'uses: actions/download-artifact@3e5f45b2cfb9172054b4087a40e8e0b5a5461e7c' "$benchmark_workflow"
if rg -n '^  (push|pull_request|pull_request_target):|uses: [^ ]+@(v[0-9]+|main|master)$' "$benchmark_workflow" >/dev/null; then
  echo "Release benchmark workflow must be manual and pin actions to commit SHAs" >&2
  exit 1
fi

grep -Fq -- '--app-version)' "$ROOT/scripts/release/build_dmg.sh"
grep -Fq -- '--toolchain-version)' "$ROOT/scripts/release/build_dmg.sh"
grep -Fq -- '--toolchain-dir)' "$ROOT/scripts/release/build_dmg.sh"
grep -Fq -- '--production)' "$ROOT/scripts/release/build_dmg.sh"
grep -Fq -- '--identity-fingerprint)' "$ROOT/scripts/release/build_dmg.sh"
grep -Fq -- '--team-id)' "$ROOT/scripts/release/build_dmg.sh"
grep -Fq -- '--notary-keychain-profile)' "$ROOT/scripts/release/build_dmg.sh"
if grep -Fq -- '    --version)' "$ROOT/scripts/release/build_dmg.sh"; then
  echo "build_dmg.sh still accepts the ambiguous legacy --version option" >&2
  exit 1
fi
grep -Fq -- '--version "$APP_VERSION"' "$ROOT/scripts/release/build_dmg.sh"
grep -Fq -- '--toolchain-dir "$TOOLCHAIN_DIR"' "$ROOT/scripts/release/build_dmg.sh"
grep -Fq 'DMG_PATH="$OUT_DIR/EasySplat-$APP_VERSION-unsigned.dmg"' "$ROOT/scripts/release/build_dmg.sh"
grep -Fq 'DMG_PATH="$ARTIFACT_STEM.dmg"' "$ROOT/scripts/release/build_dmg.sh"
if rg -n 'http://localhost|generate-keypair|private_key_ed25519|--private-key-file|scripts/toolchain/(build_|package_toolchain)|EASYSPLAT_DEVELOPER_ID_APPLICATION' \
  "$ROOT/scripts/release/build_dmg.sh" >/dev/null; then
  echo "build_dmg.sh retains a local toolchain build, release key, or production-signing path" >&2
  exit 1
fi
toolchain_check_line="$(grep -n -m1 'Missing toolchain artifact:' "$ROOT/scripts/release/build_dmg.sh" | cut -d: -f1)"
app_build_line="$(grep -n -m1 'build_app.sh"' "$ROOT/scripts/release/build_dmg.sh" | cut -d: -f1)"
test -n "$toolchain_check_line"
test "$toolchain_check_line" -lt "$app_build_line"
grep -q 'scripts/toolchain/build_msplat.sh' "$ROOT/.github/workflows/toolchain-build.yml"
grep -q 'scripts/toolchain/build_da3_mps.sh' "$ROOT/.github/workflows/toolchain-build.yml"
toolchain_workflow="$ROOT/.github/workflows/toolchain-build.yml"
if rg -n 'Homebrew|verify_homebrew_lock|build_suitesparse\.sh' \
  "$toolchain_workflow" "$ROOT/scripts/run.sh" >/dev/null; then
  echo "Release and local launch paths still require Homebrew or the retired SuiteSparse builder." >&2
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
assert positions == sorted(positions), "native toolchain builders run out of dependency order"
PY

assert_dirty_toolchain_source_rejected() {
  local relative_path="$1"
  local fixture_name="${relative_path//\//-}"
  local fixture="$TMP_DIR/dirty-toolchain-source-$fixture_name"
  local error_path="$fixture/package.stderr"

  mkdir -p "$fixture/scripts/toolchain" "$(dirname "$fixture/$relative_path")"
  install -m 0755 \
    "$ROOT/scripts/toolchain/package_toolchain.sh" \
    "$fixture/scripts/toolchain/package_toolchain.sh"
  printf '%s\n' fixture >"$fixture/$relative_path"
  git -C "$fixture" init -q
  git -C "$fixture" add .
  git -C "$fixture" \
    -c user.name='EasySplat release test' \
    -c user.email='release-test@easysplat.invalid' \
    commit -qm 'test fixture'

  printf '%s\n' dirty >>"$fixture/$relative_path"
  if "$fixture/scripts/toolchain/package_toolchain.sh" --version 2.0.0 \
    >/dev/null 2>"$error_path"; then
    echo "Toolchain packaging accepted dirty source input: $relative_path" >&2
    exit 1
  fi
  if ! grep -Fq 'Toolchain source inputs must be committed before release packaging.' \
    "$error_path"; then
    cat "$error_path" >&2
    echo "Toolchain packaging did not reject dirty source input: $relative_path" >&2
    exit 1
  fi
  grep -Fq "$relative_path" "$error_path"
}

for dirty_toolchain_source in \
  Tools/NativeColmap/local_vocab_retriever.cc \
  scripts/ci/generate_msplat_sparse_fixtures.py \
  scripts/toolchain/da3-model-lock.json \
  scripts/toolchain/safe_extract_source.py \
  scripts/toolchain/atomic_swap_install.py \
  scripts/toolchain/tests/test_colmap_support_builder.py \
  scripts/toolchain/tests/test_ceres_builder.py \
  scripts/toolchain/tests/test_openimageio_builder.py \
  scripts/toolchain/tests/test_native_colmap_retriever.py; do
  assert_dirty_toolchain_source_rejected "$dirty_toolchain_source"
done

grep -Fq 'feature_extractor matches_importer local_vocab_retriever mapper' "$ROOT/scripts/toolchain/package_toolchain.sh"
grep -Fq 'point_triangulator bundle_adjuster model_analyzer image_undistorter model_converter' "$ROOT/scripts/toolchain/package_toolchain.sh"
grep -Fq 'Native COLMAP does not expose the exact reviewed command surface.' "$ROOT/scripts/toolchain/package_toolchain.sh"
grep -Fq '"$BIN/colmap" "$command" -h' "$ROOT/scripts/toolchain/package_toolchain.sh"
grep -Fq 'Mapper.ba_global_frames_ratio' "$ROOT/scripts/toolchain/package_toolchain.sh"
grep -Fq 'Mapper.ba_local_max_refinements' "$ROOT/scripts/toolchain/package_toolchain.sh"
grep -Fq 'Mapper.ba_global_points_ratio' "$ROOT/scripts/toolchain/package_toolchain.sh"
grep -Fq 'Mapper.ba_global_max_refinements' "$ROOT/scripts/toolchain/package_toolchain.sh"
grep -Fq 'Mapper.ba_local_max_num_iterations' "$ROOT/scripts/toolchain/package_toolchain.sh"
grep -Fq 'Mapper.ba_local_function_tolerance' "$ROOT/scripts/toolchain/package_toolchain.sh"
grep -Fq 'Mapper.ba_global_function_tolerance' "$ROOT/scripts/toolchain/package_toolchain.sh"
grep -Fq 'Mapper.ba_local_num_images' "$ROOT/scripts/toolchain/package_toolchain.sh"
grep -Fq 'Mapper.random_seed' "$ROOT/scripts/toolchain/package_toolchain.sh"
grep -Fq 'TwoViewGeometry.random_seed' "$ROOT/scripts/toolchain/package_toolchain.sh"
grep -Fq 'EasySplat.require_empty_matching_results' "$ROOT/scripts/toolchain/package_toolchain.sh"
grep -Fq 'TwoViewGeometry.random_seed' "$ROOT/scripts/toolchain/build_colmap_impl.sh"
grep -Fq 'EasySplat.require_empty_matching_results' "$ROOT/scripts/toolchain/build_colmap_impl.sh"
grep -Fq 'NativeRetrieverTests NativeMatchesImporterTests' "$ROOT/scripts/toolchain/build_colmap_impl.sh"
grep -Fq 'NativeRetrieverTests NativeMatchesImporterTests' "$ROOT/scripts/toolchain/package_toolchain.sh"
grep -Fq 'Mapper.min_num_matches' "$ROOT/scripts/toolchain/package_toolchain.sh"
grep -Fq 'returned_neighbor_count' "$ROOT/scripts/toolchain/package_toolchain.sh"
grep -Fq 'minimum_frame_separation' "$ROOT/scripts/toolchain/package_toolchain.sh"
grep -Fq 'image_group_list_path image_group_list_digest' "$ROOT/scripts/toolchain/package_toolchain.sh"
grep -Fq 'for command in image_group_list_path image_group_list_digest' "$ROOT/scripts/toolchain/build_colmap_impl.sh"
grep -Fq 'max_training_descriptors' "$ROOT/scripts/toolchain/package_toolchain.sh"
if rg -n 'pycolmap|--self-check|EASYSPLAT_REQUIRE_REAL_PYCOLMAP|test_real_pycolmap|easysplat[_-]colmap[_-]bridge|global_mapper' \
  "$ROOT/scripts/toolchain/package_toolchain.sh" >/dev/null; then
  echo "Core packaging retains a Python COLMAP bridge, self-check, or unreviewed command." >&2
  exit 1
fi
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
grep -q 'DA3_SOURCE_DESCRIPTOR="git:${DA3_REPO}@${DA3_SOURCE_COMMIT}"' "$ROOT/scripts/toolchain/build_da3_mps.sh"
grep -q 'MSPLAT_COMMIT="106499b0a53f82b0c92d013b0861fbebd341b17e"' "$ROOT/scripts/toolchain/build_msplat.sh"
grep -q 'MSPLAT_VERSION="1\.1\.3"' "$ROOT/scripts/toolchain/build_msplat.sh"
grep -q 'NLOHMANN_JSON_SHA256="04022b05d806eb5ff73023c280b68697d12b93e1b7267a0b22a1a39ec7578069"' "$ROOT/scripts/toolchain/build_msplat.sh"
grep -q 'NANOFLANN_SHA256="57496cb27e1310a77a367e5a902c8f1c700496d91ac54ccc87fbe9ccc28bc6cc"' "$ROOT/scripts/toolchain/build_msplat.sh"
grep -q 'CLI11_SHA256="43e650d5e1a3acaaf419d1e61a81f77b408d0696f472be0599ddf877d40984b0"' "$ROOT/scripts/toolchain/build_msplat.sh"
grep -q 'FETCHCONTENT_SOURCE_DIR_NLOHMANN_JSON' "$ROOT/scripts/toolchain/build_msplat.sh"
grep -q 'FETCHCONTENT_SOURCE_DIR_NANOFLANN' "$ROOT/scripts/toolchain/build_msplat.sh"
grep -q 'FETCHCONTENT_SOURCE_DIR_CLI11' "$ROOT/scripts/toolchain/build_msplat.sh"
grep -q 'promote_install' "$ROOT/scripts/toolchain/build_msplat.sh"
grep -q 'easysplat-train' "$ROOT/scripts/toolchain/build_msplat.sh"
grep -q 'msplat-1.1.3-checkpoint.patch' "$ROOT/scripts/toolchain/build_msplat.sh"
if grep -Eqi 'pip install|python-build-standalone|site-packages|_core\.so|core_extension_path\.txt|(^|[^[:alnum:]])msplat-train' "$ROOT/scripts/toolchain/build_msplat.sh"; then
  echo "Native msplat builder still contains packaged-Python or legacy CLI remnants" >&2
  exit 1
fi
grep -q '^numpy==2\.3\.5$' "$ROOT/Tools/Da3Sfm/requirements.in"
if rg -n 'opencv-python-headless|\bcv2\b' \
  "$ROOT/Tools/Da3Sfm/requirements.in" \
  "$ROOT/Tools/Da3Sfm/requirements.txt" \
  "$ROOT/Tools/Da3Sfm/easysplat_da3_sfm" \
  "$ROOT/scripts/toolchain/package_toolchain.sh" >/dev/null; then
  echo "Lean DA3/COLMAP runtime still includes OpenCV." >&2
  exit 1
fi
# This asserts the requirements continuation backslash.
# shellcheck disable=SC1003
grep -q '^numpy==2\.3\.5 \\' "$ROOT/Tools/Da3Sfm/requirements.txt"
grep -q -- '--hash=sha256:' "$ROOT/Tools/Da3Sfm/requirements.txt"
grep -Fq -- '--require-hashes' "$ROOT/scripts/toolchain/build_da3_mps.sh"
grep -Fq -- '--only-binary=:all:' "$ROOT/scripts/toolchain/build_da3_mps.sh"
grep -Fq -- '--no-binary=antlr4-python3-runtime' "$ROOT/scripts/toolchain/build_da3_mps.sh"
grep -Fq -- '--report "$PIP_INSTALL_REPORT"' "$ROOT/scripts/toolchain/build_da3_mps.sh"
grep -Fq 'export PYTHONDONTWRITEBYTECODE=1' "$ROOT/scripts/toolchain/build_da3_mps.sh"
grep -q 'rm -rf "$target"' "$ROOT/scripts/toolchain/build_da3_mps.sh"
grep -Fq '/usr/bin/lipo -archs "$binary"' "$ROOT/scripts/toolchain/package_toolchain.sh"
grep -Fq '"$desc" != *"universal binary"*' "$ROOT/scripts/toolchain/package_toolchain.sh"
grep -Fq 'require_arm64_only_macho "Packaged native file $relative" "$file"' \
  "$ROOT/scripts/toolchain/package_toolchain.sh"
grep -Fq '/usr/bin/vtool -show-build "$binary"' "$ROOT/scripts/toolchain/package_toolchain.sh"
grep -Fq "grep -Fx 'Signature=adhoc'" "$ROOT/scripts/toolchain/package_toolchain.sh"
grep -Fq "'@rpath/libomp.dylib'" "$ROOT/scripts/toolchain/package_toolchain.sh"
grep -Fq '"@executable_path/../lib"' "$ROOT/scripts/toolchain/package_toolchain.sh"
grep -Fq 'validate_arm64_only(source)' "$ROOT/scripts/toolchain/generate_supply_chain_manifest.py"
grep -q 'source_provenance' "$ROOT/scripts/toolchain/package_toolchain.sh"
grep -q 'pinned-git' "$ROOT/scripts/toolchain/package_toolchain.sh"
grep -Fq 'PYTHON_STANDALONE_SHA256="718a87bf84d81cb81355488ca37be1f66c2252304be2090721016948de96e7ca"' "$ROOT/scripts/toolchain/build_da3_mps.sh"
grep -Fq 'PYTHON_STANDALONE_FULL_SHA256="ff7e2bb25f1f29067a0663af42b32980b0da295b948238d5e3fc09d2b27228a6"' "$ROOT/scripts/toolchain/build_da3_mps.sh"
grep -Fq '"$DA3_SOURCE/src/depth_anything_3/" "$DA3_VENDOR/src/depth_anything_3/"' "$ROOT/scripts/toolchain/build_da3_mps.sh"
if grep -Fq '"$DA3_SOURCE/" "$DA3_VENDOR/"' "$ROOT/scripts/toolchain/build_da3_mps.sh"; then
  echo "DA3 builder must not package the full upstream tree or streaming submodules." >&2
  exit 1
fi
grep -Fq 'test ! -e "$DA3_VENDOR/da3_streaming"' "$ROOT/scripts/toolchain/build_da3_mps.sh"
grep -Fq 'install -m 0755 "$COLMAP_INSTALL/bin/colmap" "$BIN/colmap"' "$ROOT/scripts/toolchain/package_toolchain.sh"
grep -Fq 'install -m 0755 "$COLMAP_SUPPORT_INSTALL/lib/libomp.dylib" "$LIB/libomp.dylib"' "$ROOT/scripts/toolchain/package_toolchain.sh"
grep -Fq 'install -m 0644 "$COLMAP_INSTALL/build_info.json" "$PROVENANCE/colmap.json"' "$ROOT/scripts/toolchain/package_toolchain.sh"
grep -Fq 'install -m 0644 "$COLMAP_SUPPORT_INSTALL/build_info.json" "$PROVENANCE/colmap-support.json"' "$ROOT/scripts/toolchain/package_toolchain.sh"
grep -Fq 'install -m 0644 "$CERES_INSTALL/build_info.json" "$PROVENANCE/ceres.json"' "$ROOT/scripts/toolchain/package_toolchain.sh"
grep -Fq 'install -m 0644 "$OPENIMAGEIO_INSTALL/build_info.json" "$PROVENANCE/openimageio.json"' "$ROOT/scripts/toolchain/package_toolchain.sh"
grep -Fq 'inputs.get("dependency_receipt_sha256")' "$ROOT/scripts/toolchain/package_toolchain.sh"
if grep -Fq 'dependency_receipt_canonical_sha256' "$ROOT/scripts/toolchain/package_toolchain.sh"; then
  echo "Toolchain packaging still expects the superseded canonical dependency receipt field." >&2
  exit 1
fi
if grep -Fq 'EIGEN_INSTALL' "$ROOT/scripts/toolchain/package_toolchain.sh"; then
  echo "Toolchain packaging still expects a separate Eigen prefix instead of the Ceres-bound dependency tree." >&2
  exit 1
fi
grep -Fq 'find "$OUT/da3_mps/python" -type f -name '\''*.pyc'\'' -delete' "$ROOT/scripts/toolchain/package_toolchain.sh"
grep -Fq 'find "$OUT/da3_mps/python" -type d -name '\''__pycache__'\'' -empty -delete' "$ROOT/scripts/toolchain/package_toolchain.sh"
grep -Fq '/usr/bin/codesign --verify --strict "$file"' "$ROOT/scripts/toolchain/package_toolchain.sh"
if grep -Fq '/usr/bin/codesign --force' "$ROOT/scripts/toolchain/package_toolchain.sh" || \
   grep -Fq 'lipo -thin' "$ROOT/scripts/toolchain/package_toolchain.sh"; then
  echo "Toolchain packaging mutates signed wheel Mach-Os and invalidates RECORD hashes." >&2
  exit 1
fi
receipt_line="$(grep -n -m1 '^validate_native_receipts$' "$ROOT/scripts/toolchain/package_toolchain.sh" | cut -d: -f1)"
launch_line="$(grep -n -m1 '^validate_native_colmap_cli$' "$ROOT/scripts/toolchain/package_toolchain.sh" | cut -d: -f1)"
semantic_line="$(grep -n -m1 '^validate_native_colmap_semantics$' "$ROOT/scripts/toolchain/package_toolchain.sh" | cut -d: -f1)"
native_line="$(grep -n -m1 '^validate_packaged_native_files$' "$ROOT/scripts/toolchain/package_toolchain.sh" | cut -d: -f1)"
supply_line="$(grep -n -m1 '^"$SUPPLY_CHAIN_GENERATOR" --toolchain-root' "$ROOT/scripts/toolchain/package_toolchain.sh" | cut -d: -f1)"
test "$receipt_line" -lt "$launch_line"
test "$launch_line" -lt "$semantic_line"
test "$semantic_line" -lt "$native_line"
test "$native_line" -lt "$supply_line"
grep -Fq 'REPRODUCIBLE_ZIP="$ROOT/scripts/toolchain/create_reproducible_zip.py"' \
  "$ROOT/scripts/toolchain/package_toolchain.sh"
test "$(grep -Fc 'python3 "$REPRODUCIBLE_ZIP"' "$ROOT/scripts/toolchain/package_toolchain.sh")" -eq 3
if grep -Fq 'zip -q -r' "$ROOT/scripts/toolchain/package_toolchain.sh"; then
  echo "Toolchain packaging still uses host-metadata-dependent ZIP construction." >&2
  exit 1
fi
grep -Fq -- '--output "$CORE_ZIP"' "$ROOT/scripts/toolchain/package_toolchain.sh"
grep -Fq -- '--output "$DA3_BASE_ZIP"' "$ROOT/scripts/toolchain/package_toolchain.sh"
grep -Fq -- '--path "da3_mps/models/DA3-BASE"' "$ROOT/scripts/toolchain/package_toolchain.sh"
grep -Fq -- '--output "$DA3_SMALL_ZIP"' "$ROOT/scripts/toolchain/package_toolchain.sh"
grep -Fq -- '--path "da3_mps/models/DA3-SMALL"' "$ROOT/scripts/toolchain/package_toolchain.sh"
grep -Fq 'rm -rf "$target/.cache"' "$ROOT/scripts/toolchain/build_da3_mps.sh"
grep -Fq 'assert_exact_da3_model_payload "$DA3_ROOT/models/$model"' "$ROOT/scripts/toolchain/package_toolchain.sh"
grep -Fq 'MAX_RELEASE_ASSET_BYTES=2147483648' "$ROOT/scripts/toolchain/package_toolchain.sh"
grep -Fq 'MAX_CORE_DOWNLOAD_BYTES=2500000000' "$ROOT/scripts/toolchain/package_toolchain.sh"
grep -Fq 'MAX_FULL_DOWNLOAD_BYTES=6000000000' "$ROOT/scripts/toolchain/package_toolchain.sh"
grep -Fq 'assert_release_asset_size "$CORE_ZIP"' "$ROOT/scripts/toolchain/package_toolchain.sh"
grep -Fq 'assert_release_asset_size "$DA3_BASE_ZIP"' "$ROOT/scripts/toolchain/package_toolchain.sh"
grep -Fq 'assert_release_asset_size "$DA3_SMALL_ZIP"' "$ROOT/scripts/toolchain/package_toolchain.sh"
grep -Fq 'assert_download_closure_size "$CORE_ZIP" "$DA3_BASE_ZIP" "$DA3_SMALL_ZIP"' "$ROOT/scripts/toolchain/package_toolchain.sh"
grep -Fq -- '--path "supply-chain/components.json"' "$ROOT/scripts/toolchain/package_toolchain.sh"
grep -Fq '"bin/colmap": "colmap"' "$ROOT/scripts/toolchain/generate_supply_chain_manifest.py"
grep -Fq '"lib/libomp.dylib": "colmap-support:libomp"' "$ROOT/scripts/toolchain/generate_supply_chain_manifest.py"
grep -Fq '"easysplat-da3-runner"' "$ROOT/scripts/toolchain/generate_supply_chain_manifest.py"
if rg -n 'homebrewBuild|SUITESPARSE_INSTALL|colmap:poissonrecon|easysplat[_-]colmap[_-]bridge' \
  "$ROOT/scripts/toolchain/package_toolchain.sh" \
  "$ROOT/scripts/toolchain/generate_supply_chain_manifest.py" >/dev/null; then
  echo "Lean native toolchain packaging references a forbidden closure." >&2
  exit 1
fi
grep -Fq '"$ROOT/scripts/toolchain/package_toolchain.sh" --version "$VERSION"' \
  "$ROOT/scripts/run.sh"
grep -Fq 'rm -f "$CORE_ZIP" "$DA3_BASE_ZIP" "$DA3_SMALL_ZIP"' "$ROOT/scripts/run.sh"
grep -Fq 'ensure_msplat_bundle' "$ROOT/scripts/run.sh"
grep -Fq 'ensure_da3_mps_bundle' "$ROOT/scripts/run.sh"

workflow="$ROOT/.github/workflows/toolchain-build.yml"
env -u GITHUB_PERSONAL_ACCESS_TOKEN -u GH_TOKEN -u GITHUB_TOKEN \
  "$ROOT/scripts/ci/check_workflows.sh"
env -u GITHUB_PERSONAL_ACCESS_TOKEN -u GH_TOKEN -u GITHUB_TOKEN \
  python3 "$ROOT/scripts/release/tests/test_toolchain_workflow.py"
env -u GITHUB_PERSONAL_ACCESS_TOKEN -u GH_TOKEN -u GITHUB_TOKEN \
  python3 "$ROOT/scripts/release/tests/test_toolchain_benchmark_workflow.py"
if rg -n -- '--models-(zip|url)|MODELS_(ZIP|URL)|toolchain-macos-arm64-.*-models\.zip' \
  "$ROOT/scripts/release/build_dmg.sh" \
  "$ROOT/scripts/run.sh" \
  "$ROOT/scripts/toolchain/package_toolchain.sh" \
  "$workflow" >/dev/null; then
  echo "Release paths still reference the removed combined models component" >&2
  exit 1
fi
if rg -n 'uses: [^ ]+@(v[0-9]+|main|master)$' "$workflow" >/dev/null; then
  echo "Toolchain workflow actions must be pinned to full commit SHAs" >&2
  exit 1
fi
if rg -n '^  push:|toolchain-v\*' "$workflow" >/dev/null; then
  echo "Toolchain release workflow must run manually from protected main, not writable tags" >&2
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

msplat_validator="$ROOT/scripts/toolchain/validate_native_msplat.sh"
[ -x "$msplat_validator" ] || {
  echo "Missing executable native msplat validator: $msplat_validator" >&2
  exit 1
}

grep -Fq '"$MSPLAT_VALIDATOR" --source "$MSPLAT_INSTALL/msplat"' "$ROOT/scripts/toolchain/package_toolchain.sh"
grep -Fq '"$MSPLAT_VALIDATOR" --packaged "$OUT"' "$ROOT/scripts/toolchain/package_toolchain.sh"
grep -Fq -- '--path "msplat/build_info.json"' "$ROOT/scripts/toolchain/package_toolchain.sh"
grep -Fq -- '--path "msplat/LICENSE"' "$ROOT/scripts/toolchain/package_toolchain.sh"
grep -Fq 'find "$ROOT/Tools/MsplatNative" -type f -newer "$CORE_ZIP"' "$ROOT/scripts/run.sh"
grep -Fq 'find "$ROOT/Tools/MsplatNative" -type f -newer "$MSPLAT_BUNDLE/build_info.json"' "$ROOT/scripts/run.sh"
grep -Fq '[ "$MSPLAT_BUILD" -nt "$MSPLAT_BUNDLE/build_info.json" ]' "$ROOT/scripts/run.sh"
grep -Fq '"$MSPLAT_VALIDATOR" --archive "$CORE_ZIP"' "$ROOT/scripts/run.sh"
grep -Fq '"$MSPLAT_VALIDATOR" --source "$MSPLAT_BUNDLE"' "$ROOT/scripts/run.sh"
grep -Fq '"$MSPLAT_VALIDATOR" --packaged "$root"' "$ROOT/scripts/run.sh"

for script in "$ROOT/scripts/toolchain/package_toolchain.sh" "$ROOT/scripts/run.sh"; do
  if grep -Eqi 'site-packages/msplat|_core\.so|core_extension_path\.txt|msplat/python|(^|[^[:alnum:]-])msplat-train([^[:alnum:]-]|$)' "$script"; then
    echo "$script still contains packaged-Python or legacy msplat layout assumptions" >&2
    exit 1
  fi
done

if grep -E '^[A-Z0-9_]+_URL="http://' "$ROOT/scripts/toolchain/build_msplat.sh"; then
  echo "Native msplat dependency URLs must use HTTPS" >&2
  exit 1
fi

msplat_source="$ROOT/Toolchains/build/msplat/install/msplat"
if [ -d "$msplat_source" ] && \
   "$msplat_validator" --source "$msplat_source" >/dev/null 2>&1; then

  packaged_fixture="$TMP_DIR/native-msplat-packaged"
  mkdir -p "$packaged_fixture/bin" "$packaged_fixture/msplat"
  cp "$msplat_source/bin/easysplat-train" "$packaged_fixture/bin/easysplat-train"
  cp "$msplat_source/bin/default.metallib" "$packaged_fixture/bin/default.metallib"
  cp "$msplat_source/build_info.json" "$packaged_fixture/msplat/build_info.json"
  cp "$msplat_source/LICENSE" "$packaged_fixture/msplat/LICENSE"
  chmod +x "$packaged_fixture/bin/easysplat-train"
  "$msplat_validator" --packaged "$packaged_fixture"

  archive_fixture="$TMP_DIR/native-msplat.zip"
  (cd "$packaged_fixture" && zip -q "$archive_fixture" \
    bin/easysplat-train bin/default.metallib msplat/build_info.json msplat/LICENSE)
  "$msplat_validator" --archive "$archive_fixture"

  tampered_fixture="$TMP_DIR/native-msplat-tampered"
  cp -R "$packaged_fixture" "$tampered_fixture"
  printf 'tamper\n' >>"$tampered_fixture/bin/default.metallib"
  if "$msplat_validator" --packaged "$tampered_fixture" >/dev/null 2>&1; then
    echo "Native msplat validator accepted a tampered metallib" >&2
    exit 1
  fi

  license_fixture="$TMP_DIR/native-msplat-license-tampered"
  cp -R "$packaged_fixture" "$license_fixture"
  printf 'tamper\n' >>"$license_fixture/msplat/LICENSE"
  if "$msplat_validator" --packaged "$license_fixture" >/dev/null 2>&1; then
    echo "Native msplat validator accepted a tampered upstream license" >&2
    exit 1
  fi

  tampered_archive="$TMP_DIR/native-msplat-tampered.zip"
  (cd "$tampered_fixture" && zip -q "$tampered_archive" \
    bin/easysplat-train bin/default.metallib msplat/build_info.json msplat/LICENSE)
  if "$msplat_validator" --archive "$tampered_archive" >/dev/null 2>&1; then
    echo "Native msplat validator accepted a tampered cached archive" >&2
    exit 1
  fi

  extra_fixture="$TMP_DIR/native-msplat-extra"
  cp -R "$packaged_fixture" "$extra_fixture"
  : >"$extra_fixture/msplat/unexpected.txt"
  if "$msplat_validator" --packaged "$extra_fixture" >/dev/null 2>&1; then
    echo "Native msplat validator accepted an unexpected file" >&2
    exit 1
  fi

  symlink_fixture="$TMP_DIR/native-msplat-symlink"
  cp -R "$packaged_fixture" "$symlink_fixture"
  rm "$symlink_fixture/msplat/LICENSE"
  ln -s "$msplat_source/LICENSE" "$symlink_fixture/msplat/LICENSE"
  if "$msplat_validator" --packaged "$symlink_fixture" >/dev/null 2>&1; then
    echo "Native msplat validator accepted a symlink" >&2
    exit 1
  fi

  legacy_fixture="$TMP_DIR/native-msplat-legacy"
  cp -R "$packaged_fixture" "$legacy_fixture"
  mkdir -p "$legacy_fixture/msplat/python/bin"
  : >"$legacy_fixture/msplat/python/bin/python3"
  if "$msplat_validator" --packaged "$legacy_fixture" >/dev/null 2>&1; then
    echo "Native msplat validator accepted the legacy Python layout" >&2
    exit 1
  fi

  legacy_archive="$TMP_DIR/native-msplat-legacy.zip"
  (cd "$legacy_fixture" && zip -q "$legacy_archive" \
    bin/easysplat-train bin/default.metallib msplat/build_info.json msplat/LICENSE \
    msplat/python/bin/python3)
  if "$msplat_validator" --archive "$legacy_archive" >/dev/null 2>&1; then
    echo "Native msplat validator accepted a legacy cached archive" >&2
    exit 1
  fi

  provenance_fixture="$TMP_DIR/native-msplat-unexpected-provenance"
  cp -R "$packaged_fixture" "$provenance_fixture"
  python3 - "$provenance_fixture/msplat/build_info.json" <<'PY'
import json
import sys
from pathlib import Path

path = Path(sys.argv[1])
payload = json.loads(path.read_text(encoding="utf-8"))
payload["unexpected"] = "not allowed"
path.write_text(json.dumps(payload), encoding="utf-8")
PY
  if "$msplat_validator" --packaged "$provenance_fixture" >/dev/null 2>&1; then
    echo "Native msplat validator accepted unexpected provenance keys" >&2
    exit 1
  fi

  overlay_fixture="$TMP_DIR/native-msplat-overlay-tampered"
  cp -R "$packaged_fixture" "$overlay_fixture"
  python3 - "$overlay_fixture/msplat/build_info.json" <<'PY'
import json
import sys
from pathlib import Path

path = Path(sys.argv[1])
payload = json.loads(path.read_text(encoding="utf-8"))
payload["overlay_sha256"] = "d" * 64
payload["patch_sha256"] = "e" * 64
path.write_text(json.dumps(payload), encoding="utf-8")
PY
  if "$msplat_validator" --packaged "$overlay_fixture" >/dev/null 2>&1; then
    echo "Native msplat validator accepted unpinned overlay provenance" >&2
    exit 1
  fi

  partial_archive="$TMP_DIR/native-msplat-partial.zip"
  (cd "$packaged_fixture" && zip -q "$partial_archive" \
    bin/easysplat-train msplat/build_info.json msplat/LICENSE)
  if "$msplat_validator" --archive "$partial_archive" >/dev/null 2>&1; then
    echo "Native msplat validator accepted a partial cached archive" >&2
    exit 1
  fi

  oversized_fixture="$TMP_DIR/native-msplat-oversized"
  cp -R "$packaged_fixture" "$oversized_fixture"
  dd if=/dev/zero of="$oversized_fixture/bin/default.metallib" bs=1048576 count=17 2>/dev/null
  oversized_archive="$TMP_DIR/native-msplat-oversized.zip"
  (cd "$oversized_fixture" && zip -q "$oversized_archive" \
    bin/easysplat-train bin/default.metallib msplat/build_info.json msplat/LICENSE)
  oversized_error="$TMP_DIR/native-msplat-oversized.stderr"
  if "$msplat_validator" --archive "$oversized_archive" >/dev/null 2>"$oversized_error"; then
    echo "Native msplat validator accepted an oversized required entry" >&2
    exit 1
  fi
  grep -qi 'size limit' "$oversized_error" || {
    echo "Oversized archive was not rejected before extraction and hashing" >&2
    exit 1
  }

  compressed_fixture="$TMP_DIR/native-msplat-compressed"
  cp -R "$packaged_fixture" "$compressed_fixture"
  dd if=/dev/zero of="$compressed_fixture/bin/default.metallib" bs=1048576 count=2 2>/dev/null
  compressed_archive="$TMP_DIR/native-msplat-compressed.zip"
  (cd "$compressed_fixture" && zip -q "$compressed_archive" \
    bin/easysplat-train bin/default.metallib msplat/build_info.json msplat/LICENSE)
  compressed_error="$TMP_DIR/native-msplat-compressed.stderr"
  if "$msplat_validator" --archive "$compressed_archive" >/dev/null 2>"$compressed_error"; then
    echo "Native msplat validator accepted a high-ratio compressed entry" >&2
    exit 1
  fi
  grep -qi 'compression ratio' "$compressed_error" || {
    echo "Compressed archive was not rejected before extraction and hashing" >&2
    exit 1
  }

  unrelated_bomb_fixture="$TMP_DIR/native-msplat-unrelated-bomb"
  cp -R "$packaged_fixture" "$unrelated_bomb_fixture"
  mkdir -p "$unrelated_bomb_fixture/da3_mps/vendor"
  dd if=/dev/zero of="$unrelated_bomb_fixture/da3_mps/vendor/bomb.bin" \
    bs=1048576 count=32 2>/dev/null
  unrelated_bomb_archive="$TMP_DIR/native-msplat-unrelated-bomb.zip"
  (cd "$unrelated_bomb_fixture" && zip -qr "$unrelated_bomb_archive" .)
  unrelated_bomb_error="$TMP_DIR/native-msplat-unrelated-bomb.stderr"
  if "$msplat_validator" --archive "$unrelated_bomb_archive" \
    >/dev/null 2>"$unrelated_bomb_error"; then
    echo "Native msplat validator accepted a compressed bomb outside its own payload" >&2
    exit 1
  fi
  grep -qi 'compression ratio' "$unrelated_bomb_error" || {
    echo "Unrelated compressed bomb was not rejected during whole-archive preflight" >&2
    exit 1
  }
fi

if [ -e "$app_bundle/Contents/lib/Sparkle.framework" ]; then
  echo "Release app unexpectedly bundled Sparkle.framework" >&2
  exit 1
fi

build_wait_path="$TMP_DIR/build-app-lock"
first_build_log="$TMP_DIR/first-build.log"
EASYSPLAT_TEST_BUILD_WAIT_PATH="$build_wait_path" \
EASYSPLAT_XCODEBUILD_BIN="$mock_xcodebuild" \
  "$ROOT/scripts/release/build_app.sh" \
  --build-root "$release_test_build_root" \
  --toolchain-dir "$toolchain_tree" \
  --project-url "$project_url" \
  --version "0.2.0" \
  --development-unsigned >"$first_build_log" 2>&1 &
first_build_pid=$!

for _ in {1..200}; do
  [ -e "$build_wait_path.ready" ] && break
  sleep 0.05
done
if [ ! -e "$build_wait_path.ready" ]; then
  kill "$first_build_pid" 2>/dev/null || true
  wait "$first_build_pid" 2>/dev/null || true
  echo "Timed out waiting for the first app build" >&2
  exit 1
fi

second_build_error="$TMP_DIR/second-build.stderr"
second_build_succeeded=0
if EASYSPLAT_XCODEBUILD_BIN="$mock_xcodebuild" \
  "$ROOT/scripts/release/build_app.sh" \
  --build-root "$release_test_build_root" \
  --toolchain-dir "$toolchain_tree" \
  --project-url "$project_url" \
  --version "0.2.0" \
  --development-unsigned >/dev/null 2>"$second_build_error"; then
  second_build_succeeded=1
fi
: >"$build_wait_path.release"
wait "$first_build_pid"

if [ "$second_build_succeeded" -eq 1 ]; then
  echo "Concurrent app builds were allowed to corrupt shared release output" >&2
  exit 1
fi
if ! grep -Fqi 'app build is already in progress' "$second_build_error"; then
  echo "Concurrent-build rejection did not report the active build lock" >&2
  cat "$second_build_error" >&2
  exit 1
fi

# The build checks the toolchain tree, then reads it again to stage and to
# compare. Replacing a helper between those reads must not reach the product.
snapshot_swap_tree="$TMP_DIR/snapshot-swap-toolchain"
/usr/bin/ditto "$toolchain_tree" "$snapshot_swap_tree"
# The trainer stands in for a swapped colmap: a real Mach-O the build could
# stage and sign, distinguishable only by the marker string it carries.
snapshot_replacement_helper="$snapshot_swap_tree/bin/easysplat-train"

snapshot_swap_root="$TMP_DIR/snapshot-swap-build"
snapshot_wait_path="$TMP_DIR/snapshot-swap-wait"
snapshot_build_log="$TMP_DIR/snapshot-swap-build.log"
EASYSPLAT_TEST_BUILD_WAIT_PATH="$snapshot_wait_path" \
EASYSPLAT_XCODEBUILD_BIN="$mock_xcodebuild" \
  "$ROOT/scripts/release/build_app.sh" \
  --build-root "$snapshot_swap_root" \
  --toolchain-dir "$snapshot_swap_tree" \
  --project-url "$project_url" \
  --version "0.2.0" \
  --development-unsigned >"$snapshot_build_log" 2>&1 &
snapshot_build_pid=$!

for _ in {1..200}; do
  [ -e "$snapshot_wait_path.ready" ] && break
  sleep 0.05
done
if [ ! -e "$snapshot_wait_path.ready" ]; then
  kill "$snapshot_build_pid" 2>/dev/null || true
  wait "$snapshot_build_pid" 2>/dev/null || true
  echo "Timed out waiting for the input-snapshot app build." >&2
  exit 1
fi
cp "$snapshot_replacement_helper" "$snapshot_swap_tree/bin/colmap"
: >"$snapshot_wait_path.release"
if ! wait "$snapshot_build_pid"; then
  echo "Release app build did not preserve its authenticated toolchain snapshot." >&2
  cat "$snapshot_build_log" >&2
  exit 1
fi
snapshot_staged_helper="$snapshot_swap_root/Export/EasySplat.app/Contents/Helpers/bin/colmap"
LC_ALL=C grep -aq 'native-colmap' "$snapshot_staged_helper"
if LC_ALL=C grep -aq 'native-msplat' "$snapshot_staged_helper"; then
  echo "Release app staged a toolchain helper replaced after input validation." >&2
  exit 1
fi

# Keep the complete signing suite intact, but let cheap contract failures surface first.
swift test --package-path "$ROOT/Tools/ManifestTool"

release_tests_completed=1
