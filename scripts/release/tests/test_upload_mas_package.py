#!/usr/bin/env python3
"""The App Store submitter must refuse everything before it reaches Apple."""

from __future__ import annotations

import os
import shlex
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
SCRIPT = ROOT / "scripts/release/upload_mas_package.sh"
KEY_ID = "N5GX84DZ8U"
ISSUER_ID = "602c0cb4-35d6-4fe0-876a-189570deab1e"
APPLE_ID = "1234567890"
APP_VERSION = "0.2.0"
APP_BUILD = "207"


class UploadMasPackageTests(unittest.TestCase):
    def setUp(self) -> None:
        self._evidence_directory = tempfile.TemporaryDirectory()
        self.default_evidence = Path(self._evidence_directory.name).resolve() / "evidence.json"
        self.default_evidence.write_text("{}\n", encoding="utf-8")

    def tearDown(self) -> None:
        self._evidence_directory.cleanup()

    def run_script(
        self,
        *arguments: str,
        home: Path | None = None,
        include_default_evidence: bool = True,
    ):
        environment = dict(os.environ)
        if home is not None:
            environment["HOME"] = str(home)
        effective_arguments = list(arguments)
        if (
            effective_arguments
            and include_default_evidence
            and "--evidence" not in effective_arguments
        ):
            effective_arguments.extend(["--evidence", str(self.default_evidence)])
        return subprocess.run(
            [str(SCRIPT), *effective_arguments],
            capture_output=True,
            text=True,
            env=environment,
        )

    def package(self, directory: Path, name: str = "EasySplat.pkg") -> Path:
        path = directory / name
        path.write_bytes(b"not really a package")
        return path

    def key_home(self, directory: Path, key_id: str = KEY_ID) -> Path:
        keys = directory / ".appstoreconnect/private_keys"
        keys.mkdir(parents=True)
        key = keys / f"AuthKey_{key_id}.p8"
        key.write_text("-----BEGIN PRIVATE KEY-----\n", encoding="ascii")
        key.chmod(0o600)
        return directory

    def submission_harness(
        self,
        directory: Path,
        *,
        cleanup_fails: bool = False,
        first_status_fails: bool = False,
        first_upload_receipt_fails: bool = False,
    ) -> tuple[Path, dict[str, str], Path]:
        home = self.key_home(directory / "home")
        altool_log = directory / "altool.log"
        status_counter = directory / "status-counter"

        fake_altool = directory / "fake-altool"
        fake_altool.write_text(
            "#!/bin/bash\n"
            "set -euo pipefail\n"
            "printf '%s\\0' \"$@\" >>\"$EASYSPLAT_TEST_ALTOOL_LOG\"\n"
            "printf '\\n' >>\"$EASYSPLAT_TEST_ALTOOL_LOG\"\n"
            "if [[ \" $* \" == *' --version '* ]]; then\n"
            "  printf '26.40.1 (174001)\\n'\n"
            "elif [[ \" $* \" == *' --upload-app '* ]]; then\n"
            "  printf '{\"delivery-id\":\"be9c5d83-4150-40cb-91a1-739cf69a6f35\",\"success-message\":\"accepted\"}\\n'\n"
            "elif [[ \" $* \" == *' --build-status '* ]]; then\n"
            "  count=0\n"
            "  if [ -f \"$EASYSPLAT_TEST_STATUS_COUNTER\" ]; then count=$(cat \"$EASYSPLAT_TEST_STATUS_COUNTER\"); fi\n"
            "  count=$((count + 1))\n"
            "  printf '%s' \"$count\" >\"$EASYSPLAT_TEST_STATUS_COUNTER\"\n"
            + (
                "  if [ \"$count\" -eq 1 ]; then exit 17; fi\n"
                if first_status_fails
                else ""
            )
            + "  printf '{\"delivery-id\":\"be9c5d83-4150-40cb-91a1-739cf69a6f35\",\"internal-build-state\":\"READY_TO_TEST\",\"is-on-app-store-connect\":true,\"processing-errors\":[]}\\n'\n"
            "else\n"
            "  printf '{\"success-message\":\"validated\"}\\n'\n"
            "fi\n",
            encoding="utf-8",
        )
        fake_altool.chmod(0o700)

        fake_pkgutil = directory / "fake-pkgutil"
        fake_pkgutil.write_text(
            "#!/bin/bash\n"
            "printf '%s\\n' 'Mac Installer Distribution: EasySplat Test'\n",
            encoding="utf-8",
        )
        fake_pkgutil.chmod(0o700)

        fake_evidence = directory / "fake-evidence.py"
        fake_evidence.write_text(
            """#!/usr/bin/env python3
import os
import shutil
import subprocess
import sys


def option(name: str) -> str:
    return sys.argv[sys.argv.index(name) + 1]


command = sys.argv[1]
if command == "snapshot-package":
    shutil.copyfile(option("--package"), option("--output"))
    print("test-snapshot-token")
elif command == "cleanup-snapshot":
    if os.environ.get("EASYSPLAT_TEST_CLEANUP_FAILS") == "1":
        raise SystemExit(19)
    os.unlink(option("--snapshot"))
    os.rmdir(option("--root"))
elif command == "cleanup-responses":
    if os.environ.get("EASYSPLAT_TEST_CLEANUP_FAILS") == "1":
        raise SystemExit(19)
    responses = [
        sys.argv[index + 1]
        for index, value in enumerate(sys.argv[:-1])
        if value == "--response"
    ]
    for response in responses:
        os.unlink(response)
    os.rmdir(option("--root"))
elif command == "start-upload-attempt":
    response = option("--package") + ".pending-upload-response.json"
    with open(option("--output"), "x", encoding="utf-8") as output:
        output.write(response + "\\n")
    print(response)
elif command == "verify-upload-attempt":
    with open(option("--attempt"), encoding="utf-8") as attempt:
        response = attempt.read().strip()
    if "--print-response-path" in sys.argv:
        print(response)
    elif "--print-altool-version" in sys.argv:
        print("26.40.1 (174001)")
elif command == "capture-response":
    descriptor = os.open(option("--output"), os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(descriptor, "wb") as output:
        shutil.copyfileobj(sys.stdin.buffer, output)
        output.flush()
        os.fsync(output.fileno())
elif command == "cleanup-upload-attempt":
    for name in ("--response", "--attempt"):
        os.unlink(option(name))
elif command == "record-upload":
    failure_marker = os.environ.get("EASYSPLAT_TEST_UPLOAD_RECEIPT_FAILURE_MARKER")
    if failure_marker and not os.path.exists(failure_marker):
        with open(failure_marker, "x", encoding="utf-8") as marker:
            marker.write("failed once\\n")
        raise SystemExit(23)
    path = option("--output")
    descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(descriptor, "wb") as output:
        output.write(b"{}\\n")
elif command == "record-processing":
    path = option("--output")
    descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(descriptor, "wb") as output:
        output.write(b"{}\\n")
elif command == "verify-upload" and "--print-delivery-id" in sys.argv:
    print("be9c5d83-4150-40cb-91a1-739cf69a6f35")
elif command == "run-bound-command":
    separator = sys.argv.index("--")
    raise SystemExit(subprocess.run(sys.argv[separator + 1 :], check=False).returncode)
""",
            encoding="utf-8",
        )
        fake_evidence.chmod(0o700)

        harness_source = SCRIPT.read_text(encoding="utf-8")
        harness_source = harness_source.replace(
            "XCRUN=/usr/bin/xcrun", f"XCRUN={shlex.quote(str(fake_altool))}"
        )
        harness_source = harness_source.replace(
            "/usr/sbin/pkgutil", shlex.quote(str(fake_pkgutil))
        )
        harness_source = harness_source.replace(
            '"$ROOT/scripts/release/mas_release_evidence.py"',
            shlex.quote(str(fake_evidence)),
        )
        harness_source = harness_source.replace(
            '"$ROOT/scripts/release/run_bound_package_command.py"',
            f"{shlex.quote(str(fake_evidence))} run-bound-command",
        )
        harness = directory / "upload-mas-package.sh"
        harness.write_text(harness_source, encoding="utf-8")
        harness.chmod(0o700)
        environment = dict(os.environ)
        environment.update(
            {
                "HOME": str(home),
                "EASYSPLAT_TEST_ALTOOL_LOG": str(altool_log),
                "EASYSPLAT_TEST_STATUS_COUNTER": str(status_counter),
                "EASYSPLAT_TEST_CLEANUP_FAILS": "1" if cleanup_fails else "0",
                "EASYSPLAT_TEST_UPLOAD_RECEIPT_FAILURE_MARKER": (
                    str(directory / "upload-receipt-failed-once")
                    if first_upload_receipt_fails
                    else ""
                ),
            }
        )
        return harness, environment, altool_log

    def test_script_is_executable(self) -> None:
        self.assertTrue(os.access(SCRIPT, os.X_OK))

    def test_usage_requires_every_input(self) -> None:
        result = self.run_script()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Usage: upload_mas_package.sh", result.stderr)

    def test_evidence_defaults_to_the_canonical_package_sibling(self) -> None:
        with tempfile.TemporaryDirectory() as scratch:
            directory = Path(scratch).resolve()
            isolated_home = directory / "isolated-home"
            isolated_home.mkdir()
            result = self.run_script(
                "--package", str(self.package(directory)),
                "--key-id", KEY_ID,
                "--issuer-id", ISSUER_ID,
                "--validate",
                home=isolated_home,
                include_default_evidence=False,
            )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn(f"AuthKey_{KEY_ID}.p8 is not in", result.stderr)
        self.assertNotIn("--evidence", result.stderr)

    def test_unknown_option_is_rejected(self) -> None:
        result = self.run_script("--dry-run")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Unknown arg", result.stderr)

    def test_exactly_one_action_is_allowed(self) -> None:
        with tempfile.TemporaryDirectory() as scratch:
            # macOS hands back /var/folders, which is a symlink to /private/var,
            # and the submitter refuses symlinked ancestry by design.
            directory = Path(scratch).resolve()
            result = self.run_script(
                "--package", str(self.package(directory)),
                "--key-id", KEY_ID,
                "--issuer-id", ISSUER_ID,
                "--validate",
                "--upload",
            )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("exactly one of --validate or --upload", result.stderr)

    def test_upload_requires_exact_app_identity_for_status_polling(self) -> None:
        with tempfile.TemporaryDirectory() as scratch:
            directory = Path(scratch).resolve()
            package = str(self.package(directory))
            missing = self.run_script(
                "--package", package,
                "--key-id", KEY_ID,
                "--issuer-id", ISSUER_ID,
                "--upload",
            )
            malformed = self.run_script(
                "--package", package,
                "--key-id", KEY_ID,
                "--issuer-id", ISSUER_ID,
                "--apple-id", "not-an-id",
                "--bundle-short-version", APP_VERSION,
                "--bundle-version", APP_BUILD,
                "--upload",
            )
        self.assertIn("--apple-id", missing.stderr)
        self.assertIn("positive decimal", malformed.stderr)

    def test_upload_is_idempotent_and_records_terminal_processing(self) -> None:
        with tempfile.TemporaryDirectory() as scratch:
            directory = Path(scratch).resolve()
            package = self.package(directory)
            evidence = directory / "EasySplat.pkg.provenance.json"
            evidence.write_text("{}\n", encoding="utf-8")
            harness, environment, altool_log = self.submission_harness(directory)
            command = [
                str(harness),
                "--package", str(package),
                "--evidence", str(evidence),
                "--key-id", KEY_ID,
                "--issuer-id", ISSUER_ID,
                "--apple-id", APPLE_ID,
                "--bundle-short-version", APP_VERSION,
                "--bundle-version", APP_BUILD,
                "--upload",
            ]
            first = subprocess.run(command, capture_output=True, text=True, env=environment)
            second = subprocess.run(command, capture_output=True, text=True, env=environment)

            self.assertEqual(first.returncode, 0, first.stderr)
            self.assertEqual(second.returncode, 0, second.stderr)
            self.assertNotIn("retained", first.stderr)
            self.assertTrue(Path(f"{package}.upload.json").is_file())
            self.assertTrue(Path(f"{package}.processing.json").is_file())
            calls = altool_log.read_text(encoding="utf-8")
            self.assertEqual(calls.count("--upload-app"), 1)
            self.assertEqual(calls.count("--build-status"), 1)
            self.assertIn(
                "--delivery-id\x00be9c5d83-4150-40cb-91a1-739cf69a6f35",
                calls,
            )
            self.assertIn("already has verified terminal processing evidence", second.stdout)

    def test_failed_status_resumes_without_uploading_twice(self) -> None:
        with tempfile.TemporaryDirectory() as scratch:
            directory = Path(scratch).resolve()
            package = self.package(directory)
            evidence = directory / "EasySplat.pkg.provenance.json"
            evidence.write_text("{}\n", encoding="utf-8")
            harness, environment, altool_log = self.submission_harness(
                directory, first_status_fails=True
            )
            command = [
                str(harness),
                "--package", str(package),
                "--evidence", str(evidence),
                "--key-id", KEY_ID,
                "--issuer-id", ISSUER_ID,
                "--apple-id", APPLE_ID,
                "--bundle-short-version", APP_VERSION,
                "--bundle-version", APP_BUILD,
                "--upload",
            ]
            first = subprocess.run(command, capture_output=True, text=True, env=environment)
            second = subprocess.run(command, capture_output=True, text=True, env=environment)

            self.assertEqual(first.returncode, 17, first.stderr)
            self.assertEqual(second.returncode, 0, second.stderr)
            calls = altool_log.read_text(encoding="utf-8")
            self.assertEqual(calls.count("--upload-app"), 1)
            self.assertEqual(calls.count("--build-status"), 2)
            self.assertIn("Resuming App Store processing status", second.stdout)

    def test_accepted_upload_recovers_its_pending_response_without_reuploading(self) -> None:
        with tempfile.TemporaryDirectory() as scratch:
            directory = Path(scratch).resolve()
            package = self.package(directory)
            evidence = directory / "EasySplat.pkg.provenance.json"
            evidence.write_text("{}\n", encoding="utf-8")
            harness, environment, altool_log = self.submission_harness(
                directory, first_upload_receipt_fails=True
            )
            command = [
                str(harness),
                "--package", str(package),
                "--evidence", str(evidence),
                "--key-id", KEY_ID,
                "--issuer-id", ISSUER_ID,
                "--apple-id", APPLE_ID,
                "--bundle-short-version", APP_VERSION,
                "--bundle-version", APP_BUILD,
                "--upload",
            ]

            first = subprocess.run(command, capture_output=True, text=True, env=environment)
            second = subprocess.run(command, capture_output=True, text=True, env=environment)

            self.assertEqual(first.returncode, 23, first.stderr)
            self.assertEqual(second.returncode, 0, second.stderr)
            calls = altool_log.read_text(encoding="utf-8")
            self.assertEqual(calls.count("--upload-app"), 1)
            self.assertEqual(calls.count("--build-status"), 1)
            self.assertIn("Recovering the accepted upload", second.stdout)

    def test_cleanup_refusal_does_not_erase_a_committed_submission(self) -> None:
        with tempfile.TemporaryDirectory() as scratch:
            directory = Path(scratch).resolve()
            package = self.package(directory)
            evidence = directory / "EasySplat.pkg.provenance.json"
            evidence.write_text("{}\n", encoding="utf-8")
            harness, environment, _ = self.submission_harness(
                directory, cleanup_fails=True
            )
            result = subprocess.run(
                [
                    str(harness),
                    "--package", str(package),
                    "--evidence", str(evidence),
                    "--key-id", KEY_ID,
                    "--issuer-id", ISSUER_ID,
                    "--apple-id", APPLE_ID,
                    "--bundle-short-version", APP_VERSION,
                    "--bundle-version", APP_BUILD,
                    "--upload",
                ],
                capture_output=True,
                text=True,
                env=environment,
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn("retained because cleanup identity was uncertain", result.stderr)

    def test_key_and_issuer_shapes_are_enforced(self) -> None:
        with tempfile.TemporaryDirectory() as scratch:
            package = str(self.package(Path(scratch).resolve()))
            lowercase_key = self.run_script(
                "--package", package,
                "--key-id", "n5gx84dz8u",
                "--issuer-id", ISSUER_ID,
                "--validate",
            )
            uppercase_issuer = self.run_script(
                "--package", package,
                "--key-id", KEY_ID,
                "--issuer-id", ISSUER_ID.upper(),
                "--validate",
            )
        self.assertIn("10 uppercase letters or digits", lowercase_key.stderr)
        self.assertIn("lowercase UUID", uppercase_issuer.stderr)

    def test_command_override_is_refused(self) -> None:
        with tempfile.TemporaryDirectory() as scratch:
            # macOS hands back /var/folders, which is a symlink to /private/var,
            # and the submitter refuses symlinked ancestry by design.
            directory = Path(scratch).resolve()
            environment = dict(os.environ)
            environment["EASYSPLAT_ALTOOL_BIN"] = "/bin/echo"
            result = subprocess.run(
                [
                    str(SCRIPT),
                    "--package", str(self.package(directory)),
                    "--key-id", KEY_ID,
                    "--issuer-id", ISSUER_ID,
                    "--validate",
                    "--evidence", str(self.default_evidence),
                ],
                capture_output=True,
                text=True,
                env=environment,
            )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("overrides are not permitted", result.stderr)

    def test_package_must_be_an_ordinary_absolute_installer(self) -> None:
        with tempfile.TemporaryDirectory() as scratch:
            # macOS hands back /var/folders, which is a symlink to /private/var,
            # and the submitter refuses symlinked ancestry by design.
            directory = Path(scratch).resolve()
            home = self.key_home(directory / "home")
            archive = directory / "EasySplat.zip"
            archive.write_bytes(b"zip")
            wrong_suffix = self.run_script(
                "--package", str(archive),
                "--key-id", KEY_ID,
                "--issuer-id", ISSUER_ID,
                "--validate",
                home=home,
            )
            absent = self.run_script(
                "--package", str(directory / "absent.pkg"),
                "--key-id", KEY_ID,
                "--issuer-id", ISSUER_ID,
                "--validate",
                home=home,
            )
            linked = directory / "linked.pkg"
            linked.symlink_to(self.package(directory))
            symlinked = self.run_script(
                "--package", str(linked),
                "--key-id", KEY_ID,
                "--issuer-id", ISSUER_ID,
                "--validate",
                home=home,
            )
            relative = self.run_script(
                "--package", "EasySplat.pkg",
                "--key-id", KEY_ID,
                "--issuer-id", ISSUER_ID,
                "--validate",
                home=home,
            )
        self.assertIn("requires an installer package", wrong_suffix.stderr)
        self.assertIn("does not exist", absent.stderr)
        self.assertIn("symlink ancestry", symlinked.stderr)
        self.assertIn("absolute and normalized", relative.stderr)

    def test_missing_or_readable_key_stops_the_submission(self) -> None:
        with tempfile.TemporaryDirectory() as scratch:
            # macOS hands back /var/folders, which is a symlink to /private/var,
            # and the submitter refuses symlinked ancestry by design.
            directory = Path(scratch).resolve()
            package = str(self.package(directory))
            empty_home = directory / "empty-home"
            empty_home.mkdir()
            missing = self.run_script(
                "--package", package,
                "--key-id", KEY_ID,
                "--issuer-id", ISSUER_ID,
                "--validate",
                home=empty_home,
            )
            home = self.key_home(directory / "home")
            (home / f".appstoreconnect/private_keys/AuthKey_{KEY_ID}.p8").chmod(0o644)
            readable = self.run_script(
                "--package", package,
                "--key-id", KEY_ID,
                "--issuer-id", ISSUER_ID,
                "--validate",
                home=home,
            )
        self.assertIn(f"AuthKey_{KEY_ID}.p8 is not in", missing.stderr)
        self.assertIn("group- or world-readable", readable.stderr)

    def test_unsigned_package_never_reaches_app_store_connect(self) -> None:
        with tempfile.TemporaryDirectory() as scratch:
            # macOS hands back /var/folders, which is a symlink to /private/var,
            # and the submitter refuses symlinked ancestry by design.
            directory = Path(scratch).resolve()
            home = self.key_home(directory / "home")
            result = self.run_script(
                "--package", str(self.package(directory)),
                "--key-id", KEY_ID,
                "--issuer-id", ISSUER_ID,
                "--validate",
                home=home,
            )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("not signed", result.stderr)

    def test_evidence_gate_precedes_altool_and_never_reads_key_bytes(self) -> None:
        source = SCRIPT.read_text(encoding="utf-8")
        evidence_call = source.index('mas_release_evidence.py" verify \\\n')
        altool_call = source.index('"$XCRUN" altool --validate-app')
        self.assertLess(evidence_call, altool_call)
        key_check = source.split(
            '/usr/bin/python3 -I - "$PRIVATE_KEY_PATH" <<\'PY\'', 1
        )[1].split("\nPY\n", 1)[0]
        self.assertIn("os.lstat(path)", key_check)
        self.assertNotIn("open(path", key_check)
        self.assertNotIn("read_bytes", key_check)
        self.assertNotIn(".read(", key_check)

    def test_altool_receives_only_the_private_verified_snapshot(self) -> None:
        source = SCRIPT.read_text(encoding="utf-8")
        self.assertIn('EVIDENCE="$PACKAGE.provenance.json"', source)
        self.assertIn("snapshot-package", source)
        self.assertGreaterEqual(source.count("verify-snapshot"), 2)
        self.assertEqual(source.count('--file "$PACKAGE_SNAPSHOT"'), 2)
        self.assertNotIn('--file "$PACKAGE"', source)

    def test_altool_uses_the_exact_validated_key_path_when_home_contains_spaces(self) -> None:
        with tempfile.TemporaryDirectory() as scratch:
            directory = Path(scratch).resolve() / "release test with spaces"
            directory.mkdir()
            home = self.key_home(directory / "home with spaces")
            key = home / f".appstoreconnect/private_keys/AuthKey_{KEY_ID}.p8"
            package = self.package(directory)
            evidence = directory / "evidence.json"
            evidence.write_text("{}\n", encoding="utf-8")
            altool_arguments = directory / "altool arguments.txt"
            evidence_arguments = directory / "evidence arguments.txt"

            fake_altool = directory / "fake altool"
            fake_altool.write_text(
                "#!/bin/bash\n"
                "/usr/bin/printf '%s\\n' \"$@\" > \"$EASYSPLAT_TEST_ALTOOL_ARGS\"\n",
                encoding="utf-8",
            )
            fake_altool.chmod(0o700)

            fake_pkgutil = directory / "fake pkgutil"
            fake_pkgutil.write_text(
                "#!/bin/bash\n"
                "/usr/bin/printf '%s\\n' "
                "'Mac Installer Distribution: EasySplat Test'\n",
                encoding="utf-8",
            )
            fake_pkgutil.chmod(0o700)

            fake_evidence = directory / "fake evidence.py"
            fake_evidence.write_text(
                """#!/usr/bin/env python3
import os
import shutil
import sys


def option(name: str) -> str:
    return sys.argv[sys.argv.index(name) + 1]


with open(os.environ["EASYSPLAT_TEST_EVIDENCE_ARGS"], "a", encoding="utf-8") as log:
    log.write("\\0".join(sys.argv[1:]) + "\\n")

command = sys.argv[1]
if command == "snapshot-package":
    shutil.copyfile(option("--package"), option("--output"))
    print("test-snapshot-token")
elif command == "cleanup-snapshot":
    os.unlink(option("--snapshot"))
    os.rmdir(option("--root"))
""",
                encoding="utf-8",
            )
            fake_evidence.chmod(0o700)

            fake_bound = directory / "fake bound package command.py"
            fake_bound.write_text(
                """#!/usr/bin/env python3
import subprocess
import sys

separator = sys.argv.index("--")
raise SystemExit(subprocess.run(sys.argv[separator + 1 :], check=False).returncode)
""",
                encoding="utf-8",
            )
            fake_bound.chmod(0o700)

            harness_source = SCRIPT.read_text(encoding="utf-8")
            harness_source = harness_source.replace(
                "XCRUN=/usr/bin/xcrun",
                f"XCRUN={shlex.quote(str(fake_altool))}",
            )
            harness_source = harness_source.replace(
                "/usr/sbin/pkgutil",
                shlex.quote(str(fake_pkgutil)),
            )
            harness_source = harness_source.replace(
                '"$ROOT/scripts/release/mas_release_evidence.py"',
                shlex.quote(str(fake_evidence)),
            )
            harness_source = harness_source.replace(
                '"$ROOT/scripts/release/run_bound_package_command.py"',
                shlex.quote(str(fake_bound)),
            )
            harness = directory / "upload mas package.sh"
            harness.write_text(harness_source, encoding="utf-8")
            harness.chmod(0o700)

            environment = dict(os.environ)
            environment.update(
                {
                    "HOME": str(home),
                    "EASYSPLAT_TEST_ALTOOL_ARGS": str(altool_arguments),
                    "EASYSPLAT_TEST_EVIDENCE_ARGS": str(evidence_arguments),
                }
            )
            result = subprocess.run(
                [
                    str(harness),
                    "--package", str(package),
                    "--evidence", str(evidence),
                    "--key-id", KEY_ID,
                    "--issuer-id", ISSUER_ID,
                    "--validate",
                ],
                capture_output=True,
                text=True,
                env=environment,
            )

            self.assertEqual(result.returncode, 0, result.stderr)
            arguments = altool_arguments.read_text(encoding="utf-8").splitlines()
            self.assertIn("--p8-file-path", arguments)
            key_path_index = arguments.index("--p8-file-path")
            self.assertEqual(arguments[key_path_index + 1], str(key))
            self.assertNotIn("BEGIN PRIVATE KEY", "\n".join(arguments))
            helper_calls = evidence_arguments.read_text(encoding="utf-8")
            self.assertNotIn(str(key), helper_calls)
            self.assertNotIn(KEY_ID, helper_calls)
            self.assertNotIn(ISSUER_ID, helper_calls)

    def test_submission_never_reads_or_prints_private_key_bytes(self) -> None:
        source = SCRIPT.read_text(encoding="utf-8")
        self.assertIn("--apiKey", source)
        self.assertIn("--apiIssuer", source)
        self.assertIn("--p8-file-path", source)
        self.assertNotIn("--auth-string", source)
        self.assertNotIn("cat ", source)


if __name__ == "__main__":
    unittest.main(verbosity=2)
