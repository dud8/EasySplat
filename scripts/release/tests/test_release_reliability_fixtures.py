#!/usr/bin/env python3
"""Tests for the streaming release-reliability fixture and performance helper."""

from __future__ import annotations

import importlib.util
import inspect
import json
import os
import subprocess
import stat
import tempfile
import time
import unittest
from pathlib import Path
from unittest import mock


ROOT = Path(__file__).resolve().parents[3]
MODULE_PATH = ROOT / "scripts/ci/release_reliability_fixtures.py"


class ReleaseReliabilityFixtureTests(unittest.TestCase):
    def load_module(self):
        self.assertTrue(MODULE_PATH.is_file(), "release reliability fixture helper is missing")
        spec = importlib.util.spec_from_file_location(
            "release_reliability_fixtures", MODULE_PATH
        )
        self.assertIsNotNone(spec)
        self.assertIsNotNone(spec.loader)
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        return module

    def test_generate_and_verify_are_deterministic_and_streaming_shaped(self) -> None:
        module = self.load_module()
        self.assertEqual(module.DEFAULT_ENTRY_COUNT, 10_000)
        self.assertEqual(module.DEFAULT_PLY_MIB, 139.6)
        with tempfile.TemporaryDirectory() as scratch:
            parent = Path(scratch).resolve()
            first = parent / "first"
            second = parent / "second"
            first_manifest = module.generate_fixtures(
                first, entry_count=7, target_ply_mib=0.05
            )
            second_manifest = module.generate_fixtures(
                second, entry_count=7, target_ply_mib=0.05
            )

            self.assertEqual(first_manifest, second_manifest)
            self.assertEqual(module.verify_fixtures(first), first_manifest)
            self.assertEqual(first_manifest["folder"]["fileCount"], 7)
            folder_payloads = {
                path.read_bytes() for path in (first / "folder").glob("*.jpg")
            }
            self.assertEqual(len(folder_payloads), 7)
            self.assertEqual(first_manifest["zip"]["entryCount"], 7)
            self.assertEqual(
                first_manifest["zip"]["uncompressedByteCount"],
                sum(len(module._photo_bytes(index)) for index in range(6))
                + first_manifest["ply"]["byteCount"],
            )
            self.assertEqual(
                first_manifest["zip"]["largeEntryPath"],
                "capture/reference-splat.ply",
            )
            self.assertEqual(
                first_manifest["zip"]["largeEntrySHA256"],
                first_manifest["ply"]["sha256"],
            )
            self.assertGreater(first_manifest["zip"]["compressedByteCount"], 0)
            self.assertEqual(first_manifest["ply"]["format"], "binary_little_endian")
            self.assertEqual(first_manifest["ply"]["recordBytes"], 248)
            self.assertGreater(first_manifest["ply"]["gaussianCount"], 0)
            self.assertEqual(first_manifest["ply"]["gaussianCount"] % 8, 0)
            self.assertEqual(first_manifest["ply"]["targetMiB"], 0.05)
            self.assertEqual(
                first_manifest["ply"]["sceneBounds"]["center"],
                {"x": 0.0, "y": 0.0, "z": 0.0},
            )
            self.assertAlmostEqual(
                first_manifest["ply"]["sceneBounds"]["radius"],
                3**0.5 + 3 * module.math.exp(-2.0),
                places=12,
            )
            with module.zipfile.ZipFile(first / "archive.zip") as archive:
                self.assertEqual(len(archive.infolist()), 7)
                self.assertEqual(
                    archive.infolist()[-1].filename,
                    "capture/reference-splat.ply",
                )
            manifest_path = first / "fixture-manifest.json"
            payload = json.loads(manifest_path.read_text(encoding="utf-8"))
            expected = (
                json.dumps(payload, sort_keys=True, separators=(",", ":")) + "\n"
            ).encode("utf-8")
            self.assertEqual(manifest_path.read_bytes(), expected)
            self.assertEqual(stat.S_IMODE(manifest_path.stat().st_mode), 0o600)

    def write_baseline(self, path: Path, module, names=("folder",)) -> None:
        payload = {
            "measurements": {
                name: {"peakRSSBytes": 512 * 1024 * 1024, "wallSeconds": 5.0}
                for name in names
            },
            "referenceHost": module.reference_host(),
            "schemaVersion": 1,
        }
        path.write_text(
            json.dumps(payload, sort_keys=True, separators=(",", ":")) + "\n",
            encoding="utf-8",
        )
        path.chmod(0o600)

    def test_measure_uses_time_l_and_enforces_the_exact_baseline_limits(self) -> None:
        module = self.load_module()
        module.enforce_baseline(
            {"peakRSSBytes": 65 * 1024 * 1024, "wallSeconds": 1.25},
            {"peakRSSBytes": 1024 * 1024, "wallSeconds": 1.0},
        )
        with self.assertRaisesRegex(module.FixtureError, "wall time"):
            module.enforce_baseline(
                {"peakRSSBytes": 1024 * 1024, "wallSeconds": 1.251},
                {"peakRSSBytes": 1024 * 1024, "wallSeconds": 1.0},
            )
        with self.assertRaisesRegex(module.FixtureError, "peak RSS"):
            module.enforce_baseline(
                {"peakRSSBytes": 65 * 1024 * 1024 + 1, "wallSeconds": 1.0},
                {"peakRSSBytes": 1024 * 1024, "wallSeconds": 1.0},
            )

        with tempfile.TemporaryDirectory() as scratch:
            parent = Path(scratch).resolve()
            fixtures = parent / "fixtures"
            module.generate_fixtures(fixtures, entry_count=3, target_ply_mib=0.02)
            baseline = parent / "baseline.json"
            self.write_baseline(baseline, module)
            output = parent / "measurement.json"
            consumer = parent / "easysplat-fixture-consumer"
            consumer.write_text(
                "#!/bin/sh\nexec /usr/bin/stat -f %z \"$1\"\n",
                encoding="utf-8",
            )
            consumer.chmod(0o700)
            with mock.patch.object(
                module,
                "_expand_command",
                return_value=[str(consumer), str(fixtures / "splat.ply")],
            ):
                result = module.measure_command(
                    root=fixtures,
                    baseline_path=baseline,
                    name="folder",
                    command=[str(consumer), "{ply}"],
                    output=output,
                )
            self.assertEqual(result["status"], "passed")
            self.assertEqual(result["name"], "folder")
            self.assertGreaterEqual(result["wallSeconds"], 0.0)
            self.assertGreater(result["peakRSSBytes"], 0)
            self.assertEqual(
                output.read_bytes(),
                (json.dumps(result, sort_keys=True, separators=(",", ":")) + "\n").encode(
                    "utf-8"
                ),
            )

    def test_temporary_run_preserves_siblings_and_removes_only_its_owned_root(self) -> None:
        module = self.load_module()
        with tempfile.TemporaryDirectory() as scratch:
            workspace = Path(scratch).resolve()
            sibling = workspace / "preserve.txt"
            sibling.write_text("preserve\n", encoding="utf-8")
            baseline = workspace / "baseline.json"
            self.write_baseline(baseline, module)
            consumer = self.make_fixture_consumer(workspace)
            with mock.patch.object(
                module,
                "_expand_command",
                side_effect=lambda root, command: [
                    str(consumer),
                    str(root / "splat.ply"),
                ],
            ):
                result = module.run_temporary_benchmark(
                    workspace=workspace,
                    baseline_path=baseline,
                    name="folder",
                    command=[str(consumer), "{ply}"],
                    entry_count=3,
                    target_ply_mib=0.02,
                )
            self.assertEqual(result["status"], "passed")
            self.assertEqual(sibling.read_text(encoding="utf-8"), "preserve\n")
            self.assertEqual(
                list(workspace.glob("easysplat-release-reliability-*")), []
            )

    def make_fixture_consumer(self, directory: Path) -> Path:
        consumer = directory / "easysplat-fixture-consumer"
        consumer.write_text(
            "#!/bin/sh\nexec /usr/bin/stat -f %z \"$1\"\n",
            encoding="utf-8",
        )
        consumer.chmod(0o700)
        return consumer

    def test_measure_refuses_placeholder_commands_that_are_not_easysplat_work(self) -> None:
        module = self.load_module()
        with tempfile.TemporaryDirectory() as scratch:
            parent = Path(scratch).resolve()
            fixtures = parent / "fixtures"
            module.generate_fixtures(fixtures, entry_count=2, target_ply_mib=0.01)
            baseline = parent / "baseline.json"
            self.write_baseline(baseline, module)
            wrapper = self.make_fixture_consumer(parent)
            for command in (
                ["/bin/test", "-f", "{ply}"],
                ["/usr/bin/true"],
                ["/usr/bin/stat", "-f", "%z", "{ply}"],
                [str(wrapper), "{ply}"],
            ):
                with self.subTest(command=command), self.assertRaisesRegex(
                    module.FixtureError, "real EasySplat entrypoint"
                ):
                    module.measure_command(
                        root=fixtures,
                        baseline_path=baseline,
                        name="folder",
                        command=command,
                    )

    def test_measure_rejects_byte_identical_fixture_identity_replacements(self) -> None:
        module = self.load_module()
        mutator_source = """\
from pathlib import Path
import sys

root = Path(sys.argv[1])
replacement = Path(sys.argv[2])
target = sys.argv[3]
if target == "root":
    root.rename(root.parent / "displaced-root")
    replacement.rename(root)
else:
    relative = {
        "folder": Path("folder"),
        "manifest": Path("fixture-manifest.json"),
        "zip": Path("archive.zip"),
        "ply": Path("splat.ply"),
        "folder-entry": Path("folder/frame-00000.jpg"),
    }[target]
    original = root / relative
    displaced = root.parent / f"displaced-{target}"
    original.rename(displaced)
    (replacement / relative).rename(original)
"""
        for target in (
            "root",
            "folder",
            "manifest",
            "zip",
            "ply",
            "folder-entry",
        ):
            with self.subTest(target=target), tempfile.TemporaryDirectory() as scratch:
                parent = Path(scratch).resolve()
                fixtures = parent / "fixtures"
                replacement = parent / "replacement"
                module.generate_fixtures(fixtures, entry_count=2, target_ply_mib=0.01)
                module.generate_fixtures(
                    replacement, entry_count=2, target_ply_mib=0.01
                )
                baseline = parent / "baseline.json"
                self.write_baseline(baseline, module)
                mutator = parent / "replace-fixture.py"
                mutator.write_text(mutator_source, encoding="utf-8")
                expanded = [
                    module.PYTHON,
                    str(mutator),
                    str(fixtures),
                    str(replacement),
                    target,
                ]
                with mock.patch.object(
                    module, "_expand_command", return_value=expanded
                ), self.assertRaisesRegex(module.FixtureError, "identity"):
                    module.measure_command(
                        root=fixtures,
                        baseline_path=baseline,
                        name="folder",
                        command=["ignored", "{ply}"],
                    )

    def test_measured_process_enforces_deadline_and_kills_stubborn_group(self) -> None:
        module = self.load_module()
        with tempfile.TemporaryDirectory() as scratch:
            parent = Path(scratch).resolve()
            heartbeat = parent / "heartbeat"
            process_group = parent / "process-group"
            worker = parent / "stubborn-worker.py"
            worker.write_text(
                """\
import os
from pathlib import Path
import signal
import subprocess
import sys
import time

heartbeat = Path(sys.argv[1])
process_group = Path(sys.argv[2])
child = subprocess.Popen([
    sys.executable,
    "-c",
    "import signal,sys,time; signal.signal(signal.SIGTERM, signal.SIG_IGN); "
    "output=open(sys.argv[1], 'ab', buffering=0); "
    "[(output.write(b'x'), time.sleep(0.01)) for _ in range(1000)]",
    str(heartbeat),
])
signal.signal(signal.SIGTERM, signal.SIG_IGN)
process_group.write_text(str(os.getpgrp()), encoding="utf-8")
while child.poll() is None:
    time.sleep(0.01)
""",
                encoding="utf-8",
            )
            started = time.monotonic()
            with mock.patch.object(
                module, "TERMINATE_GRACE_SECONDS", 0.05
            ), mock.patch.object(
                module, "KILL_GRACE_SECONDS", 0.2
            ), self.assertRaisesRegex(module.FixtureError, "wall deadline"):
                module._measure_process(
                    [module.PYTHON, str(worker), str(heartbeat), str(process_group)],
                    parent,
                    deadline_seconds=0.2,
                )
            self.assertLess(time.monotonic() - started, 1.5)
            self.assertTrue(process_group.is_file())
            self.assertTrue(heartbeat.is_file())
            size_after_gate = heartbeat.stat().st_size
            time.sleep(0.15)
            self.assertEqual(heartbeat.stat().st_size, size_after_gate)
            with self.assertRaises(ProcessLookupError):
                os.killpg(int(process_group.read_text(encoding="utf-8")), 0)

    def test_zip_verifier_uses_one_stable_descriptor_and_bounded_streaming(self) -> None:
        module = self.load_module()
        source = inspect.getsource(module._verify_zip)
        self.assertNotIn("bytearray", source)
        self.assertEqual(source.count("zipfile.ZipFile("), 1)
        with tempfile.TemporaryDirectory() as scratch:
            parent = Path(scratch).resolve()
            fixtures = parent / "fixtures"
            module.generate_fixtures(fixtures, entry_count=3, target_ply_mib=0.01)
            archive = fixtures / "archive.zip"
            displaced = fixtures / "original.zip"

            def replace_path() -> None:
                archive.rename(displaced)
                archive.write_bytes(b"foreign zip bytes\n")
                archive.chmod(0o600)

            with self.assertRaisesRegex(module.FixtureError, "changed|identity"):
                module._verify_zip(fixtures, 3, after_hash=replace_path)
            self.assertTrue(displaced.is_file())
            self.assertEqual(archive.read_bytes(), b"foreign zip bytes\n")

    def test_cleanup_refuses_a_child_swapped_to_an_external_symlink(self) -> None:
        module = self.load_module()
        with tempfile.TemporaryDirectory() as scratch:
            workspace = Path(scratch).resolve()
            root = workspace / f"{module.TEMPORARY_PREFIX}fixture"
            child = root / "child"
            child.mkdir(parents=True)
            (child / "owned.txt").write_text("owned\n", encoding="utf-8")
            external = workspace / "external"
            external.mkdir()
            sentinel = external / "preserve.txt"
            sentinel.write_text("preserve\n", encoding="utf-8")
            original = os.lstat(root)
            real_open = os.open
            swapped = False

            def swapping_open(path, flags, mode=0o777, *, dir_fd=None):
                nonlocal swapped
                if path == "child" and dir_fd is not None and not swapped:
                    swapped = True
                    child.rename(root / "displaced-child")
                    child.symlink_to(external, target_is_directory=True)
                return real_open(path, flags, mode, dir_fd=dir_fd)

            with mock.patch.object(module.os, "open", side_effect=swapping_open):
                with self.assertRaises(module.FixtureError):
                    module._remove_owned_temporary_root(root, workspace, original)

            self.assertTrue(swapped, "cleanup did not bind child traversal to a descriptor")
            self.assertEqual(sentinel.read_text(encoding="utf-8"), "preserve\n")

    def test_cleanup_retains_a_final_window_root_replacement(self) -> None:
        module = self.load_module()
        with tempfile.TemporaryDirectory() as scratch:
            workspace = Path(scratch).resolve()
            root = workspace / f"{module.TEMPORARY_PREFIX}fixture"
            root.mkdir(mode=0o700)
            original = os.lstat(root)
            replacement = workspace / "replacement"
            replacement.mkdir(mode=0o700)
            sentinel = replacement / "preserve.txt"
            sentinel.write_text("preserve\n", encoding="utf-8")
            displaced = workspace / "displaced"
            real_rename = os.rename
            swapped = False

            def swapping_rename(source, destination, *args, **kwargs):
                nonlocal swapped
                if not swapped and source == root.name:
                    swapped = True
                    real_rename(root, displaced)
                    real_rename(replacement, root)
                return real_rename(source, destination, *args, **kwargs)

            with mock.patch.object(module.os, "rename", side_effect=swapping_rename):
                with self.assertRaisesRegex(module.FixtureError, "retained|identity"):
                    module._remove_owned_temporary_root(root, workspace, original)
            self.assertTrue(swapped)
            retained = list(workspace.rglob("preserve.txt"))
            self.assertEqual(len(retained), 1)
            self.assertEqual(retained[0].read_text(encoding="utf-8"), "preserve\n")
            self.assertTrue(displaced.is_dir())

    def test_baseline_rejects_unknown_keys_symlinks_hardlinks_and_fifos(self) -> None:
        module = self.load_module()
        for unsafe_type in ("unknown", "symlink", "hardlink", "fifo"):
            with self.subTest(unsafe_type=unsafe_type), tempfile.TemporaryDirectory() as scratch:
                parent = Path(scratch).resolve()
                fixtures = parent / "fixtures"
                module.generate_fixtures(fixtures, entry_count=2, target_ply_mib=0.01)
                real = parent / "real-baseline.json"
                self.write_baseline(real, module)
                baseline = real
                if unsafe_type == "unknown":
                    payload = json.loads(real.read_text(encoding="utf-8"))
                    payload["unexpected"] = True
                    real.write_text(
                        json.dumps(payload, sort_keys=True, separators=(",", ":")) + "\n",
                        encoding="utf-8",
                    )
                else:
                    baseline = parent / "baseline.json"
                    if unsafe_type == "symlink":
                        baseline.symlink_to(real.name)
                    elif unsafe_type == "hardlink":
                        os.link(real, baseline)
                    else:
                        os.mkfifo(baseline)
                with self.assertRaises(module.FixtureError):
                    module.measure_command(
                        root=fixtures,
                        baseline_path=baseline,
                        name="folder",
                        command=["/usr/bin/true"],
                    )

    def test_cli_exposes_generate_verify_measure_and_run(self) -> None:
        result = subprocess.run(
            ["/usr/bin/python3", "-I", str(MODULE_PATH), "--help"],
            capture_output=True,
            text=True,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        for command in (
            "generate",
            "verify",
            "measure",
            "run",
            "full-gate",
            "product-gate",
        ):
            self.assertIn(command, result.stdout)
        for placeholder in ("{folder}", "{zip}", "{ply}"):
            self.assertIn(placeholder, result.stdout)
        self.assertIn("not product benchmarks", result.stdout)

    def test_product_gate_names_one_exact_xctest_for_each_required_workload(self) -> None:
        module = self.load_module()

        self.assertEqual(
            module.PRODUCT_WORKLOADS,
            (
                (
                    "folder-admission-10000",
                    "EasySplatAppTests.AppModelDatasetSelectionTests/"
                    "testReleaseReliabilityFolderAdmissionTraversesTenThousandRealFiles",
                ),
                (
                    "zip-extraction-10000",
                    "EasySplatCoreTests.SafeArchiveExtractorTests/"
                    "testReleaseReliabilityExtractsTenThousandEntryArchiveWithLargePayload",
                ),
                (
                    "ply-validation-139.6mib",
                    "EasySplatCoreTests.ProjectArtifactValidatorTests/"
                    "testReleaseReliabilityValidatesReferenceSizePlyWithExactEvidence",
                ),
                (
                    "ply-export-139.6mib",
                    "EasySplatAppTests.UserSelectedExportPublicationTests/"
                    "testReleaseReliabilityExportsReferenceSizePlyToAnAbsentDestination",
                ),
            ),
        )

    def test_product_workload_receipt_is_exact_and_cannot_be_reused(self) -> None:
        module = self.load_module()
        with tempfile.TemporaryDirectory() as scratch:
            root = Path(scratch).resolve()
            receipt = root / "receipt.json"
            workload = "folder-admission-10000"
            payload = {
                "schemaVersion": 1,
                "status": "passed",
                "wallSeconds": 0.25,
                "workload": workload,
            }
            receipt.write_bytes(module._canonical_json(payload))
            receipt.chmod(0o600)

            self.assertEqual(
                module._consume_product_workload_receipt(receipt, workload),
                0.25,
            )

            self.assertFalse(receipt.exists())
            with self.assertRaises(module.FixtureError):
                module._consume_product_workload_receipt(receipt, workload)

    def test_product_workload_receipt_rejects_invalid_operation_timing(self) -> None:
        module = self.load_module()
        for wall_seconds in (True, 0, -1, float("inf"), "0.25"):
            with self.subTest(wall_seconds=wall_seconds), tempfile.TemporaryDirectory() as scratch:
                receipt = Path(scratch).resolve() / "receipt.json"
                payload = {
                    "schemaVersion": 1,
                    "status": "passed",
                    "wallSeconds": wall_seconds,
                    "workload": "folder-admission-10000",
                }
                receipt.write_bytes(module._canonical_json(payload))
                receipt.chmod(0o600)
                with self.assertRaises(module.FixtureError):
                    module._consume_product_workload_receipt(
                        receipt,
                        "folder-admission-10000",
                    )

    def test_operation_timing_cannot_exceed_independent_process_timing(self) -> None:
        module = self.load_module()
        self.assertEqual(
            module._validated_product_measurement(
                operation_wall_seconds=0.5,
                process_measured={"peakRSSBytes": 100, "wallSeconds": 0.51},
            ),
            {"peakRSSBytes": 100, "wallSeconds": 0.5},
        )
        with self.assertRaisesRegex(module.FixtureError, "process wall time"):
            module._validated_product_measurement(
                operation_wall_seconds=1.0,
                process_measured={"peakRSSBytes": 100, "wallSeconds": 0.5},
            )

    def test_product_workload_rejects_success_without_its_test_receipt(self) -> None:
        module = self.load_module()
        with tempfile.TemporaryDirectory() as scratch:
            root = Path(scratch).resolve()
            fixtures = root / "fixtures"
            output = root / "output"
            output.mkdir(mode=0o700)
            module.generate_fixtures(fixtures, entry_count=2, target_ply_mib=0.01)
            baseline = root / "baseline.json"
            self.write_baseline(
                baseline,
                module,
                names=("folder-admission-10000",),
            )
            test_binary = root / "EasySplatPackageTests"
            test_binary.write_bytes(b"not executed")
            test_binary.chmod(0o700)
            completed = subprocess.CompletedProcess([], 0, b"", b"")
            captured: dict[str, object] = {}

            def successful_process(arguments, **kwargs):
                captured["arguments"] = arguments
                captured["environment"] = kwargs["environment"]
                return completed

            with mock.patch.dict(
                os.environ,
                {"GITHUB_TOKEN": "must-not-reach-xctest"},
            ), mock.patch.object(
                module,
                "_validate_product_test_binary",
                return_value=os.lstat(test_binary),
            ), mock.patch.object(
                module,
                "_run_with_wall_deadline",
                side_effect=successful_process,
            ), self.assertRaisesRegex(module.FixtureError, "receipt"):
                module._measure_product_workload(
                    fixture_root=fixtures,
                    output_root=output,
                    baseline_path=baseline,
                    name="folder-admission-10000",
                    test_specifier=module.PRODUCT_WORKLOADS[0][1],
                    test_binary=test_binary,
                )
            self.assertNotIn("GITHUB_TOKEN", captured["environment"])
            self.assertEqual(
                captured["arguments"][-5:],
                [
                    module.XCRUN,
                    "xctest",
                    "-XCTest",
                    module.PRODUCT_WORKLOADS[0][1],
                    str(test_binary.parent.parent.parent),
                ],
            )

    def test_product_workload_enforces_operation_timing_not_xctest_startup(self) -> None:
        module = self.load_module()
        with tempfile.TemporaryDirectory() as scratch:
            root = Path(scratch).resolve()
            fixtures = root / "fixtures"
            output = root / "output"
            output.mkdir(mode=0o700)
            module.generate_fixtures(fixtures, entry_count=2, target_ply_mib=0.01)
            baseline = root / "baseline.json"
            self.write_baseline(
                baseline,
                module,
                names=("folder-admission-10000",),
            )
            test_binary = root / "EasySplatPackageTests"
            test_binary.write_bytes(b"not executed")
            test_binary.chmod(0o700)

            def successful_process(arguments, **_kwargs):
                timing = Path(arguments[arguments.index("-o") + 1])
                timing.write_text(
                    "        9.99 real\n"
                    "        100 maximum resident set size\n",
                    encoding="utf-8",
                )
                receipt = output / "receipt.json"
                receipt.write_bytes(
                    module._canonical_json(
                        {
                            "schemaVersion": 1,
                            "status": "passed",
                            "wallSeconds": 0.5,
                            "workload": "folder-admission-10000",
                        }
                    )
                )
                receipt.chmod(0o600)
                return subprocess.CompletedProcess(arguments, 0, b"", b"")

            with mock.patch.object(
                module,
                "_validate_product_test_binary",
                return_value=os.lstat(test_binary),
            ), mock.patch.object(
                module,
                "_run_with_wall_deadline",
                side_effect=successful_process,
            ):
                result = module._measure_product_workload(
                    fixture_root=fixtures,
                    output_root=output,
                    baseline_path=baseline,
                    name="folder-admission-10000",
                    test_specifier=module.PRODUCT_WORKLOADS[0][1],
                    test_binary=test_binary,
                )

            self.assertEqual(result["wallSeconds"], 0.5)
            self.assertEqual(result["processWallSeconds"], 9.99)
            self.assertEqual(result["peakRSSBytes"], 100)

    def test_repository_product_gate_uses_optimized_xctest_and_host_baseline(self) -> None:
        module = self.load_module()
        gate = ROOT / "scripts/ci/run_release_reliability_product_gate.sh"
        baseline = ROOT / "scripts/ci/release_reliability_m4_max_baseline.json"
        source = gate.read_text(encoding="utf-8")

        for token in (
            "swift build -c release",
            "-Xswiftc -DDEBUG",
            "-Xswiftc -enable-testing",
            "--build-tests",
            "--disable-swift-testing",
            "--enable-xctest",
            "release_reliability_fixtures.py\" product-gate",
            "release_reliability_m4_max_baseline.json",
        ):
            self.assertIn(token, source)
        self.assertNotIn("--skip-build", source)
        self.assertNotIn("GITHUB_TOKEN", source)
        self.assertNotIn("GH_TOKEN", source)
        self.assertEqual(
            module.PRODUCT_REQUIRED_CHECKS,
            (
                (
                    "cooperative-cancellation-under-two-seconds",
                    "EasySplatCoreTests.SubprocessRunnerAsyncTests/"
                    "testRunAsyncReportsTerminationBeforeRethrowingCancellation",
                    2.0,
                ),
                (
                    "passive-share-cleanup-under-one-second",
                    "EasySplatAppTests.ResultWorkspaceTests/"
                    "testPickerCloseQueuesPassiveCancellationUntilTheNextMainActorTurn",
                    1.0,
                ),
            ),
        )
        payload = json.loads(baseline.read_text(encoding="utf-8"))
        self.assertEqual(payload["schemaVersion"], 1)
        self.assertEqual(payload["referenceHost"]["hardwareModel"], "Mac16,5")
        self.assertEqual(
            set(payload["measurements"]),
            {name for name, _ in module.PRODUCT_WORKLOADS},
        )
        for selected in payload["measurements"].values():
            self.assertGreater(selected["wallSeconds"], 0)
            self.assertGreater(selected["peakRSSBytes"], 0)

    def test_required_timing_check_runs_one_exact_test_with_sanitized_environment(self) -> None:
        module = self.load_module()
        with tempfile.TemporaryDirectory() as scratch:
            root = Path(scratch).resolve()
            test_binary = root / "EasySplatPackageTests"
            test_binary.write_bytes(b"not executed")
            test_binary.chmod(0o700)
            output_root = root / "required-check"
            output_root.mkdir(mode=0o700)
            name, test_specifier, limit_seconds = module.PRODUCT_REQUIRED_CHECKS[0]
            test_case = module._xctest_case_name(test_specifier)
            output = (
                f"Test Case '-[{test_case}]' passed (0.1 seconds).\n"
                "Executed 1 test, with 0 failures (0 unexpected) in 0.1 seconds\n"
            ).encode()
            captured: dict[str, object] = {}

            def successful_process(arguments, **kwargs):
                captured["arguments"] = arguments
                captured["environment"] = kwargs["environment"]
                receipt = Path(kwargs["environment"][module.PRODUCT_RECEIPT_KEY])
                receipt.write_bytes(
                    module._canonical_json(
                        {
                            "schemaVersion": 1,
                            "status": "passed",
                            "wallSeconds": 0.2,
                            "workload": name,
                        }
                    )
                )
                receipt.chmod(0o600)
                return subprocess.CompletedProcess(arguments, 0, output, b"")

            with mock.patch.dict(
                os.environ,
                {"GITHUB_TOKEN": "must-not-reach-xctest"},
            ), mock.patch.object(
                module,
                "_validate_product_test_binary",
                return_value=os.lstat(test_binary),
            ), mock.patch.object(
                module,
                "_run_with_wall_deadline",
                side_effect=successful_process,
            ):
                result = module._run_product_required_check(
                    name=name,
                    test_specifier=test_specifier,
                    test_binary=test_binary,
                    output_root=output_root,
                    limit_seconds=limit_seconds,
                )

            self.assertEqual(result["status"], "passed")
            self.assertEqual(result["wallSeconds"], 0.2)
            self.assertEqual(result["limitSeconds"], 2.0)
            self.assertNotIn("GITHUB_TOKEN", captured["environment"])
            self.assertEqual(
                captured["environment"][module.PRODUCT_TIMING_KEY],
                "1",
            )
            self.assertEqual(captured["environment"][module.PRODUCT_WORKLOAD_KEY], name)
            self.assertEqual(
                captured["environment"][module.PRODUCT_RECEIPT_KEY],
                str(output_root / "receipt.json"),
            )
            self.assertEqual(
                captured["arguments"],
                [
                    module.XCRUN,
                    "xctest",
                    "-XCTest",
                    test_specifier,
                    str(test_binary.parent.parent.parent),
                ],
            )

    def test_required_timing_check_rejects_zero_test_success(self) -> None:
        module = self.load_module()
        with tempfile.TemporaryDirectory() as scratch:
            root = Path(scratch).resolve()
            test_binary = root / "EasySplatPackageTests"
            test_binary.write_bytes(b"not executed")
            test_binary.chmod(0o700)
            output_root = root / "required-check"
            output_root.mkdir(mode=0o700)
            name, test_specifier, limit_seconds = module.PRODUCT_REQUIRED_CHECKS[0]
            completed = subprocess.CompletedProcess([], 0, b"Executed 0 tests\n", b"")
            with mock.patch.object(
                module,
                "_validate_product_test_binary",
                return_value=os.lstat(test_binary),
            ), mock.patch.object(
                module,
                "_run_with_wall_deadline",
                return_value=completed,
            ), self.assertRaisesRegex(module.FixtureError, "exact XCTest"):
                module._run_product_required_check(
                    name=name,
                    test_specifier=test_specifier,
                    test_binary=test_binary,
                    output_root=output_root,
                    limit_seconds=limit_seconds,
                )

    def test_required_timing_check_rejects_pass_without_a_measured_receipt(self) -> None:
        module = self.load_module()
        with tempfile.TemporaryDirectory() as scratch:
            root = Path(scratch).resolve()
            test_binary = root / "EasySplatPackageTests"
            test_binary.write_bytes(b"not executed")
            test_binary.chmod(0o700)
            output_root = root / "required-check"
            output_root.mkdir(mode=0o700)
            name, test_specifier, limit_seconds = module.PRODUCT_REQUIRED_CHECKS[0]
            test_case = module._xctest_case_name(test_specifier)
            output = (
                f"Test Case '-[{test_case}]' passed (0.1 seconds).\n"
                "Executed 1 test, with 0 failures (0 unexpected) in 0.1 seconds\n"
            ).encode()
            completed = subprocess.CompletedProcess([], 0, output, b"")
            with mock.patch.object(
                module,
                "_validate_product_test_binary",
                return_value=os.lstat(test_binary),
            ), mock.patch.object(
                module,
                "_run_with_wall_deadline",
                return_value=completed,
            ), self.assertRaisesRegex(module.FixtureError, "success receipt"):
                module._run_product_required_check(
                    name=name,
                    test_specifier=test_specifier,
                    test_binary=test_binary,
                    output_root=output_root,
                    limit_seconds=limit_seconds,
                )

    def test_required_timing_check_rejects_a_measured_budget_overrun(self) -> None:
        module = self.load_module()
        with tempfile.TemporaryDirectory() as scratch:
            root = Path(scratch).resolve()
            test_binary = root / "EasySplatPackageTests"
            test_binary.write_bytes(b"not executed")
            test_binary.chmod(0o700)
            output_root = root / "required-check"
            output_root.mkdir(mode=0o700)
            name, test_specifier, limit_seconds = module.PRODUCT_REQUIRED_CHECKS[0]
            test_case = module._xctest_case_name(test_specifier)
            output = (
                f"Test Case '-[{test_case}]' passed (2.5 seconds).\n"
                "Executed 1 test, with 0 failures (0 unexpected) in 2.5 seconds\n"
            ).encode()

            def successful_process(arguments, **kwargs):
                receipt = Path(kwargs["environment"][module.PRODUCT_RECEIPT_KEY])
                receipt.write_bytes(
                    module._canonical_json(
                        {
                            "schemaVersion": 1,
                            "status": "passed",
                            "wallSeconds": 2.5,
                            "workload": name,
                        }
                    )
                )
                receipt.chmod(0o600)
                return subprocess.CompletedProcess(arguments, 0, output, b"")

            with mock.patch.object(
                module,
                "_validate_product_test_binary",
                return_value=os.lstat(test_binary),
            ), mock.patch.object(
                module,
                "_run_with_wall_deadline",
                side_effect=successful_process,
            ), self.assertRaisesRegex(module.FixtureError, "release budget"):
                module._run_product_required_check(
                    name=name,
                    test_specifier=test_specifier,
                    test_binary=test_binary,
                    output_root=output_root,
                    limit_seconds=limit_seconds,
                )

    def test_swift_fixture_protocol_literals_match_the_python_harness(self) -> None:
        module = self.load_module()
        swift_sources = (
            ROOT / "EasySplatAppTests/ReleaseReliabilityFixtureSupport.swift",
            ROOT
            / "EasySplatCore/Tests/EasySplatCoreTests/ReleaseReliabilityFixtureSupport.swift",
        )
        for source_path in swift_sources:
            source = source_path.read_text(encoding="utf-8")
            for key in (
                module.PRODUCT_FIXTURE_ROOT_KEY,
                module.PRODUCT_OUTPUT_ROOT_KEY,
                module.PRODUCT_RECEIPT_KEY,
                module.PRODUCT_WORKLOAD_KEY,
                module.PRODUCT_TIMING_KEY,
            ):
                self.assertIn(f'"{key}"', source)
            for key in ("schemaVersion", "status", "wallSeconds", "workload"):
                self.assertIn(f'\\"{key}\\"', source)

    def test_full_gate_measures_generation_and_verification_and_cleans_exact_root(self) -> None:
        module = self.load_module()
        with tempfile.TemporaryDirectory() as scratch:
            workspace = Path(scratch).resolve()
            baseline = workspace / "baseline.json"
            self.write_baseline(
                baseline,
                module,
                names=("fixture-generate", "fixture-verify"),
            )
            payload = module.run_full_fixture_gate(
                workspace=workspace,
                baseline_path=baseline,
                entry_count=3,
                target_ply_mib=0.02,
            )
            self.assertEqual(payload["status"], "passed")
            self.assertEqual(
                sorted(payload["measurements"]),
                ["fixture-generate", "fixture-verify"],
            )
            self.assertEqual(
                list(workspace.glob(f"{module.TEMPORARY_PREFIX}*")), []
            )

        gate_source = (ROOT / "scripts/ci/test_release_scripts.sh").read_text(
            encoding="utf-8"
        )
        self.assertNotIn(
            'release_reliability_fixtures.py" full-gate',
            gate_source,
            "fixture creation and verification are not product performance gates",
        )


if __name__ == "__main__":
    unittest.main(verbosity=2)
