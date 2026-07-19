from __future__ import annotations

import hashlib
import json
import os
import stat
import subprocess
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[3]
HELPER = ROOT / "scripts/release/notarize_artifact.sh"
SUBMISSION_ID = "a2a4ed8f-4d52-47d5-bf09-0c682d8146c9"


class NotarizeArtifactTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary_directory = tempfile.TemporaryDirectory(
            prefix="easysplat-notarize-test."
        )
        self.root = Path(self.temporary_directory.name).resolve()
        self.bin = self.root / "bin"
        self.bin.mkdir(mode=0o700)
        self.command_log = self.root / "commands.jsonl"
        self._write_command_shims()

    def tearDown(self) -> None:
        self.temporary_directory.cleanup()

    def _write_command_shims(self) -> None:
        xcrun = self.bin / "xcrun"
        xcrun.write_text(
            """#!/usr/bin/env bash
set -euo pipefail
/usr/bin/python3 - "$FAKE_COMMAND_LOG" "$@" <<'PY'
import json
import sys
with open(sys.argv[1], "a", encoding="utf-8") as handle:
    handle.write(json.dumps(["xcrun", *sys.argv[2:]], separators=(",", ":")) + "\\n")
PY
if [ "$1" = notarytool ] && [ "$2" = submit ]; then
  if [ "${FAKE_SUBMIT_OVERSIZE:-0}" = 1 ]; then
    /usr/bin/python3 - <<'PY'
import sys
sys.stdout.write("x" * (1024 * 1024 + 4096))
PY
    exit 0
  fi
  if [ "${FAKE_MUTATE_ARTIFACT_DURING_SUBMIT:-0}" = 1 ]; then
    if [ -d "$FAKE_ARTIFACT_PATH" ]; then
      printf 'submit-time mutation' >>"$FAKE_ARTIFACT_PATH/Contents/MacOS/EasySplatApp"
    else
      printf 'submit-time mutation' >>"$FAKE_ARTIFACT_PATH"
    fi
  fi
  status="${FAKE_NOTARY_STATUS:-Accepted}"
  printf '{"id":"%s","status":"%s"}\\n' "$FAKE_SUBMISSION_ID" "$status"
  printf 'profile=%s artifact=%s https://alice:password@example.test /Users/alice/source /Volumes/Private/input\\n' \
    "${@: -5:1}" "$3" >&2
  exit "${FAKE_SUBMIT_EXIT:-0}"
fi
if [ "$1" = notarytool ] && [ "$2" = log ]; then
  output="$4"
  if [ "${FAKE_LOG_OVERSIZE:-0}" = 1 ]; then
    /usr/bin/python3 - "$output" <<'PY'
import sys
with open(sys.argv[1], "wb") as handle:
    handle.write(b"x" * (4 * 1024 * 1024 + 4096))
PY
    exit 0
  fi
  printf '{"issues":[{"path":"%s","message":"profile %s at /Users/alice/source and /Volumes/Private/input via https://alice:password@example.test"}]}\\n' \
    "$FAKE_ARTIFACT_PATH" "$FAKE_PROFILE" >"$output"
  exit "${FAKE_LOG_EXIT:-0}"
fi
if [ "$1" = stapler ] && [ "$2" = staple ]; then
  target="${@: -1}"
  if [ "${FAKE_STAPLE_NOOP:-0}" = 1 ]; then
    exit 0
  elif [ -d "$target" ]; then
    mkdir -p "$target/Contents/_CodeSignature"
    printf 'notary-ticket' >"$target/Contents/_CodeSignature/notary-ticket"
  else
    printf 'notary-ticket' >>"$target"
  fi
  exit 0
fi
exit 0
""",
            encoding="utf-8",
        )
        xcrun.chmod(0o700)

        passthrough = """#!/usr/bin/env bash
set -euo pipefail
command_name="$(basename "$0")"
/usr/bin/python3 - "$FAKE_COMMAND_LOG" "$command_name" "$@" <<'PY'
import json
import sys
with open(sys.argv[1], "a", encoding="utf-8") as handle:
    handle.write(json.dumps(sys.argv[2:], separators=(",", ":")) + "\\n")
PY
if [ "$command_name" = ditto ]; then
  printf 'private app submission archive' >"${@: -1}"
fi
if [ "${FAKE_FAIL_COMMAND:-}" = "$command_name" ]; then
  printf 'failed %s for profile %s at %s\\n' \
    "$command_name" "$FAKE_PROFILE" "$FAKE_ARTIFACT_PATH" >&2
  exit 9
fi
"""
        for name in ("codesign", "syspolicy_check", "spctl", "ditto"):
            path = self.bin / name
            path.write_text(passthrough, encoding="utf-8")
            path.chmod(0o700)

    def _environment(self) -> dict[str, str]:
        environment = os.environ.copy()
        environment.update(
            {
                "EASYSPLAT_NOTARY_TEST_MODE": "1",
                "EASYSPLAT_NOTARY_XCRUN_BIN": str(self.bin / "xcrun"),
                "EASYSPLAT_NOTARY_CODESIGN_BIN": str(self.bin / "codesign"),
                "EASYSPLAT_NOTARY_SYSPOLICY_BIN": str(
                    self.bin / "syspolicy_check"
                ),
                "EASYSPLAT_NOTARY_SPCTL_BIN": str(self.bin / "spctl"),
                "EASYSPLAT_NOTARY_DITTO_BIN": str(self.bin / "ditto"),
                "FAKE_COMMAND_LOG": str(self.command_log),
                "FAKE_SUBMISSION_ID": SUBMISSION_ID,
                "FAKE_ARTIFACT_PATH": "",
                "FAKE_PROFILE": "easysplat-production",
            }
        )
        return environment

    def _run_helper(
        self,
        artifact_type: str,
        artifact: Path,
        *,
        profile: str = "easysplat-production",
        receipt: Path | None = None,
        diagnostics: Path | None = None,
        extra_environment: dict[str, str] | None = None,
    ) -> tuple[subprocess.CompletedProcess[str], Path, Path]:
        receipt = receipt or self.root / "receipt.json"
        diagnostics = diagnostics or self.root / "diagnostics"
        environment = self._environment()
        environment["FAKE_ARTIFACT_PATH"] = str(artifact)
        environment["FAKE_PROFILE"] = profile
        if extra_environment:
            environment.update(extra_environment)
        result = subprocess.run(
            [
                str(HELPER),
                "--type",
                artifact_type,
                "--artifact",
                str(artifact),
                "--keychain-profile",
                profile,
                "--receipt",
                str(receipt),
                "--diagnostics-dir",
                str(diagnostics),
            ],
            cwd=ROOT,
            env=environment,
            text=True,
            capture_output=True,
            check=False,
        )
        return result, receipt, diagnostics

    def _commands(self) -> list[list[str]]:
        if not self.command_log.exists():
            return []
        return [
            json.loads(line)
            for line in self.command_log.read_text(encoding="utf-8").splitlines()
        ]

    def test_zip_submission_writes_verified_atomic_receipt(self) -> None:
        artifact = self.root / "EasySplat.zip"
        artifact.write_bytes(b"signed archive")
        receipt = self.root / "receipt.json"
        diagnostics = self.root / "diagnostics"

        result, _, _ = self._run_helper(
            "zip", artifact, receipt=receipt, diagnostics=diagnostics
        )

        self.assertEqual(result.returncode, 0, result.stderr)
        payload = json.loads(receipt.read_text(encoding="utf-8"))
        expected_hash = hashlib.sha256(artifact.read_bytes()).hexdigest()
        self.assertEqual(payload["artifactType"], "zip")
        self.assertEqual(payload["submissionID"], SUBMISSION_ID)
        self.assertEqual(payload["status"], "Accepted")
        self.assertEqual(payload["preStapleSHA256"], expected_hash)
        self.assertEqual(payload["postStapleSHA256"], expected_hash)
        self.assertFalse(payload["stapled"])
        self.assertEqual(payload["artifactDigestFormat"], "sha256-file-v1")
        self.assertEqual(
            payload["verification"],
            {
                "codesign": "notApplicable",
                "systemPolicy": "notApplicable",
                "stapler": "notApplicable",
                "gatekeeper": "notApplicable",
            },
        )
        receipt_text = receipt.read_text(encoding="utf-8")
        self.assertNotIn("easysplat-production", receipt_text)
        self.assertNotIn(str(artifact), receipt_text)
        self.assertEqual(stat.S_IMODE(receipt.stat().st_mode), 0o600)
        commands = self._commands()
        self.assertEqual(
            commands,
            [
                [
                    "xcrun",
                    "notarytool",
                    "submit",
                    str(artifact),
                    "--keychain-profile",
                    "easysplat-production",
                    "--wait",
                    "--output-format",
                    "json",
                ]
            ],
        )
        self.assertNotIn("easysplat-production", result.stdout + result.stderr)

    def test_app_is_submitted_as_private_zip_then_stapled_and_verified(self) -> None:
        artifact = self.root / "EasySplat.app"
        executable = artifact / "Contents/MacOS/EasySplatApp"
        executable.parent.mkdir(parents=True)
        executable.write_bytes(b"signed executable")

        result, receipt, _ = self._run_helper("app", artifact)

        self.assertEqual(result.returncode, 0, result.stderr)
        payload = json.loads(receipt.read_text(encoding="utf-8"))
        self.assertEqual(payload["artifactType"], "app")
        self.assertTrue(payload["stapled"])
        self.assertEqual(payload["artifactDigestFormat"], "sha256-tree-v1")
        self.assertEqual(
            payload["verification"],
            {
                "codesign": "passed",
                "systemPolicy": "passed",
                "stapler": "passed",
                "gatekeeper": "passed",
            },
        )
        self.assertNotEqual(
            payload["preStapleSHA256"], payload["postStapleSHA256"]
        )
        commands = self._commands()
        self.assertEqual(commands[0][0:4], ["ditto", "-c", "-k", "--keepParent"])
        self.assertEqual(commands[0][4], str(artifact))
        submission_archive = commands[0][5]
        self.assertTrue(submission_archive.endswith(".zip"))
        self.assertNotEqual(submission_archive, str(artifact))
        self.assertEqual(
            commands[1],
            [
                "xcrun",
                "notarytool",
                "submit",
                submission_archive,
                "--keychain-profile",
                "easysplat-production",
                "--wait",
                "--output-format",
                "json",
            ],
        )
        self.assertEqual(
            commands[2:],
            [
                ["xcrun", "stapler", "staple", str(artifact)],
                [
                    "codesign",
                    "--verify",
                    "--deep",
                    "--strict",
                    "--verbose=4",
                    str(artifact),
                ],
                ["syspolicy_check", "distribution", "--bundle", str(artifact)],
                ["xcrun", "stapler", "validate", str(artifact)],
                ["spctl", "--assess", "--type", "execute", str(artifact)],
            ],
        )
        self.assertNotIn("easysplat-production", result.stdout + result.stderr)

    def test_dmg_is_stapled_then_assessed_as_primary_signature(self) -> None:
        artifact = self.root / "EasySplat.dmg"
        artifact.write_bytes(b"signed disk image")

        result, receipt, _ = self._run_helper("dmg", artifact)

        self.assertEqual(result.returncode, 0, result.stderr)
        payload = json.loads(receipt.read_text(encoding="utf-8"))
        self.assertEqual(payload["artifactType"], "dmg")
        self.assertTrue(payload["stapled"])
        self.assertEqual(payload["artifactDigestFormat"], "sha256-file-v1")
        self.assertEqual(
            payload["verification"],
            {
                "codesign": "notApplicable",
                "systemPolicy": "notApplicable",
                "stapler": "passed",
                "gatekeeper": "passed",
            },
        )
        self.assertNotEqual(
            payload["preStapleSHA256"], payload["postStapleSHA256"]
        )
        self.assertEqual(
            self._commands(),
            [
                [
                    "xcrun",
                    "notarytool",
                    "submit",
                    str(artifact),
                    "--keychain-profile",
                    "easysplat-production",
                    "--wait",
                    "--output-format",
                    "json",
                ],
                ["xcrun", "stapler", "staple", str(artifact)],
                ["xcrun", "stapler", "validate", str(artifact)],
                [
                    "spctl",
                    "--assess",
                    "--type",
                    "open",
                    "--context",
                    "context:primary-signature",
                    str(artifact),
                ],
            ],
        )

    def test_rejected_submission_writes_only_scrubbed_private_diagnostic(self) -> None:
        artifact = self.root / "EasySplat.zip"
        artifact.write_bytes(b"signed archive")

        result, receipt, diagnostics = self._run_helper(
            "zip",
            artifact,
            extra_environment={"FAKE_NOTARY_STATUS": "Invalid"},
        )

        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(receipt.exists())
        self.assertTrue(diagnostics.is_dir())
        self.assertEqual(stat.S_IMODE(diagnostics.stat().st_mode), 0o700)
        diagnostic_files = list(diagnostics.iterdir())
        self.assertEqual(len(diagnostic_files), 1)
        diagnostic = diagnostic_files[0]
        self.assertEqual(stat.S_IMODE(diagnostic.stat().st_mode), 0o600)
        diagnostic_text = diagnostic.read_text(encoding="utf-8")
        for secret in (
            "easysplat-production",
            str(artifact),
            "/Users/alice",
            "/Volumes/Private",
            "alice:password@",
        ):
            self.assertNotIn(secret, diagnostic_text)
        self.assertIn("<artifact>", diagnostic_text)
        self.assertIn("/Users/<redacted>", diagnostic_text)
        self.assertIn("/Volumes/<redacted>", diagnostic_text)
        self.assertIn("https://<redacted>@example.test", diagnostic_text)
        self.assertNotIn("easysplat-production", result.stdout + result.stderr)
        commands = self._commands()
        self.assertEqual(commands[0][1:3], ["notarytool", "submit"])
        self.assertEqual(
            commands[1][0:4],
            ["xcrun", "notarytool", "log", SUBMISSION_ID],
        )
        self.assertEqual(
            commands[1][5:],
            ["--keychain-profile", "easysplat-production"],
        )

    def test_profile_name_is_strict_and_never_echoed(self) -> None:
        artifact = self.root / "EasySplat.zip"
        artifact.write_bytes(b"signed archive")
        invalid_profiles = (
            ".hidden",
            "-leading",
            "contains space",
            "nested/profile",
            "line\nbreak",
            "a" * 65,
            "prod --password do-not-print",
        )

        for profile in invalid_profiles:
            with self.subTest(profile=repr(profile)):
                if self.command_log.exists():
                    self.command_log.unlink()
                result, receipt, _ = self._run_helper(
                    "zip",
                    artifact,
                    profile=profile,
                    receipt=self.root / f"receipt-{len(profile)}.json",
                )
                self.assertEqual(result.returncode, 64)
                self.assertNotIn(profile, result.stdout + result.stderr)
                self.assertFalse(receipt.exists())
                self.assertEqual(self._commands(), [])

    def test_unsafe_artifact_and_output_paths_are_rejected_before_commands(self) -> None:
        regular = self.root / "EasySplat.zip"
        regular.write_bytes(b"signed archive")
        symlink_artifact = self.root / "Linked.zip"
        symlink_artifact.symlink_to(regular)
        fifo_artifact = self.root / "Pipe.zip"
        os.mkfifo(fifo_artifact, mode=0o600)
        actual_directory = self.root / "actual"
        actual_directory.mkdir()
        nested_artifact = actual_directory / "Nested.zip"
        nested_artifact.write_bytes(b"signed archive")
        linked_directory = self.root / "linked-directory"
        linked_directory.symlink_to(actual_directory, target_is_directory=True)

        cases = (
            ("relative artifact", "zip", Path("EasySplat.zip"), None, None),
            (
                "lexical traversal",
                "zip",
                Path(f"{self.root}/missing/../EasySplat.zip"),
                None,
                None,
            ),
            ("artifact symlink", "zip", symlink_artifact, None, None),
            ("artifact special file", "zip", fifo_artifact, None, None),
            (
                "symlinked artifact parent",
                "zip",
                linked_directory / "Nested.zip",
                None,
                None,
            ),
            (
                "receipt symlink",
                "zip",
                regular,
                self.root / "receipt-link.json",
                None,
            ),
            (
                "diagnostics symlink",
                "zip",
                regular,
                None,
                self.root / "diagnostics-link",
            ),
        )
        (self.root / "receipt-link.json").symlink_to(self.root / "outside.json")
        (self.root / "diagnostics-link").symlink_to(
            actual_directory, target_is_directory=True
        )

        for name, artifact_type, artifact, receipt, diagnostics in cases:
            with self.subTest(name=name):
                if self.command_log.exists():
                    self.command_log.unlink()
                result, _, _ = self._run_helper(
                    artifact_type,
                    artifact,
                    receipt=receipt or self.root / f"{name}.json",
                    diagnostics=diagnostics or self.root / f"{name}-diagnostics",
                )
                self.assertEqual(result.returncode, 64, result.stderr)
                self.assertEqual(self._commands(), [])

    def test_invalid_submission_identifier_does_not_request_unbound_log(self) -> None:
        artifact = self.root / "EasySplat.zip"
        artifact.write_bytes(b"signed archive")

        result, receipt, diagnostics = self._run_helper(
            "zip",
            artifact,
            extra_environment={"FAKE_SUBMISSION_ID": "not-a-stable-id"},
        )

        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(receipt.exists())
        self.assertEqual(len(self._commands()), 1)
        diagnostic_files = list(diagnostics.iterdir())
        self.assertEqual(len(diagnostic_files), 1)
        diagnostic_text = diagnostic_files[0].read_text(encoding="utf-8")
        self.assertNotIn("easysplat-production", diagnostic_text)
        self.assertNotIn(str(artifact), diagnostic_text)

    def test_submission_and_failure_log_outputs_are_bounded(self) -> None:
        artifact = self.root / "EasySplat.zip"
        artifact.write_bytes(b"signed archive")

        oversized_submission, receipt, diagnostics = self._run_helper(
            "zip",
            artifact,
            extra_environment={"FAKE_SUBMIT_OVERSIZE": "1"},
        )
        self.assertNotEqual(oversized_submission.returncode, 0)
        self.assertFalse(receipt.exists())
        self.assertLessEqual(
            max(path.stat().st_size for path in diagnostics.iterdir()),
            4 * 1024 * 1024,
        )

        self.command_log.unlink()
        oversized_log, receipt, diagnostics = self._run_helper(
            "zip",
            artifact,
            receipt=self.root / "second-receipt.json",
            diagnostics=self.root / "second-diagnostics",
            extra_environment={
                "FAKE_NOTARY_STATUS": "Invalid",
                "FAKE_LOG_OVERSIZE": "1",
            },
        )
        self.assertNotEqual(oversized_log.returncode, 0)
        self.assertFalse(receipt.exists())
        self.assertLessEqual(
            max(path.stat().st_size for path in diagnostics.iterdir()),
            4 * 1024 * 1024,
        )
        self.assertEqual(self._commands()[1][1:3], ["notarytool", "log"])

    def test_failed_post_staple_verification_preserves_existing_receipt(self) -> None:
        artifact = self.root / "EasySplat.app"
        executable = artifact / "Contents/MacOS/EasySplatApp"
        executable.parent.mkdir(parents=True)
        executable.write_bytes(b"signed executable")
        receipt = self.root / "receipt.json"
        receipt.write_text("existing verified receipt\n", encoding="utf-8")

        result, _, _ = self._run_helper(
            "app",
            artifact,
            receipt=receipt,
            extra_environment={"FAKE_FAIL_COMMAND": "codesign"},
        )

        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(
            receipt.read_text(encoding="utf-8"), "existing verified receipt\n"
        )
        self.assertNotIn("easysplat-production", result.stdout + result.stderr)

    def test_stapling_must_change_app_or_dmg_before_receipt_publication(self) -> None:
        for artifact_type, suffix, payload in (
            ("app", ".app", b"signed executable"),
            ("dmg", ".dmg", b"signed disk image"),
        ):
            with self.subTest(artifact_type=artifact_type):
                if self.command_log.exists():
                    self.command_log.unlink()
                artifact = self.root / f"NoChange-{artifact_type}{suffix}"
                if artifact_type == "app":
                    executable = artifact / "Contents/MacOS/EasySplatApp"
                    executable.parent.mkdir(parents=True)
                    executable.write_bytes(payload)
                else:
                    artifact.write_bytes(payload)
                result, receipt, _ = self._run_helper(
                    artifact_type,
                    artifact,
                    receipt=self.root / f"{artifact_type}-receipt.json",
                    diagnostics=self.root / f"{artifact_type}-diagnostics",
                    extra_environment={"FAKE_STAPLE_NOOP": "1"},
                )
                self.assertNotEqual(result.returncode, 0)
                self.assertFalse(receipt.exists())

    def test_submit_time_source_mutation_is_rejected_before_stapling(self) -> None:
        for artifact_type, suffix, payload in (
            ("app", ".app", b"signed executable"),
            ("zip", ".zip", b"signed archive"),
            ("dmg", ".dmg", b"signed disk image"),
        ):
            with self.subTest(artifact_type=artifact_type):
                if self.command_log.exists():
                    self.command_log.unlink()
                artifact = self.root / f"Mutated-{artifact_type}{suffix}"
                if artifact_type == "app":
                    executable = artifact / "Contents/MacOS/EasySplatApp"
                    executable.parent.mkdir(parents=True)
                    executable.write_bytes(payload)
                else:
                    artifact.write_bytes(payload)
                result, receipt, _ = self._run_helper(
                    artifact_type,
                    artifact,
                    receipt=self.root / f"mutated-{artifact_type}-receipt.json",
                    diagnostics=self.root / f"mutated-{artifact_type}-diagnostics",
                    extra_environment={
                        "FAKE_MUTATE_ARTIFACT_DURING_SUBMIT": "1"
                    },
                )
                self.assertNotEqual(result.returncode, 0)
                self.assertFalse(receipt.exists())
                self.assertNotIn(
                    ["xcrun", "stapler", "staple", str(artifact)],
                    self._commands(),
                )


if __name__ == "__main__":
    unittest.main()
