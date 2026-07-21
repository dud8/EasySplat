#!/usr/bin/env python3
"""Hostile contracts for the native COLMAP build supervisor."""

from __future__ import annotations

import importlib.util
import hashlib
import json
import os
import signal
import subprocess
import sys
import tempfile
import time
import unittest
from pathlib import Path
from unittest import mock


ROOT = Path(__file__).resolve().parents[3]
SUPERVISOR = ROOT / "scripts/toolchain/secure_colmap_build.py"
WRAPPER = ROOT / "scripts/toolchain/build_colmap.sh"
IMPLEMENTATION = ROOT / "scripts/toolchain/build_colmap_impl.sh"
RELEASE_TESTS = ROOT / "scripts/ci/test_release_scripts.sh"


def load_supervisor():
    spec = importlib.util.spec_from_file_location("secure_colmap_build", SUPERVISOR)
    assert spec is not None and spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


def wait_until(predicate, timeout: float = 5.0) -> bool:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if predicate():
            return True
        time.sleep(0.02)
    return predicate()


class SourceContractTests(unittest.TestCase):
    def test_mandatory_release_gate_runs_the_supervisor_suite(self) -> None:
        script = RELEASE_TESTS.read_text(encoding="utf-8")
        self.assertIn(
            '/usr/bin/python3 -I "$ROOT/scripts/toolchain/tests/test_colmap_build_supervisor.py"',
            script,
        )

    def test_builder_runs_only_under_the_secure_supervisor(self) -> None:
        wrapper = WRAPPER.read_text(encoding="utf-8")
        implementation = IMPLEMENTATION.read_text(encoding="utf-8")
        self.assertTrue(SUPERVISOR.is_file(), SUPERVISOR)
        self.assertIn(
            'BUILD_SUPERVISOR="$SCRIPT_DIRECTORY/secure_colmap_build.py"', wrapper
        )
        self.assertIn('--control-input "$IMPLEMENTATION"', wrapper)
        self.assertIn('[ "$GUARDED_RUN" = "1" ]', implementation)
        self.assertNotIn('exec "$SELECTED_PYTHON" "$BUILD_SUPERVISOR"', implementation)
        self.assertNotIn('exec 9>"$BUILD_LOCK"', implementation)
        self.assertNotIn("/usr/bin/lockf -s -t 0 9", implementation)

    def test_source_and_build_are_unique_per_supervised_run(self) -> None:
        script = IMPLEMENTATION.read_text(encoding="utf-8")
        self.assertIn('SRC="./src"', script)
        self.assertIn('BUILD="./build"', script)
        prepare = script.split("prepare_source() {", 1)[1].split("\n}\n\n", 1)[0]
        self.assertNotIn('rm -rf "$SRC"', prepare)
        self.assertIn("source checkout path already exists", prepare)

    def test_guarded_build_root_is_bound_to_an_inherited_directory_descriptor(
        self,
    ) -> None:
        script = IMPLEMENTATION.read_text(encoding="utf-8")
        self.assertIn('GUARDED_STAGE_FD=""', script)
        self.assertIn('GUARDED_STAGE_FD="$3"', script)
        acquire = script.split("acquire_build_lock() {", 1)[1].split(
            "\n}\n\nrecover_stale_promotions()", 1
        )[0]
        self.assertIn('"$GUARDED_STAGE_FD"', acquire)
        self.assertIn("os.fstat(stage_descriptor)", acquire)
        self.assertIn('os.stat(".", follow_symlinks=False)', acquire)
        self.assertIn("await_promotion_approval", script)
        self.assertLess(
            script.rindex("await_promotion_approval"),
            script.rindex("promote_install"),
        )

    def test_guarded_helpers_bind_the_full_supervisor_process_chain(self) -> None:
        script = IMPLEMENTATION.read_text(encoding="utf-8")
        acquire = script.split("acquire_build_lock() {", 1)[1].split(
            "\n}\n\nawait_promotion_approval()", 1
        )[0]
        approval = script.split("await_promotion_approval() {", 1)[1].split(
            "\n}\n\nrecover_stale_promotions()", 1
        )[0]

        for helper in (acquire, approval):
            self.assertIn('[ "$PPID" = "$BUILD_SUPERVISOR_PID" ]', helper)
            self.assertIn("\"$$\" <<'PY'", helper)
            self.assertIn("implementation_pid", helper)
            self.assertIn("os.getppid() != implementation_pid", helper)
            self.assertIn("os.getpgrp() != implementation_pid", helper)
            self.assertIn("os.getsid(0) != implementation_pid", helper)
        self.assertNotIn(
            "if os.getppid() != int(supervisor_pid):",
            acquire + approval,
        )

    def test_guarded_child_does_not_delete_the_supervisor_owned_stage(self) -> None:
        script = IMPLEMENTATION.read_text(encoding="utf-8")
        cleanup = script.split("cleanup() {", 1)[1].split("\n}\ntrap cleanup", 1)[0]
        self.assertNotIn('"$INPUT_SNAPSHOT"', cleanup)
        self.assertNotIn('"$GUARDED_STAGE_DEVICE"', cleanup)
        self.assertNotIn('"$GUARDED_STAGE_INODE"', cleanup)
        supervisor = SUPERVISOR.read_text(encoding="utf-8")
        self.assertIn("_remove_owned_run_stage", supervisor)
        self.assertIn('"--remove-owned-tree"', supervisor)

    def test_receipt_uses_bound_input_digests_not_snapshot_pathnames(self) -> None:
        script = IMPLEMENTATION.read_text(encoding="utf-8")
        for digest in (
            "FROZEN_WRAPPER_SHA256",
            "FROZEN_IMPLEMENTATION_SHA256",
            "FROZEN_SUPERVISOR_SHA256",
            "FROZEN_PROMOTER_SHA256",
            "FROZEN_COLMAP_PATCH_SHA256",
            "FROZEN_RETRIEVER_HEADER_SHA256",
            "FROZEN_RETRIEVER_SOURCE_SHA256",
            "FROZEN_OVERLAY_SHA256",
        ):
            self.assertIn(digest, script)
        self.assertNotIn(
            '"build_supervisor_sha256": sha256(build_supervisor_path)', script
        )
        metadata = script.split("stage_metadata() {", 1)[1].split(
            "\n}\n\nvalidate_metadata()", 1
        )[0]
        self.assertNotIn("sha256(patch_path)", metadata)
        self.assertNotIn("Path(overlay_header_path).name", metadata)
        self.assertNotIn("Path(overlay_source_path).name", metadata)

    def test_builder_freezes_every_executed_control_script(self) -> None:
        wrapper = WRAPPER.read_text(encoding="utf-8")

        for path in ("$WRAPPER", "$IMPLEMENTATION", "$BUILD_SUPERVISOR", "$PROMOTER"):
            self.assertIn(f'--control-input "{path}"', wrapper)
        self.assertIn("EASYSPLAT_FROZEN_WRAPPER", wrapper)
        self.assertIn("EASYSPLAT_FROZEN_SUPERVISOR_FD", wrapper)
        self.assertIn("exec(compile(payload", wrapper)
        self.assertNotIn('"$BOOTSTRAP_PYTHON_BIN" "$BUILD_SUPERVISOR"', wrapper)

    def test_guarded_builder_executes_only_the_frozen_promoter(self) -> None:
        script = IMPLEMENTATION.read_text(encoding="utf-8")
        self.assertIn("FROZEN_PROMOTER_FD", script)
        self.assertIn("FROZEN_PROMOTER_SHA256", script)
        self.assertIn("FROZEN_PROMOTER_SIZE", script)
        self.assertIn("run_frozen_promoter", script)
        guarded_body = script.split('if [ "${1:-}" = "--guarded-run" ]; then', 1)[
            1
        ]
        for call in (
            '--create-owned-tree "$INSTALL"',
            '--recover "$journal"',
            '--tree-receipt',
            '"$INSTALL" "$LIVE_INSTALL" "$tree_receipt"',
            '--commit "$journal"',
        ):
            self.assertIn(call, guarded_body)
        self.assertNotIn('"$SELECTED_PYTHON" "$PROMOTER"', guarded_body)

    def test_receipt_uses_frozen_control_digests(self) -> None:
        script = IMPLEMENTATION.read_text(encoding="utf-8")
        for digest in (
            "FROZEN_WRAPPER_SHA256",
            "FROZEN_IMPLEMENTATION_SHA256",
            "FROZEN_SUPERVISOR_SHA256",
            "FROZEN_PROMOTER_SHA256",
        ):
            self.assertIn(digest, script)
        self.assertNotIn(
            '"builder_sha256": sha256(builder_path)',
            script,
        )
        self.assertNotIn(
            '"builder_implementation_sha256": sha256(builder_implementation_path)',
            script,
        )
        self.assertNotIn(
            '"build_supervisor_sha256": sha256(build_supervisor_path)',
            script,
        )
        self.assertNotIn(
            '"promoter_sha256": sha256(promoter_path)',
            script,
        )

    def test_process_group_is_never_signaled_after_reaping_its_leader(self) -> None:
        source = SUPERVISOR.read_text(encoding="utf-8")
        quiesce = source.split("def _quiesce_group(", 1)[1].split(
            "\n\ndef supervise(", 1
        )[0]
        supervise = source.split("def supervise(", 1)[1].split(
            "\n\ndef parse_arguments(", 1
        )[0]
        self.assertNotIn("leader.poll()", quiesce)
        self.assertNotIn("child.poll()", supervise)
        self.assertIn("KQ_NOTE_EXIT", supervise)
        self.assertLess(
            supervise.index("_quiesce_group("),
            supervise.index("child.wait("),
        )

        handler = supervise.split("def handle_signal(", 1)[1].split(
            "\n\n    for signum", 1
        )[0]
        self.assertNotIn("_signal_group", handler)
        self.assertIn("received_signal = signum", handler)
        self.assertLess(
            supervise.index("signal.signal(signum, handle_signal)"),
            supervise.index("_create_run_stage("),
        )
        loop = supervise.split("        while True:", 1)[1].split(
            "\n        _assert_run_stage_stable(", 1
        )[0]
        first_cancellation = loop.index("if received_signal is not None:")
        request_read = loop.index("request = os.read(")
        second_cancellation = loop.index(
            "if received_signal is not None:", first_cancellation + 1
        )
        approval = loop.index('os.write(approval_writer, b"A")')
        self.assertLess(first_cancellation, request_read)
        self.assertLess(request_read, second_cancellation)
        self.assertLess(second_cancellation, approval)
        approval_section = loop[loop.rindex("previous_mask = signal.pthread_sigmask") :]
        self.assertLess(
            approval_section.index("signal.SIG_BLOCK"),
            approval_section.index("if received_signal is not None:"),
        )
        self.assertLess(
            approval_section.index('os.write(approval_writer, b"A")'),
            approval_section.index("signal.SIG_SETMASK"),
        )

    def test_signal_and_exception_cleanup_cover_owned_stages(self) -> None:
        script = IMPLEMENTATION.read_text(encoding="utf-8")
        cleanup = script.split("cleanup() {", 1)[1].split("\n}\ntrap cleanup", 1)[0]
        self.assertIn("trap '' INT TERM HUP", cleanup)
        self.assertIn("trap 'exit 129' HUP", script)

        supervisor = SUPERVISOR.read_text(encoding="utf-8")
        supervise = supervisor.split("def supervise(", 1)[1].split(
            "\n\ndef parse_arguments", 1
        )[0]
        finalizer = supervise.split("    finally:", 1)[1]
        self.assertIn("not stage_removed", finalizer)
        self.assertIn("_remove_owned_run_stage(", finalizer)


@unittest.skipUnless(SUPERVISOR.is_file(), "supervisor implementation not present")
class SecureBoundaryTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.module = load_supervisor()

    def test_wrapper_executes_anonymous_supervisor_with_control_inputs(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            toolchain = root / "scripts/toolchain"
            overlay = root / "Tools/NativeColmap"
            tools = root / "bin"
            toolchain.mkdir(parents=True)
            overlay.mkdir(parents=True)
            tools.mkdir()
            wrapper = toolchain / "build_colmap.sh"
            wrapper.write_bytes(WRAPPER.read_bytes())
            wrapper.chmod(0o700)
            implementation = toolchain / "build_colmap_impl.sh"
            implementation.write_text("#!/bin/bash\nexit 7\n", encoding="utf-8")
            promoter = toolchain / "atomic_swap_install.py"
            promoter.write_text("raise SystemExit(8)\n", encoding="utf-8")
            patch = toolchain / "patches/colmap-4.1.1-easysplat.patch"
            patch.parent.mkdir()
            patch.write_text("reviewed patch\n", encoding="utf-8")
            (overlay / "local_vocab_retriever.h").write_text(
                "reviewed header\n", encoding="utf-8"
            )
            (overlay / "local_vocab_retriever.cc").write_text(
                "reviewed source\n", encoding="utf-8"
            )
            marker = root / "supervisor.json"
            supervisor = toolchain / "secure_colmap_build.py"
            supervisor.write_text(
                "\n".join(
                    (
                        "import fcntl, json, os, pathlib, sys",
                        f"pathlib.Path({str(marker)!r}).write_text(json.dumps({{",
                        "    'arguments': sys.argv[1:],",
                        "    'wrapper': os.environ.get('EASYSPLAT_EXECUTED_WRAPPER_SHA256'),",
                        "    'implementation': os.environ.get('EASYSPLAT_EXPECTED_IMPLEMENTATION_SHA256'),",
                        "    'supervisor': os.environ.get('EASYSPLAT_EXECUTED_SUPERVISOR_SHA256'),",
                        "    'promoter': os.environ.get('EASYSPLAT_EXPECTED_PROMOTER_SHA256'),",
                        "    'supervisor_access': fcntl.fcntl(int(os.environ['EASYSPLAT_FROZEN_SUPERVISOR_FD']), fcntl.F_GETFL) & os.O_ACCMODE,",
                        "}), encoding='utf-8')",
                    )
                )
                + "\n",
                encoding="utf-8",
            )
            for name in ("cmake", "git", "ninja", "rg"):
                executable = tools / name
                executable.write_text("#!/bin/bash\nexit 0\n", encoding="utf-8")
                executable.chmod(0o700)

            environment = os.environ.copy()
            environment["PATH"] = f"{tools}:{environment['PATH']}"
            result = subprocess.run(
                [str(wrapper)],
                check=False,
                capture_output=True,
                text=True,
                env=environment,
            )

            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            capture = json.loads(marker.read_text(encoding="utf-8"))
            self.assertEqual(
                capture["wrapper"], hashlib.sha256(wrapper.read_bytes()).hexdigest()
            )
            self.assertEqual(
                capture["supervisor"],
                hashlib.sha256(supervisor.read_bytes()).hexdigest(),
            )
            self.assertEqual(
                capture["implementation"],
                hashlib.sha256(implementation.read_bytes()).hexdigest(),
            )
            self.assertEqual(
                capture["promoter"],
                hashlib.sha256(promoter.read_bytes()).hexdigest(),
            )
            self.assertEqual(capture["supervisor_access"], os.O_RDONLY)
            arguments = capture["arguments"]
            self.assertEqual(arguments.count("--control-input"), 4)
            self.assertIn(str(wrapper.resolve()), arguments)
            self.assertIn(str(implementation.resolve()), arguments)
            self.assertIn(str(supervisor.resolve()), arguments)
            self.assertIn(str(promoter.resolve()), arguments)

            marker.unlink()
            wrapper.chmod(0o775)
            rejected = subprocess.run(
                [str(wrapper)],
                check=False,
                capture_output=True,
                text=True,
                env=environment,
            )
            self.assertNotEqual(rejected.returncode, 0)
            self.assertIn("unsafe native COLMAP wrapper", rejected.stderr)
            self.assertFalse(marker.exists())

    def test_signal_during_input_freeze_cleans_stage_without_spawning_child(
        self,
    ) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            work = root / "work"
            work.mkdir()
            sources = []
            for name in ("patch", "header", "source"):
                path = root / name
                path.write_text(f"{name}\n", encoding="utf-8")
                sources.append(path)
            child_marker = root / "child-ran"
            child = root / "child.sh"
            child.write_text(
                f"#!/bin/bash\ntouch {str(child_marker)!r}\n",
                encoding="utf-8",
            )
            child.chmod(0o700)

            freeze_inputs = self.module.freeze_inputs

            def interrupt_freeze(*arguments, **keywords):
                os.kill(os.getpid(), signal.SIGTERM)
                return freeze_inputs(*arguments, **keywords)

            with mock.patch.object(
                self.module,
                "freeze_inputs",
                side_effect=interrupt_freeze,
            ):
                return_code = self.module.supervise(
                    work=work,
                    lock_path=work / ".build.lock",
                    sources=sources,
                    command=(str(child),),
                    termination_grace=0.2,
                )

            self.assertEqual(return_code, 128 + signal.SIGTERM)
            self.assertFalse(child_marker.exists())
            self.assertEqual(list(work.glob("input.stage.*")), [])

    def test_control_path_replacement_cannot_change_executed_implementation(
        self,
    ) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            work = root / "work"
            work.mkdir()
            sources = []
            for name in ("patch", "header", "source"):
                path = root / name
                path.write_text(f"{name}\n", encoding="utf-8")
                sources.append(path)

            marker = root / "executed"
            wrapper = root / "build_colmap.sh"
            implementation = root / "build_colmap_impl.sh"
            supervisor = root / "secure_colmap_build.py"
            promoter = root / "atomic_swap_install.py"
            wrapper.write_text("wrapper\n", encoding="utf-8")
            implementation.write_text(
                "\n".join(
                    (
                        "#!/bin/bash",
                        '[ "$#" = "31" ] || exit 9',
                        '[ "${BASH_SOURCE[0]}" = "/dev/fd/${22}" ] || exit 10',
                        "/usr/bin/python3 -c 'import fcntl, os, sys; fd = int(sys.argv[1]); os.fstat(fd); assert (fcntl.fcntl(fd, fcntl.F_GETFL) & os.O_ACCMODE) == os.O_RDONLY' \"${22}\" || exit 11",
                        f"printf reviewed > {str(marker)!r}",
                    )
                )
                + "\n",
                encoding="utf-8",
            )
            supervisor.write_text("supervisor\n", encoding="utf-8")
            promoter.write_bytes(
                (ROOT / "scripts/toolchain/atomic_swap_install.py").read_bytes()
            )
            controls = (wrapper, implementation, supervisor, promoter)
            expected_controls = tuple(
                hashlib.sha256(path.read_bytes()).hexdigest() for path in controls
            )

            freeze_inputs = self.module.freeze_inputs
            call_count = 0

            def replace_after_control_freeze(*arguments, **keywords):
                nonlocal call_count
                frozen = freeze_inputs(*arguments, **keywords)
                call_count += 1
                if call_count == 2:
                    implementation.write_text(
                        f"#!/bin/bash\nprintf replacement > {str(marker)!r}\n",
                        encoding="utf-8",
                    )
                    promoter.write_text("raise SystemExit('replacement ran')\n")
                return frozen

            with mock.patch.object(
                self.module,
                "freeze_inputs",
                side_effect=replace_after_control_freeze,
            ):
                return_code = self.module.supervise(
                    work=work,
                    lock_path=work / ".build.lock",
                    sources=sources,
                    control_sources=controls,
                    expected_control_sha256=expected_controls,
                    command=(
                        "/usr/bin/env",
                        "-i",
                        "/bin/bash",
                        "--noprofile",
                        "--norc",
                        str(implementation),
                    ),
                    termination_grace=0.2,
                )

            self.assertEqual(return_code, 0)
            self.assertEqual(marker.read_text(encoding="utf-8"), "reviewed")
            self.assertEqual(list(work.glob("input.stage.*")), [])

    def test_executed_control_digest_mismatch_is_rejected_before_launch(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            work = root / "work"
            work.mkdir()
            sources = []
            for name in ("patch", "header", "source"):
                path = root / name
                path.write_text(f"{name}\n", encoding="utf-8")
                sources.append(path)
            controls = []
            for name in (
                "build_colmap.sh",
                "build_colmap_impl.sh",
                "secure_colmap_build.py",
            ):
                path = root / name
                path.write_text(f"{name}\n", encoding="utf-8")
                controls.append(path)
            promoter = root / "atomic_swap_install.py"
            promoter.write_bytes(
                (ROOT / "scripts/toolchain/atomic_swap_install.py").read_bytes()
            )
            controls.append(promoter)
            expected_controls = tuple(
                hashlib.sha256(path.read_bytes()).hexdigest() for path in controls
            )

            with self.assertRaisesRegex(
                self.module.SecurityError, "executed native build control changed"
            ):
                self.module.supervise(
                    work=work,
                    lock_path=work / ".build.lock",
                    sources=sources,
                    control_sources=controls,
                    expected_control_sha256=("0" * 64, *expected_controls[1:]),
                    command=(
                        "/usr/bin/env",
                        "-i",
                        "/bin/bash",
                        str(controls[1]),
                    ),
                    termination_grace=0.2,
                )

            self.assertEqual(list(work.glob("input.stage.*")), [])

    def run_promotion_signal_case(self, injection: str) -> tuple[int, bool, list[Path]]:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            work = root / "work"
            work.mkdir()
            sources = []
            for name in ("patch", "header", "source"):
                path = root / name
                path.write_text(f"{name}\n", encoding="utf-8")
                sources.append(path)

            approved = root / "approved"
            child = root / "request.py"
            child.write_text(
                "\n".join(
                    (
                        "#!/usr/bin/python3",
                        "import os, pathlib, sys",
                        "ready = int(sys.argv[7])",
                        "approval = int(sys.argv[8])",
                        "os.write(ready, b'R')",
                        "if os.read(approval, 2) == b'A':",
                        f"    pathlib.Path({str(approved)!r}).write_text('approved')",
                    )
                )
                + "\n",
                encoding="utf-8",
            )
            child.chmod(0o700)

            original_read = self.module.os.read
            original_write = self.module.os.write

            def interrupt_after_request(descriptor: int, size: int) -> bytes:
                payload = original_read(descriptor, size)
                if injection == "after-request" and payload == b"R":
                    os.kill(os.getpid(), signal.SIGTERM)
                return payload

            def delay_approval(descriptor: int, payload: bytes) -> int:
                if injection == "approval-write" and payload == b"A":
                    os.kill(os.getpid(), signal.SIGTERM)
                count = original_write(descriptor, payload)
                if payload == b"A":
                    time.sleep(0.2)
                return count

            with (
                mock.patch.object(
                    self.module.os,
                    "read",
                    side_effect=interrupt_after_request,
                ),
                mock.patch.object(
                    self.module.os,
                    "write",
                    side_effect=delay_approval,
                ),
            ):
                return_code = self.module.supervise(
                    work=work,
                    lock_path=work / ".build.lock",
                    sources=sources,
                    command=(str(child),),
                    termination_grace=0.2,
                )

            return return_code, approved.exists(), list(work.glob("input.stage.*"))

    def test_signal_after_promotion_request_never_approves_the_child(self) -> None:
        return_code, approved, stages = self.run_promotion_signal_case("after-request")
        self.assertEqual(return_code, 128 + signal.SIGTERM)
        self.assertFalse(approved)
        self.assertEqual(stages, [])

    def test_signal_at_the_masked_approval_write_is_post_commit(self) -> None:
        return_code, approved, stages = self.run_promotion_signal_case("approval-write")
        self.assertEqual(return_code, 128 + signal.SIGTERM)
        self.assertTrue(approved)
        self.assertEqual(stages, [])

    def test_post_reap_signal_is_recorded_without_signaling_the_old_group(
        self,
    ) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            work = root / "work"
            work.mkdir()
            sources = []
            for name in ("patch", "header", "source"):
                path = root / name
                path.write_text(f"{name}\n", encoding="utf-8")
                sources.append(path)

            forwarded: list[tuple[int, int]] = []
            remove_owned_stage = self.module._remove_owned_run_stage

            def interrupt_cleanup(*arguments) -> None:
                os.kill(os.getpid(), signal.SIGTERM)
                remove_owned_stage(*arguments)

            with (
                mock.patch.object(
                    self.module,
                    "_signal_group",
                    side_effect=lambda group, signum: forwarded.append((group, signum)),
                ),
                mock.patch.object(
                    self.module,
                    "_remove_owned_run_stage",
                    side_effect=interrupt_cleanup,
                ),
            ):
                return_code = self.module.supervise(
                    work=work,
                    lock_path=work / ".build.lock",
                    sources=sources,
                    command=("/usr/bin/true",),
                    termination_grace=0.2,
                )

            self.assertEqual(return_code, 128 + signal.SIGTERM)
            self.assertEqual(forwarded, [])
            self.assertEqual(list(work.glob("input.stage.*")), [])

    def test_exception_after_stage_creation_removes_the_owned_stage(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            work = root / "work"
            work.mkdir()
            sources = []
            for name in ("patch", "header"):
                path = root / name
                path.write_text(f"{name}\n", encoding="utf-8")
                sources.append(path)
            sources.append(root / "missing-source")

            with self.assertRaises(self.module.SecurityError):
                self.module.supervise(
                    work=work,
                    lock_path=work / ".build.lock",
                    sources=sources,
                    command=("/usr/bin/true",),
                    termination_grace=0.2,
                )

            self.assertEqual(list(work.glob("input.stage.*")), [])

    def test_hup_runs_the_real_install_stage_cleanup_contract(self) -> None:
        implementation = IMPLEMENTATION.read_text(encoding="utf-8")
        cleanup_function = (
            "cleanup() {"
            + implementation.split("cleanup() {", 1)[1].split(
                "\n}\n\ncreate_owned_install_stage()", 1
            )[0]
            + "\n}\n"
        )

        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            install = root / "install.stage.fixture"
            ready = root / "ready"
            sleeper = root / "sleeper-pid"
            fixture = root / "hup-cleanup.sh"
            fixture.write_text(
                "\n".join(
                    (
                        "#!/bin/bash",
                        "set -euo pipefail",
                        f"SELECTED_PYTHON={sys.executable!r}",
                        f"PROMOTER={str(ROOT / 'scripts/toolchain/atomic_swap_install.py')!r}",
                        f"INSTALL={str(install)!r}",
                        "LOCK_OWNED=0",
                        "STAGE_CLEANUP_ALLOWED=1",
                        "INSTALL_STAGE_OWNED=1",
                        'run_frozen_promoter() { "$SELECTED_PYTHON" "$PROMOTER" "$@"; }',
                        'identity="$("$SELECTED_PYTHON" "$PROMOTER" --create-owned-tree "$INSTALL")"',
                        'INSTALL_STAGE_DEVICE="${identity%%:*}"',
                        'INSTALL_STAGE_INODE="${identity#*:}"',
                        cleanup_function,
                        "trap cleanup EXIT",
                        "trap 'exit 130' INT",
                        "trap 'exit 143' TERM",
                        "trap 'exit 129' HUP",
                        "/bin/sleep 300 >/dev/null 2>&1 &",
                        f'printf "%s\\n" "$!" > {str(sleeper)!r}',
                        f"touch {str(ready)!r}",
                        "wait",
                    )
                )
                + "\n",
                encoding="utf-8",
            )
            fixture.chmod(0o700)

            process = subprocess.Popen(
                ["/bin/bash", str(fixture)],
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
            )
            sleeper_pid = 0
            try:
                self.assertTrue(wait_until(ready.is_file), "cleanup fixture not ready")
                sleeper_pid = int(sleeper.read_text(encoding="utf-8"))
                self.assertTrue(install.is_dir())
                os.kill(process.pid, signal.SIGHUP)
                stdout, stderr = process.communicate(timeout=5)
                self.assertEqual(
                    process.returncode, 128 + signal.SIGHUP, stdout + stderr
                )
                self.assertFalse(install.exists())
            finally:
                if process.poll() is None:
                    process.kill()
                    process.communicate(timeout=5)
                if sleeper_pid:
                    try:
                        os.kill(sleeper_pid, signal.SIGTERM)
                    except ProcessLookupError:
                        pass
                for stream in (process.stdout, process.stderr):
                    if stream is not None:
                        stream.close()

    def test_lock_rejects_symlink_and_hardlink_without_truncating_target(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            target = root / "target"
            target.write_bytes(b"must survive\n")

            symlink = root / "symlink.lock"
            symlink.symlink_to(target)
            with self.assertRaises(self.module.SecurityError):
                self.module.acquire_bound_lock(symlink)

            hardlink = root / "hardlink.lock"
            os.link(target, hardlink)
            with self.assertRaises(self.module.SecurityError):
                self.module.acquire_bound_lock(hardlink)

            self.assertEqual(target.read_bytes(), b"must survive\n")
            self.assertEqual(hardlink.read_bytes(), b"must survive\n")

    def test_owned_stage_cleanup_executes_under_selected_xcode_python(self) -> None:
        selected_python = subprocess.run(
            ["/usr/bin/xcrun", "--find", "python3"],
            check=True,
            capture_output=True,
            text=True,
        ).stdout.strip()
        probe = "\n".join(
            (
                "import importlib.util, os, pathlib, sys, tempfile",
                f"source = pathlib.Path({str(SUPERVISOR)!r})",
                "spec = importlib.util.spec_from_file_location('cleanup_probe', source)",
                "module = importlib.util.module_from_spec(spec)",
                "sys.modules[spec.name] = module",
                "spec.loader.exec_module(module)",
                "with tempfile.TemporaryDirectory(dir='/private/tmp') as temporary:",
                "    stage = pathlib.Path(temporary) / 'input.stage.probe'",
                "    stage.mkdir(mode=0o700)",
                "    (stage / 'payload').write_bytes(b'owned')",
                "    descriptor = os.open(stage, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)",
                "    metadata = os.fstat(descriptor)",
                "    module._remove_owned_run_stage(stage, descriptor, metadata.st_dev, metadata.st_ino)",
                "    assert not stage.exists()",
                "    os.close(descriptor)",
            )
        )

        result = subprocess.run(
            [selected_python, "-c", probe],
            check=False,
            capture_output=True,
            text=True,
        )

        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_lock_rejects_name_replacement_after_open(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            lock = root / "build.lock"
            lock.write_bytes(b"reusable\n")
            replacement = root / "replacement"
            replacement.write_bytes(b"replacement\n")

            def replace_name() -> None:
                moved = root / "opened.lock"
                lock.rename(moved)
                replacement.rename(lock)

            with self.assertRaises(self.module.SecurityError):
                self.module.acquire_bound_lock(lock, after_open=replace_name)
            self.assertEqual((root / "opened.lock").read_bytes(), b"reusable\n")
            self.assertEqual(lock.read_bytes(), b"replacement\n")

    def test_lock_blocks_absent_and_replacement_work_names(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            work = root / "work"
            work.mkdir()
            inputs = []
            arguments = []
            for name in ("patch", "header", "source"):
                path = root / name
                path.write_text(f"{name}\n", encoding="utf-8")
                inputs.append(path)
                arguments.extend(("--input", str(path)))

            held = self.module.acquire_bound_lock(work / ".build.lock")
            try:
                work.rename(root / "opened-work")
                contender_command = [
                    sys.executable,
                    str(SUPERVISOR),
                    "--work",
                    str(work),
                    "--lock",
                    str(work / ".build.lock"),
                    *arguments,
                    "--",
                    "/usr/bin/true",
                ]
                absent = subprocess.run(
                    contender_command,
                    check=False,
                    capture_output=True,
                    text=True,
                )
                self.assertEqual(absent.returncode, 75, absent.stderr)
                self.assertFalse(work.exists())

                work.mkdir()
                (work / ".build.lock").write_bytes(b"replacement work lock\n")
                replacement = subprocess.run(
                    contender_command,
                    check=False,
                    capture_output=True,
                    text=True,
                )
                self.assertEqual(replacement.returncode, 75, replacement.stderr)
            finally:
                held.close()

            reusable = subprocess.run(
                contender_command,
                check=False,
                capture_output=True,
                text=True,
            )
            self.assertEqual(reusable.returncode, 0, reusable.stderr)

    def test_frozen_input_rejects_symlink_and_hardlink_sources(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            stage = root / "stage"
            stage.mkdir(mode=0o700)
            target = root / "target"
            target.write_bytes(b"reviewed\n")
            symlink = root / "symlink"
            symlink.symlink_to(target)
            hardlink = root / "hardlink"
            os.link(target, hardlink)
            for source in (symlink, hardlink):
                with self.subTest(source=source.name):
                    with self.assertRaises(self.module.SecurityError):
                        self.module.freeze_inputs((source,), stage)

    def test_frozen_input_rejects_group_writable_source(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            stage = root / "stage"
            stage.mkdir(mode=0o700)
            source = root / "source"
            source.write_bytes(b"reviewed\n")
            source.chmod(0o660)

            with self.assertRaises(self.module.SecurityError):
                self.module.freeze_inputs((source,), stage)

    def test_frozen_inputs_survive_source_and_snapshot_name_swaps(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            stage = root / "stage"
            stage.mkdir(mode=0o700)
            sources = []
            payloads = []
            for index, name in enumerate(("patch", "header", "source")):
                path = root / name
                payload = f"reviewed-{index}\n".encode()
                path.write_bytes(payload)
                sources.append(path)
                payloads.append(payload)

            frozen = self.module.freeze_inputs(tuple(sources), stage)
            try:
                moved_stage = root / "moved-stage"
                stage.rename(moved_stage)
                stage.mkdir(mode=0o700)
                for path in sources:
                    path.write_bytes(b"later pathname generation\n")

                self.assertEqual(
                    tuple(self.module.read_frozen(item) for item in frozen),
                    tuple(payloads),
                )
                for item in frozen:
                    self.module.verify_frozen(item, item.sha256)
                    with self.assertRaises(self.module.SecurityError):
                        self.module.verify_frozen(item, "0" * 64)
                    with self.assertRaises(OSError):
                        os.pwrite(item.fd, b"x", 0)
                    self.assertEqual(os.fstat(item.fd).st_nlink, 0)
            finally:
                self.module.close_frozen_inputs(frozen)

    def test_frozen_input_preserves_every_large_source_byte(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            stage = root / "stage"
            stage.mkdir(mode=0o700)
            source = root / "source"
            payload = b"".join(
                bytes((index,)) * (1024 * 1024)
                for index in range(1, 5)
            )
            source.write_bytes(payload)

            frozen = self.module.freeze_inputs((source,), stage)
            try:
                self.assertEqual(self.module.read_frozen(frozen[0]), payload)
                self.module.verify_frozen(
                    frozen[0], hashlib.sha256(payload).hexdigest()
                )
            finally:
                self.module.close_frozen_inputs(frozen)

    def test_shell_freeze_gate_rejects_a_descriptor_digest_mismatch(self) -> None:
        script = IMPLEMENTATION.read_text(encoding="utf-8")
        function_body = script.split("freeze_native_inputs() {", 1)[1].split(
            "\n}\n\nsanitize_environment()", 1
        )[0]
        function = f"freeze_native_inputs() {{{function_body}\n}}"
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            stage = root / "stage"
            stage.mkdir(mode=0o700)
            sources = []
            for name in ("patch", "header", "source"):
                path = root / name
                path.write_text(f"{name}\n", encoding="utf-8")
                sources.append(path)
            frozen = self.module.freeze_inputs(tuple(sources), stage)
            try:
                payloads = tuple(self.module.read_frozen(item) for item in frozen)
                overlay = self.module._overlay_digest(payloads)

                def invoke(patch_sha256: str) -> subprocess.CompletedProcess[str]:
                    values = (
                        ("COLMAP_PATCH", frozen[0]),
                        ("RETRIEVER_HEADER", frozen[1]),
                        ("RETRIEVER_SOURCE", frozen[2]),
                    )
                    assignments = [f'SELECTED_PYTHON="{sys.executable}"']
                    for label, item in values:
                        assignments.extend(
                            (
                                f'FROZEN_{label}_FD="{item.fd}"',
                                f'FROZEN_{label}_SHA256="{item.sha256}"',
                                f'FROZEN_{label}_SIZE="{item.size}"',
                            )
                        )
                    assignments[2] = f'FROZEN_COLMAP_PATCH_SHA256="{patch_sha256}"'
                    assignments.append(f'FROZEN_OVERLAY_SHA256="{overlay}"')
                    harness = "\n".join(
                        (
                            "set -euo pipefail",
                            *assignments,
                            function,
                            "freeze_native_inputs",
                        )
                    )
                    return subprocess.run(
                        ["/bin/bash", "-c", harness],
                        check=False,
                        capture_output=True,
                        text=True,
                        pass_fds=tuple(item.fd for item in frozen),
                    )

                accepted = invoke(frozen[0].sha256)
                self.assertEqual(accepted.returncode, 0, accepted.stderr)
                rejected = invoke("0" * 64)
                self.assertNotEqual(rejected.returncode, 0)
                self.assertIn("digest mismatch", rejected.stderr)
            finally:
                self.module.close_frozen_inputs(frozen)

    def test_same_size_restored_mtime_replacement_during_freeze_is_rejected(
        self,
    ) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            stage = root / "stage"
            stage.mkdir(mode=0o700)
            source = root / "source"
            source.write_bytes(b"reviewed")
            original = source.stat()

            def replace_after_open(path: Path, index: int) -> None:
                self.assertEqual(index, 0)
                moved = path.with_suffix(".opened")
                path.rename(moved)
                path.write_bytes(b"hostile!")
                os.utime(path, ns=(original.st_atime_ns, original.st_mtime_ns))

            with self.assertRaises(self.module.SecurityError):
                self.module.freeze_inputs(
                    (source,), stage, after_source_open=replace_after_open
                )

    def test_supervised_child_receives_exact_read_only_frozen_descriptors(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            work = root / "work"
            work.mkdir()
            payloads = (b"patch\n", b"header\n", b"source\n")
            arguments = []
            for index, payload in enumerate(payloads):
                path = root / f"input-{index}"
                path.write_bytes(payload)
                arguments.extend(("--input", str(path)))
            capture = root / "capture.json"
            child = root / "inspect.py"
            child.write_text(
                "\n".join(
                    (
                        "#!/usr/bin/env python3",
                        "import hashlib, json, os, sys",
                        "assert len(sys.argv[1:]) == 18",
                        "captured = []",
                        "for index in (9, 12, 15):",
                        "    fd = int(sys.argv[index])",
                        "    expected = sys.argv[index + 1]",
                        "    size = int(sys.argv[index + 2])",
                        "    payload = os.pread(fd, size, 0)",
                        "    assert hashlib.sha256(payload).hexdigest() == expected",
                        "    try:",
                        "        os.pwrite(fd, b'x', 0)",
                        "    except OSError:",
                        "        pass",
                        "    else:",
                        "        raise AssertionError('frozen descriptor is writable')",
                        "    captured.append(payload.decode())",
                        "with open(os.environ['CAPTURE'], 'w', encoding='utf-8') as handle:",
                        "    json.dump(captured, handle)",
                    )
                )
                + "\n",
                encoding="utf-8",
            )
            child.chmod(0o755)
            environment = os.environ.copy()
            environment["CAPTURE"] = str(capture)
            result = subprocess.run(
                [
                    sys.executable,
                    str(SUPERVISOR),
                    "--work",
                    str(work),
                    "--lock",
                    str(work / ".build.lock"),
                    *arguments,
                    "--",
                    str(child),
                ],
                check=False,
                capture_output=True,
                text=True,
                env=environment,
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(
                json.loads(capture.read_text(encoding="utf-8")),
                [payload.decode() for payload in payloads],
            )

    def test_stage_name_swap_cannot_redirect_compile_or_receipt_outputs(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            work = root / "work"
            work.mkdir()
            arguments = []
            for name in ("patch", "header", "source"):
                path = root / name
                path.write_text(f"{name}\n", encoding="utf-8")
                arguments.extend(("--input", str(path)))

            ready = root / "ready"
            proceed = root / "proceed"
            child = root / "descriptor_root.py"
            child.write_text(
                "\n".join(
                    (
                        "#!/usr/bin/env python3",
                        "import hashlib, os, pathlib, sys, time",
                        "stage_path = pathlib.Path(sys.argv[2])",
                        "stage_fd = int(sys.argv[3])",
                        "pathlib.Path(os.environ['READY']).write_text(str(stage_path), encoding='utf-8')",
                        "deadline = time.monotonic() + 5",
                        "while not pathlib.Path(os.environ['PROCEED']).exists():",
                        "    if time.monotonic() >= deadline:",
                        "        raise SystemExit('timed out waiting for stage replacement')",
                        "    time.sleep(0.01)",
                        "cwd = os.stat('.', follow_symlinks=False)",
                        "bound = os.fstat(stage_fd)",
                        "assert (cwd.st_dev, cwd.st_ino) == (bound.st_dev, bound.st_ino)",
                        "source = pathlib.Path('src/unit.cc')",
                        "payload = source.read_bytes()",
                        "build = pathlib.Path('build')",
                        "build.mkdir()",
                        "(build / 'unit.o').write_bytes(payload)",
                        "(build / 'receipt.sha256').write_text(hashlib.sha256(payload).hexdigest() + '\\n', encoding='utf-8')",
                        "os.write(int(sys.argv[7]), b'R')",
                        "if os.read(int(sys.argv[8]), 1) != b'A':",
                        "    raise SystemExit('promotion was not approved')",
                        "pathlib.Path(os.environ['PROMOTED']).write_text('accepted\\n', encoding='utf-8')",
                    )
                )
                + "\n",
                encoding="utf-8",
            )
            child.chmod(0o755)
            environment = os.environ.copy()
            promoted = root / "promoted"
            environment.update(
                {
                    "READY": str(ready),
                    "PROCEED": str(proceed),
                    "PROMOTED": str(promoted),
                }
            )
            process = subprocess.Popen(
                [
                    sys.executable,
                    str(SUPERVISOR),
                    "--work",
                    str(work),
                    "--lock",
                    str(work / ".build.lock"),
                    *arguments,
                    "--",
                    str(child),
                ],
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
                env=environment,
            )
            try:
                self.assertTrue(
                    wait_until(ready.is_file), "fake build never became ready"
                )
                stage = Path(ready.read_text(encoding="utf-8"))
                moved_stage = stage.with_name(stage.name + ".opened")
                stage.rename(moved_stage)
                stage.mkdir(mode=0o700)
                (moved_stage / "src").mkdir()
                (moved_stage / "src/unit.cc").write_bytes(
                    b"reviewed source generation\n"
                )
                (stage / "src").mkdir()
                (stage / "src/unit.cc").write_bytes(b"hostile replacement generation\n")
                proceed.write_text("continue\n", encoding="utf-8")

                stdout, stderr = process.communicate(timeout=10)
                self.assertEqual(process.returncode, 74, stdout + stderr)
                self.assertIn("native COLMAP run stage name changed", stderr)
                object_path = moved_stage / "build/unit.o"
                receipt_path = moved_stage / "build/receipt.sha256"
                if receipt_path.exists():
                    self.assertEqual(
                        object_path.read_bytes(),
                        b"reviewed source generation\n",
                    )
                    expected = hashlib.sha256(
                        b"reviewed source generation\n"
                    ).hexdigest()
                    self.assertEqual(
                        receipt_path.read_text(encoding="utf-8"),
                        expected + "\n",
                    )
                self.assertFalse((stage / "build").exists())
                self.assertFalse(promoted.exists())
            finally:
                if process.poll() is None:
                    process.kill()
                    process.communicate(timeout=5)
                for stream in (process.stdout, process.stderr):
                    if stream is not None:
                        stream.close()

    def test_interrupted_partial_source_is_isolated_from_the_next_run(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            work = root / "work"
            work.mkdir()
            arguments = []
            for name in ("patch", "header", "source"):
                path = root / name
                path.write_text(f"{name}\n", encoding="utf-8")
                arguments.extend(("--input", str(path)))
            capture = root / "stages.txt"
            child = root / "partial.py"
            child.write_text(
                "\n".join(
                    (
                        "#!/usr/bin/env python3",
                        "import os, pathlib, sys",
                        "stage = pathlib.Path(sys.argv[2])",
                        "with open(os.environ['CAPTURE'], 'a', encoding='utf-8') as handle:",
                        "    handle.write(str(stage) + '\\n')",
                        "if os.environ.get('LEAVE_PARTIAL') == '1':",
                        "    (stage / 'src' / '.git').mkdir(parents=True)",
                        "    raise SystemExit(91)",
                    )
                )
                + "\n",
                encoding="utf-8",
            )
            child.chmod(0o755)
            command = [
                sys.executable,
                str(SUPERVISOR),
                "--work",
                str(work),
                "--lock",
                str(work / ".build.lock"),
                *arguments,
                "--",
                str(child),
            ]
            first_environment = os.environ.copy()
            first_environment.update({"CAPTURE": str(capture), "LEAVE_PARTIAL": "1"})
            first = subprocess.run(
                command,
                check=False,
                capture_output=True,
                text=True,
                env=first_environment,
            )
            self.assertEqual(first.returncode, 91, first.stderr)

            second_environment = os.environ.copy()
            second_environment["CAPTURE"] = str(capture)
            second = subprocess.run(
                command,
                check=False,
                capture_output=True,
                text=True,
                env=second_environment,
            )
            self.assertEqual(second.returncode, 0, second.stderr)
            first_stage, second_stage = map(
                Path, capture.read_text(encoding="utf-8").splitlines()
            )
            self.assertNotEqual(first_stage, second_stage)
            self.assertFalse(first_stage.exists())
            self.assertFalse(second_stage.exists())

    def test_supervisor_holds_lock_and_quiesces_the_process_group(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            work = root / "work"
            work.mkdir()
            inputs = []
            arguments = []
            for name in ("patch", "header", "source"):
                path = root / name
                path.write_text(f"{name}\n", encoding="utf-8")
                inputs.append(path)
                arguments.extend(("--input", str(path)))

            ready = root / "ready"
            child = root / "child.sh"
            child.write_text(
                "\n".join(
                    (
                        "#!/bin/bash",
                        "set -euo pipefail",
                        "(trap '' TERM; while :; do /bin/sleep 0.1; done) &",
                        'printf "%s %s\\n" "$$" "$!" > "$READY"',
                        "wait",
                    )
                )
                + "\n",
                encoding="utf-8",
            )
            child.chmod(0o755)
            command = [
                sys.executable,
                str(SUPERVISOR),
                "--work",
                str(work),
                "--lock",
                str(work / ".build.lock"),
                *arguments,
                "--termination-grace",
                "0.2",
                "--",
                str(child),
            ]
            environment = os.environ.copy()
            environment["READY"] = str(ready)
            process = subprocess.Popen(
                command,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
                env=environment,
            )
            child_pid = 0
            try:
                self.assertTrue(
                    wait_until(ready.is_file), "fake child never became ready"
                )
                child_pid, descendant_pid = map(
                    int, ready.read_text(encoding="utf-8").split()
                )

                lock_path = work / ".build.lock"
                opened_lock = work / ".opened.build.lock"
                lock_path.rename(opened_lock)
                lock_path.write_bytes(b"replacement lock generation\n")

                contender = subprocess.run(
                    [
                        sys.executable,
                        str(SUPERVISOR),
                        "--work",
                        str(work),
                        "--lock",
                        str(lock_path),
                        *arguments,
                        "--",
                        "/usr/bin/true",
                    ],
                    check=False,
                    capture_output=True,
                    text=True,
                )
                self.assertNotEqual(contender.returncode, 0)
                self.assertIn(
                    "another native COLMAP build is running", contender.stderr
                )

                opened_work = root / "opened-work"
                work.rename(opened_work)
                work.mkdir()
                lock_path.write_bytes(b"replacement work lock\n")
                stdout, stderr = process.communicate(timeout=5)
                self.assertEqual(process.returncode, 74, stdout + stderr)
                self.assertIn("native COLMAP run stage name changed", stderr)

                def process_is_gone(pid: int) -> bool:
                    try:
                        os.kill(pid, 0)
                    except ProcessLookupError:
                        return True
                    return False

                self.assertTrue(wait_until(lambda: process_is_gone(child_pid)))
                self.assertTrue(wait_until(lambda: process_is_gone(descendant_pid)))

                reusable = subprocess.run(
                    [
                        sys.executable,
                        str(SUPERVISOR),
                        "--work",
                        str(work),
                        "--lock",
                        str(lock_path),
                        *arguments,
                        "--",
                        "/usr/bin/true",
                    ],
                    check=False,
                    capture_output=True,
                    text=True,
                )
                self.assertEqual(reusable.returncode, 0, reusable.stderr)
            finally:
                if process.poll() is None:
                    if child_pid:
                        try:
                            os.killpg(child_pid, signal.SIGKILL)
                        except ProcessLookupError:
                            pass
                    process.kill()
                    process.communicate(timeout=5)
                for stream in (process.stdout, process.stderr):
                    if stream is not None:
                        stream.close()

    def test_signals_quiesce_children_and_remove_the_owned_stage(self) -> None:
        def process_is_gone(pid: int) -> bool:
            try:
                os.kill(pid, 0)
            except ProcessLookupError:
                return True
            return False

        for signum in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP):
            with (
                self.subTest(signum=signum),
                tempfile.TemporaryDirectory() as directory,
            ):
                root = Path(directory)
                work = root / "work"
                work.mkdir()
                arguments = []
                for name in ("patch", "header", "source"):
                    path = root / name
                    path.write_text(f"{name}\n", encoding="utf-8")
                    arguments.extend(("--input", str(path)))

                ready = root / "ready"
                child = root / "child.sh"
                child.write_text(
                    "\n".join(
                        (
                            "#!/bin/bash",
                            "set -euo pipefail",
                            "/bin/sleep 300 &",
                            'printf "%s %s %s\\n" "$$" "$!" "$PWD" > "$READY"',
                            "wait",
                        )
                    )
                    + "\n",
                    encoding="utf-8",
                )
                child.chmod(0o755)
                process = subprocess.Popen(
                    [
                        sys.executable,
                        str(SUPERVISOR),
                        "--work",
                        str(work),
                        "--lock",
                        str(work / ".build.lock"),
                        *arguments,
                        "--termination-grace",
                        "0.2",
                        "--",
                        str(child),
                    ],
                    stdout=subprocess.PIPE,
                    stderr=subprocess.PIPE,
                    text=True,
                    env={**os.environ, "READY": str(ready)},
                )
                child_pid = 0
                descendant_pid = 0
                stage = None
                try:
                    self.assertTrue(
                        wait_until(ready.is_file),
                        "signal fixture never became ready",
                    )
                    child_raw, descendant_raw, stage_raw = ready.read_text(
                        encoding="utf-8"
                    ).split()
                    child_pid = int(child_raw)
                    descendant_pid = int(descendant_raw)
                    stage = Path(stage_raw)
                    self.assertEqual(stage.parent.resolve(), work.resolve())
                    self.assertTrue(stage.name.startswith("input.stage."))

                    os.kill(process.pid, signum)
                    stdout, stderr = process.communicate(timeout=5)

                    self.assertEqual(
                        process.returncode,
                        128 + signum,
                        stdout + stderr,
                    )
                    self.assertFalse(stage.exists())
                    for pid in (child_pid, descendant_pid):
                        self.assertTrue(
                            wait_until(lambda pid=pid: process_is_gone(pid)),
                            f"signal left process {pid} alive",
                        )
                finally:
                    if process.poll() is None:
                        if child_pid:
                            try:
                                os.killpg(child_pid, signal.SIGKILL)
                            except ProcessLookupError:
                                pass
                        process.kill()
                        process.communicate(timeout=5)
                    for stream in (process.stdout, process.stderr):
                        if stream is not None:
                            stream.close()


if __name__ == "__main__":
    unittest.main()
