from __future__ import annotations

import importlib.util
import json
import os
import subprocess
import tempfile
import unittest
from pathlib import Path


SCRIPT = Path(__file__).resolve().parents[1] / "create_dmg.sh"
RECEIPT_HELPER = SCRIPT.parent / "verify_notarization_receipt.py"
SPEC = importlib.util.spec_from_file_location(
    "verify_notarization_receipt_for_create_dmg_tests",
    RECEIPT_HELPER,
)
assert SPEC and SPEC.loader
RECEIPT_MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(RECEIPT_MODULE)


class CreateDMGAdmissionTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary_directory = tempfile.TemporaryDirectory(
            prefix="easysplat-create-dmg-test."
        )
        self.root = Path(self.temporary_directory.name).resolve()
        self.app = self.root / "EasySplat.app"
        self.executable = self.app / "Contents/MacOS/EasySplatApp"
        self.executable.parent.mkdir(parents=True)
        self.receipt = self.root / "app-notarization.json"
        self.output = self.root / "EasySplat.dmg"
        self.bin = self.root / "bin"
        self.bin.mkdir()
        self.command_log = self.root / "commands.jsonl"
        self._reset_app_and_receipt()
        self._write_command_shims()

    def tearDown(self) -> None:
        self.temporary_directory.cleanup()

    def _reset_app_and_receipt(self) -> None:
        self.executable.write_bytes(b"locally forged unsigned app")
        digest = RECEIPT_MODULE.artifact_sha256(self.app)
        self.receipt.write_text(
            json.dumps(
                {
                    "schemaVersion": 1,
                    "artifactType": "app",
                    "artifactDigestFormat": "sha256-tree-v1",
                    "submissionID": "a2a4ed8f-4d52-47d5-bf09-0c682d8146c9",
                    "status": "Accepted",
                    "preStapleSHA256": "0" * 64,
                    "postStapleSHA256": digest,
                    "stapled": True,
                    "verification": {
                        "codesign": "passed",
                        "systemPolicy": "passed",
                        "stapler": "passed",
                        "gatekeeper": "passed",
                    },
                    "downstreamChecksums": "generate-after-notarization",
                },
                separators=(",", ":"),
            ),
            encoding="utf-8",
        )
        self.output.unlink(missing_ok=True)
        self.command_log.unlink(missing_ok=True)

    def _write_command_shims(self) -> None:
        source = """#!/bin/bash -p
set -euo pipefail
command_name="$(/usr/bin/basename "$0")"
logical_name="$command_name"
if [ "$command_name" = xcrun ] && [ "${1:-}" = stapler ]; then
  logical_name=stapler
fi
/usr/bin/python3 - "$EASYSPLAT_CREATE_DMG_COMMAND_LOG" "$logical_name" "$@" <<'PY'
import json
import sys
with open(sys.argv[1], "a", encoding="utf-8") as handle:
    handle.write(json.dumps(sys.argv[2:], separators=(",", ":")) + "\\n")
PY
if [ "${EASYSPLAT_CREATE_DMG_MUTATE_COMMAND:-}" = "$logical_name" ]; then
  printf 'mutation' >>"${@: -1}/Contents/MacOS/EasySplatApp"
fi
if [ "${EASYSPLAT_CREATE_DMG_FAIL_COMMAND:-}" = "$logical_name" ]; then
  printf 'forced %s failure\\n' "$logical_name" >&2
  exit 9
fi
if [ "$logical_name" = hdiutil ] && [ "${1:-}" = create ]; then
  printf 'test dmg' >"${@: -1}"
fi
"""
        for name in ("codesign", "xcrun", "spctl", "syspolicy_check", "hdiutil"):
            path = self.bin / name
            path.write_text(source, encoding="utf-8")
            path.chmod(0o700)

    def _test_environment(
        self,
        *,
        fail_command: str = "",
        mutate_command: str = "",
        test_mode: bool = True,
    ) -> dict[str, str]:
        environment = self._clean_environment()
        environment.update(
            {
                "EASYSPLAT_NOTARY_TEST_MODE": "1" if test_mode else "0",
                "EASYSPLAT_NOTARY_CODESIGN_BIN": str(self.bin / "codesign"),
                "EASYSPLAT_NOTARY_XCRUN_BIN": str(self.bin / "xcrun"),
                "EASYSPLAT_NOTARY_SPCTL_BIN": str(self.bin / "spctl"),
                "EASYSPLAT_NOTARY_SYSPOLICY_BIN": str(
                    self.bin / "syspolicy_check"
                ),
                "EASYSPLAT_HDIUTIL_BIN": str(self.bin / "hdiutil"),
                "EASYSPLAT_CREATE_DMG_COMMAND_LOG": str(self.command_log),
                "EASYSPLAT_CREATE_DMG_FAIL_COMMAND": fail_command,
                "EASYSPLAT_CREATE_DMG_MUTATE_COMMAND": mutate_command,
            }
        )
        return environment

    @staticmethod
    def _clean_environment() -> dict[str, str]:
        environment = os.environ.copy()
        for name in ("GITHUB_PERSONAL_ACCESS_TOKEN", "GH_TOKEN", "GITHUB_TOKEN"):
            environment.pop(name, None)
        return environment

    def _run(
        self,
        environment: dict[str, str] | None = None,
    ) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            [
                str(SCRIPT),
                "--app-path",
                str(self.app),
                "--out",
                str(self.output),
                "--app-notarization-receipt",
                str(self.receipt),
            ],
            cwd=SCRIPT.parents[2],
            env=environment,
            text=True,
            capture_output=True,
            check=False,
        )

    def test_locally_forged_accepted_receipt_cannot_authorize_a_dmg(self) -> None:
        result = self._run(self._clean_environment())

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("codesign", result.stderr.lower())
        self.assertFalse(self.output.exists())

    def test_test_command_overrides_require_the_isolated_notary_gate(self) -> None:
        result = self._run(self._test_environment(test_mode=False))

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("test command overrides", result.stderr.lower())
        self.assertFalse(self.output.exists())

    def test_all_live_apple_admission_checks_precede_dmg_creation(self) -> None:
        result = self._run(self._test_environment())

        self.assertEqual(result.returncode, 0, result.stderr)
        commands = [
            json.loads(line)
            for line in self.command_log.read_text(encoding="utf-8").splitlines()
        ]
        self.assertEqual(
            [command[0] for command in commands],
            ["codesign", "stapler", "spctl", "syspolicy_check", "hdiutil", "hdiutil"],
        )
        self.assertEqual(commands[0][1:4], ["--verify", "--deep", "--strict"])
        self.assertEqual(commands[1][1:3], ["stapler", "validate"])
        self.assertEqual(commands[2][1:4], ["--assess", "--type", "execute"])
        self.assertEqual(
            commands[3][1:],
            ["distribution", commands[2][-1]],
        )
        self.assertTrue(self.output.is_file())

    def test_each_live_apple_admission_failure_stops_publication(self) -> None:
        for command in ("codesign", "stapler", "spctl", "syspolicy_check"):
            with self.subTest(command=command):
                self._reset_app_and_receipt()
                result = self._run(
                    self._test_environment(fail_command=command)
                )

                self.assertNotEqual(result.returncode, 0)
                self.assertIn(command, result.stderr.lower())
                self.assertFalse(self.output.exists())

    def test_each_live_apple_admission_mutation_is_rejected(self) -> None:
        for command in ("codesign", "stapler", "spctl", "syspolicy_check"):
            with self.subTest(command=command):
                self._reset_app_and_receipt()
                result = self._run(
                    self._test_environment(mutate_command=command)
                )

                self.assertNotEqual(result.returncode, 0)
                self.assertRegex(
                    result.stderr.lower(),
                    r"artifact.*changed|current artifact bytes|identity changed",
                )
                self.assertFalse(self.output.exists())


if __name__ == "__main__":
    unittest.main()
