#!/usr/bin/env python3
"""Contracts for the source-built native COLMAP support prefix."""

from __future__ import annotations

import hashlib
import importlib.util
import io
import json
import fcntl
import os
import re
import shutil
import stat
import subprocess
import sys
import tarfile
import tempfile
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest import mock


ROOT = Path(__file__).resolve().parents[3]
BUILDER = ROOT / "scripts" / "toolchain" / "build_colmap_support.sh"
IMPLEMENTATION = ROOT / "scripts" / "toolchain" / "build_colmap_support_impl.sh"
CONTROL_FREEZER = ROOT / "scripts" / "toolchain" / "freeze_build_controls.py"
LOCK = ROOT / "scripts" / "toolchain" / "colmap-support-lock.json"
HOMEBREW_LOCK = ROOT / "scripts" / "toolchain" / "homebrew-lock.json"
EXTRACTOR = ROOT / "scripts" / "toolchain" / "safe_extract_source.py"
PROMOTER = ROOT / "scripts" / "toolchain" / "atomic_swap_install.py"
RELEASE_TEST = ROOT / "scripts" / "ci" / "test_release_scripts.sh"
PACKAGE_TOOLCHAIN = ROOT / "scripts" / "toolchain" / "package_toolchain.sh"
REPRODUCIBLE_ZIP = ROOT / "scripts" / "toolchain" / "create_reproducible_zip.py"
DEFAULT_INSTALL = ROOT / "Toolchains" / "build" / "colmap-support" / "install"
NORMALIZED_MTIME_EPOCH = 946684800
CONTROL_FREEZER_BEGIN = "# EASYSPLAT_CONTROL_FREEZER_BEGIN"
CONTROL_FREEZER_END = "# EASYSPLAT_CONTROL_FREEZER_END"
FREEZER_BOOTSTRAP_BEGIN = "# EASYSPLAT_FREEZER_BOOTSTRAP_BEGIN"
FREEZER_BOOTSTRAP_END = "# EASYSPLAT_FREEZER_BOOTSTRAP_END"
DEPENDENCIES = ("boost", "gflags", "glog", "libomp")
REQUIRED_STATIC_LIBRARIES = {
    "libboost_atomic.a",
    "libboost_chrono.a",
    "libboost_container.a",
    "libboost_date_time.a",
    "libboost_exception.a",
    "libboost_graph.a",
    "libboost_program_options.a",
    "libboost_thread.a",
    "libgflags.a",
    "libglog.a",
}
EXPECTED_TOOL_HASH_KEYS = {
    "ar",
    "clang",
    "clangxx",
    "cmake",
    "codesign",
    "curl",
    "install_name_tool",
    "ld",
    "lipo",
    "lockf",
    "ninja",
    "otool",
    "python",
    "ranlib",
    "ripgrep",
    "shasum",
    "vtool",
    "xattr",
    "xcodebuild",
    "xcrun",
}


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for block in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def install_tree_digest(root: Path) -> str:
    digest = hashlib.sha256()
    paths = [
        root,
        *sorted(root.rglob("*"), key=lambda item: item.relative_to(root).as_posix()),
    ]
    for path in paths:
        relative = "." if path == root else path.relative_to(root).as_posix()
        if relative == "build_info.json":
            continue
        metadata = path.lstat()
        mode = stat.S_IMODE(metadata.st_mode)
        if path.is_dir() and not path.is_symlink():
            kind = "directory"
            content = ""
        elif path.is_file() and not path.is_symlink():
            kind = "file"
            content = sha256(path)
        else:
            raise AssertionError(f"unexpected install entry: {path}")
        digest.update(relative.encode("utf-8"))
        digest.update(b"\0")
        digest.update(kind.encode("ascii"))
        digest.update(b"\0")
        digest.update(f"{mode:o}".encode("ascii"))
        digest.update(b"\0")
        digest.update(str(metadata.st_mtime_ns).encode("ascii"))
        digest.update(b"\0")
        digest.update(content.encode("ascii"))
        digest.update(b"\0")
    return digest.hexdigest()


def selected_developer_directory() -> Path:
    return Path(
        subprocess.run(
            ["/usr/bin/xcode-select", "-p"],
            check=True,
            capture_output=True,
            text=True,
        ).stdout.strip()
    )


def selected_xcode_tool(name: str) -> Path:
    environment = {"DEVELOPER_DIR": str(selected_developer_directory())}
    return Path(
        subprocess.run(
            ["/usr/bin/xcrun", "--find", name],
            check=True,
            capture_output=True,
            text=True,
            env=environment,
        ).stdout.strip()
    )


def selected_macos_sdk() -> Path:
    developer = selected_developer_directory()
    return Path(
        subprocess.run(
            ["/usr/bin/xcrun", "--sdk", "macosx", "--show-sdk-path"],
            check=True,
            capture_output=True,
            text=True,
            env={"DEVELOPER_DIR": str(developer)},
        ).stdout.strip()
    )


def load_python_module(path: Path, name: str):
    spec = importlib.util.spec_from_file_location(name, path)
    assert spec is not None and spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def extract_shell_function(source: str, name: str) -> str:
    marker = f"{name}() {{"
    start = source.index(marker)
    following = re.search(
        r"^[A-Za-z_][A-Za-z0-9_]*\(\) \{",
        source[start + len(marker) :],
        re.MULTILINE,
    )
    end = len(source) if following is None else start + len(marker) + following.start()
    return source[start:end].rstrip()


def run_build_lock_acquisition(
    work: Path,
    *,
    lockf: Path = Path("/usr/bin/lockf"),
    environment: dict[str, str] | None = None,
) -> subprocess.CompletedProcess[str]:
    source = IMPLEMENTATION.read_text(encoding="utf-8")
    functions = []
    if "validate_build_lock() {" in source:
        functions.append(extract_shell_function(source, "validate_build_lock"))
    functions.append(extract_shell_function(source, "acquire_build_lock"))
    harness = work.parent / "lock-harness.sh"
    harness.write_text(
        "#!/bin/bash\n"
        "set -euo pipefail\n"
        'WORK="$1"\n'
        'BUILD_LOCK="$WORK/.build.lock"\n'
        'LOCKF_BIN="$2"\n'
        'PYTHON_BIN=""\n'
        "LOCK_OWNED=0\n"
        'die() { printf "%s\\n" "$*" >&2; exit 1; }\n\n'
        + "\n\n".join(functions)
        + "\n\nacquire_build_lock\n",
        encoding="utf-8",
    )
    harness.chmod(0o700)
    process_environment = os.environ.copy()
    if environment is not None:
        process_environment.update(environment)
    return subprocess.run(
        [str(harness), str(work), str(lockf)],
        check=False,
        capture_output=True,
        text=True,
        env=process_environment,
    )


def load_control_freezer():
    source = CONTROL_FREEZER.read_text(encoding="utf-8")
    if CONTROL_FREEZER_BEGIN not in source or CONTROL_FREEZER_END not in source:
        raise AssertionError("shared control freezer has no testable boundary")
    payload = source.split(CONTROL_FREEZER_BEGIN, 1)[1].split(CONTROL_FREEZER_END, 1)[0]
    namespace: dict[str, object] = {}
    exec(compile(payload, str(CONTROL_FREEZER), "exec"), namespace)
    return namespace["freeze_control_file"], namespace["ControlFreezeError"]


def load_freezer_bootstrap():
    source = BUILDER.read_text(encoding="utf-8")
    if FREEZER_BOOTSTRAP_BEGIN not in source or FREEZER_BOOTSTRAP_END not in source:
        raise AssertionError(
            "dependency wrapper has no frozen-helper bootstrap boundary"
        )
    payload = source.split(FREEZER_BOOTSTRAP_BEGIN, 1)[1].split(
        FREEZER_BOOTSTRAP_END, 1
    )[0]
    namespace: dict[str, object] = {}
    exec(compile(payload, str(BUILDER), "exec"), namespace)
    return namespace["freeze_freezer_file"], namespace["FreezerBootstrapError"]


class ControlByteAttestationTests(unittest.TestCase):
    def test_shared_freezer_is_anonymous_and_immune_to_name_replacement(self) -> None:
        freeze, _ = load_freezer_bootstrap()
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            helper = root / "freezer.sh"
            output = root / "output"
            original = b'#!/bin/bash\nprintf "%s\\n" original >"$1"\n'
            helper.write_bytes(original)
            descriptor, digest = freeze(helper)
            try:
                helper.write_text(
                    '#!/bin/bash\nprintf "%s\\n" replacement >"$1"\n',
                    encoding="utf-8",
                )
                result = subprocess.run(
                    ["/bin/bash", f"/dev/fd/{descriptor}", str(output)],
                    check=False,
                    capture_output=True,
                    text=True,
                    pass_fds=(descriptor,),
                )
                metadata = os.fstat(descriptor)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(output.read_text(encoding="utf-8"), "original\n")
                self.assertEqual(digest, hashlib.sha256(original).hexdigest())
                self.assertEqual(metadata.st_nlink, 0)
                self.assertEqual(stat.S_IMODE(metadata.st_mode), 0o400)
                self.assertEqual(
                    fcntl.fcntl(descriptor, fcntl.F_GETFL) & os.O_ACCMODE,
                    os.O_RDONLY,
                )
            finally:
                os.close(descriptor)

    def test_shared_freezer_bootstrap_rejects_links_and_name_replacement(self) -> None:
        freeze, error = load_freezer_bootstrap()
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            victim = root / "victim"
            victim.write_text("preserve\n", encoding="utf-8")
            symlink = root / "symlink"
            symlink.symlink_to(victim)
            hardlink = root / "hardlink"
            os.link(victim, hardlink)
            for candidate in (symlink, hardlink):
                with self.subTest(candidate=candidate.name):
                    with self.assertRaises(error):
                        freeze(candidate)
                    self.assertEqual(victim.read_text(encoding="utf-8"), "preserve\n")
            group_writable = root / "group-writable"
            group_writable.write_text("unsafe\n", encoding="utf-8")
            group_writable.chmod(0o660)
            with self.assertRaises(error):
                freeze(group_writable)
            source = root / "source"
            source.write_text("original\n", encoding="utf-8")
            displaced = root / "displaced"

            def replace_name() -> None:
                source.replace(displaced)
                source.write_text("replacement\n", encoding="utf-8")

            with self.assertRaises(error):
                freeze(source, after_open=replace_name)
            self.assertEqual(displaced.read_text(encoding="utf-8"), "original\n")
            self.assertEqual(source.read_text(encoding="utf-8"), "replacement\n")

    def test_implementation_replacement_cannot_change_executed_bytes(self) -> None:
        freeze, _ = load_control_freezer()
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            implementation = root / "implementation.sh"
            output = root / "output"
            implementation.write_text(
                '#!/bin/bash\nprintf "%s\\n" original >"$1"\n',
                encoding="utf-8",
            )
            descriptor, digest = freeze(implementation)
            try:
                implementation.write_text(
                    '#!/bin/bash\nprintf "%s\\n" replacement >"$1"\n',
                    encoding="utf-8",
                )
                result = subprocess.run(
                    [
                        "/bin/bash",
                        "--noprofile",
                        "--norc",
                        f"/dev/fd/{descriptor}",
                        str(output),
                    ],
                    check=False,
                    capture_output=True,
                    text=True,
                    pass_fds=(descriptor,),
                )
                metadata = os.fstat(descriptor)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(output.read_text(encoding="utf-8"), "original\n")
                self.assertEqual(
                    digest,
                    hashlib.sha256(
                        b'#!/bin/bash\nprintf "%s\\n" original >"$1"\n'
                    ).hexdigest(),
                )
                self.assertEqual(metadata.st_nlink, 0)
                self.assertEqual(stat.S_IMODE(metadata.st_mode), 0o400)
                self.assertEqual(
                    fcntl.fcntl(descriptor, fcntl.F_GETFL) & os.O_ACCMODE,
                    os.O_RDONLY,
                )
            finally:
                os.close(descriptor)

    def test_promoter_replacement_cannot_change_cleanup_or_promotion_bytes(
        self,
    ) -> None:
        freeze, _ = load_control_freezer()
        implementation_source = IMPLEMENTATION.read_text(encoding="utf-8")
        self.assertIn("run_promoter() {", implementation_source)
        self.assertNotIn('"$PROMOTER"', implementation_source)
        runner = extract_shell_function(implementation_source, "run_promoter")
        self.assertIn('"$FROZEN_PROMOTER_FD" "$FROZEN_PROMOTER_SHA256"', runner)
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            promoter = root / "promoter.py"
            output = root / "operations"
            promoter.write_text(
                "from pathlib import Path\n"
                "import sys\n"
                "with Path(sys.argv[2]).open('a', encoding='utf-8') as handle:\n"
                "    handle.write(f'original:{sys.argv[1]}\\n')\n",
                encoding="utf-8",
            )
            descriptor, digest = freeze(promoter)
            try:
                promoter.write_text(
                    "from pathlib import Path\n"
                    "import sys\n"
                    "Path(sys.argv[2]).write_text('replacement\\n', encoding='utf-8')\n",
                    encoding="utf-8",
                )
                harness = root / "promoter-harness.sh"
                harness.write_text(
                    "#!/bin/bash\nset -euo pipefail\n"
                    'FROZEN_PROMOTER_FD="$1"\n'
                    'FROZEN_PROMOTER_SHA256="$2"\n'
                    + runner
                    + '\nrun_promoter cleanup "$3"\nrun_promoter promote "$3"\n',
                    encoding="utf-8",
                )
                harness.chmod(0o700)
                result = subprocess.run(
                    [str(harness), str(descriptor), digest, str(output)],
                    check=False,
                    capture_output=True,
                    text=True,
                    pass_fds=(descriptor,),
                )
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(
                    output.read_text(encoding="utf-8"),
                    "original:cleanup\noriginal:promote\n",
                )
            finally:
                os.close(descriptor)

    def test_control_freezer_rejects_links_and_mid_read_replacement(self) -> None:
        freeze, error = load_control_freezer()
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            victim = root / "victim"
            victim.write_text("preserve\n", encoding="utf-8")
            symlink = root / "symlink"
            symlink.symlink_to(victim)
            hardlink = root / "hardlink"
            os.link(victim, hardlink)
            for candidate in (symlink, hardlink):
                with self.subTest(candidate=candidate.name):
                    with self.assertRaises(error):
                        freeze(candidate)
                    self.assertEqual(victim.read_text(encoding="utf-8"), "preserve\n")

            source = root / "source"
            source.write_text("original\n", encoding="utf-8")
            displaced = root / "displaced"

            def replace_name() -> None:
                source.replace(displaced)
                source.write_text("replacement\n", encoding="utf-8")

            with self.assertRaises(error):
                freeze(source, after_open=replace_name)
            self.assertEqual(displaced.read_text(encoding="utf-8"), "original\n")
            self.assertEqual(source.read_text(encoding="utf-8"), "replacement\n")

    def test_receipt_contract_uses_frozen_executed_digests(self) -> None:
        wrapper = BUILDER.read_text(encoding="utf-8")
        implementation = IMPLEMENTATION.read_text(encoding="utf-8")
        for field in (
            "EASYSPLAT_FROZEN_FREEZER_SHA256",
            "EASYSPLAT_FROZEN_WRAPPER_SHA256",
            "EASYSPLAT_FROZEN_IMPLEMENTATION_SHA256",
            "EASYSPLAT_FROZEN_PROMOTER_SHA256",
        ):
            self.assertIn(field, wrapper)
            self.assertIn(field, implementation)
        self.assertIn('"/dev/fd/$FROZEN_IMPLEMENTATION_FD"', wrapper)
        self.assertIn('"builder_sha256": wrapper_sha256', implementation)
        self.assertIn('"control_freezer_sha256": freezer_sha256', implementation)
        self.assertIn(
            '"builder_implementation_sha256": implementation_sha256',
            implementation,
        )
        self.assertIn('"promoter_sha256": promoter_sha256', implementation)
        for stale in (
            '"builder_sha256": file_sha256(builder)',
            '"builder_implementation_sha256": file_sha256(implementation)',
            '"promoter_sha256": file_sha256(promoter)',
        ):
            self.assertNotIn(stale, implementation)


class BuildLockSafetyTests(unittest.TestCase):
    def test_regular_lock_is_acquired_without_changing_contents(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            work = root / "work"
            work.mkdir()
            lock_path = work / ".build.lock"
            lock_path.write_text("existing\n", encoding="utf-8")

            result = run_build_lock_acquisition(work)

            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(lock_path.read_text(encoding="utf-8"), "existing\n")

    def test_symlink_lock_is_rejected_without_truncating_target(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            work = root / "work"
            work.mkdir()
            target = root / "target"
            target.write_text("keep me\n", encoding="utf-8")
            (work / ".build.lock").symlink_to(target)

            result = run_build_lock_acquisition(work)

            self.assertEqual(target.read_text(encoding="utf-8"), "keep me\n")
            self.assertNotEqual(result.returncode, 0)

    def test_hardlinked_lock_is_rejected_without_truncating_target(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            work = root / "work"
            work.mkdir()
            target = root / "target"
            target.write_text("keep me\n", encoding="utf-8")
            os.link(target, work / ".build.lock")

            result = run_build_lock_acquisition(work)

            self.assertEqual(target.read_text(encoding="utf-8"), "keep me\n")
            self.assertNotEqual(result.returncode, 0)

    def test_lock_name_replacement_after_open_fails_closed(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            work = root / "work"
            work.mkdir()
            lock_path = work / ".build.lock"
            lock_path.write_text("original\n", encoding="utf-8")
            hostile_lockf = root / "hostile-lockf.sh"
            hostile_lockf.write_text(
                "#!/bin/bash\n"
                "set -euo pipefail\n"
                'mv "$TEST_LOCK_PATH" "$TEST_LOCK_PATH.opened"\n'
                'printf "%s\\n" replacement >"$TEST_LOCK_PATH"\n'
                'exec /usr/bin/lockf "$@"\n',
                encoding="utf-8",
            )
            hostile_lockf.chmod(0o700)

            result = run_build_lock_acquisition(
                work,
                lockf=hostile_lockf,
                environment={"TEST_LOCK_PATH": str(lock_path)},
            )

            self.assertNotEqual(result.returncode, 0)


class SourceContractTests(unittest.TestCase):
    def builder_source(self) -> str:
        self.assertTrue(BUILDER.is_file(), BUILDER)
        self.assertTrue(IMPLEMENTATION.is_file(), IMPLEMENTATION)
        return "\n".join(
            (
                BUILDER.read_text(encoding="utf-8"),
                IMPLEMENTATION.read_text(encoding="utf-8"),
            )
        )

    def wrapper_source(self) -> str:
        return BUILDER.read_text(encoding="utf-8")

    def test_builder_uses_the_reviewed_lock_and_is_wired_into_release_tests(
        self,
    ) -> None:
        script = self.builder_source()
        self.assertTrue(LOCK.is_file(), LOCK)
        lock = json.loads(LOCK.read_text(encoding="utf-8"))
        for name in DEPENDENCIES:
            entry = lock["dependencies"][name]
            self.assertRegex(entry["source"]["url"], r"^https://")
            self.assertRegex(entry["source"]["sha256"], r"^[0-9a-f]{64}$")
            self.assertIn(name, script)
        self.assertIn("colmap-support-lock.json", script)
        self.assertNotIn('LOCK="$ROOT/scripts/toolchain/homebrew-lock.json"', script)
        self.assertNotIn("brew --prefix", script)
        self.assertRegex(
            RELEASE_TEST.read_text(encoding="utf-8"),
            r'test_colmap_support_builder\.py"\s+\\?\s*SourceContractTests\s+ArchiveSafetyTests\s+ReleaseArchiveMetadataTests\s+AtomicPromotionTests',
        )
        self.assertIn(
            '/usr/bin/python3 -I "$ROOT/scripts/toolchain/tests/test_colmap_support_builder.py"',
            RELEASE_TEST.read_text(encoding="utf-8"),
        )

    def test_release_archives_use_the_reproducible_writer(self) -> None:
        script = PACKAGE_TOOLCHAIN.read_text(encoding="utf-8")
        self.assertTrue(REPRODUCIBLE_ZIP.is_file(), REPRODUCIBLE_ZIP)
        self.assertIn(
            'REPRODUCIBLE_ZIP="$ROOT/scripts/toolchain/create_reproducible_zip.py"',
            script,
        )
        self.assertEqual(script.count('python3 "$REPRODUCIBLE_ZIP"'), 3)
        self.assertNotIn("zip -q -r", script)

    def test_support_boundary_excludes_unused_metis(self) -> None:
        lock = json.loads(LOCK.read_text(encoding="utf-8"))
        self.assertNotIn("metis", lock["dependencies"])
        self.assertNotIn("metis", self.builder_source().lower())

    def test_homebrew_provenance_lock_remains_canonical(self) -> None:
        lock = json.loads(HOMEBREW_LOCK.read_text(encoding="utf-8"))
        self.assertEqual(
            lock["formulae"]["metis"]["source"]["url"],
            "https://karypis.github.io/glaros/files/sw/metis/metis-5.1.0.tar.gz",
        )

    def test_openmp_source_license_is_recorded_accurately(self) -> None:
        lock = json.loads(LOCK.read_text(encoding="utf-8"))
        self.assertEqual(
            lock["dependencies"]["libomp"]["license"],
            "Apache-2.0 WITH LLVM-exception",
        )

    def test_gflags_does_not_mutate_the_user_package_registry(self) -> None:
        script = self.builder_source()
        self.assertIn("-DREGISTER_BUILD_DIR=OFF", script)
        self.assertIn("-DREGISTER_INSTALL_PREFIX=OFF", script)

    def test_glog_disables_unwind_with_the_upstream_enum(self) -> None:
        script = self.builder_source()
        self.assertIn("-DWITH_UNWIND=none", script)
        self.assertNotIn("-DWITH_UNWIND=OFF", script)

    def test_builds_static_support_and_only_shared_openmp_for_macos_15_arm64(
        self,
    ) -> None:
        script = self.builder_source()
        for contract in (
            "CMAKE_OSX_ARCHITECTURES=arm64",
            "CMAKE_OSX_DEPLOYMENT_TARGET=15.0",
            "CMAKE_OSX_SYSROOT",
            "CMAKE_ASM_FLAGS",
            "MACOSX_DEPLOYMENT_TARGET=15.0",
            "-isysroot",
            "link=static",
            "BUILD_SHARED_LIBS=OFF",
            "LIBOMP_ENABLE_SHARED=ON",
            "LIBOMP_USE_ITT_NOTIFY=OFF",
            "OPENMP_ENABLE_LIBOMPTARGET=OFF",
            "ZERO_AR_DATE=1",
            "SOURCE_DATE_EPOCH=0",
            "umask 022",
            "-ffile-prefix-map=",
            "-fdebug-prefix-map=",
            "--ignore-site-config",
            "--user-config=",
            "CMAKE_TOOLCHAIN_FILE",
            "DYLD_INSERT_LIBRARIES",
            "DYLD_FALLBACK_LIBRARY_PATH",
            "DESTDIR",
            "MAKEFLAGS",
        ):
            self.assertIn(contract, script)
        self.assertNotRegex(script, r"-(?:mcpu|march)(?:=|\s+)native")
        self.assertIn("lib/libomp.dylib", script)
        self.assertIn("libboost_graph.a", script)
        self.assertIn("libboost_exception.a", script)
        self.assertIn("libboost_program_options.a", script)
        self.assertIn("libgflags.a", script)
        self.assertIn("libglog.a", script)

    def test_download_extraction_and_promotion_fail_closed(self) -> None:
        script = self.builder_source()
        for contract in (
            "curl --proto '=https'",
            '"$SHASUM_BIN" -a 256',
            "safe_extract_source.py",
            "atomic_swap_install.py",
            "install.stage.",
            ".build.lock",
            '"$LOCKF_BIN" -s -t 0 9',
            "build_info.json",
            "install_tree_sha256",
            "ArtifactTests",
        ):
            self.assertIn(contract, script)
        self.assertIn("https://", script)
        self.assertNotIn('filter="data"', script)
        self.assertNotIn("install.previous.", script)

    def test_cleanup_remains_available_until_tree_receipt_succeeds(self) -> None:
        implementation = IMPLEMENTATION.read_text(encoding="utf-8")
        promotion = implementation.split("promote_install() {", 1)[1].split("\n}", 1)[0]
        receipt = promotion.index('tree_receipt="$(')
        disable_cleanup = promotion.index("STAGE_CLEANUP_ALLOWED=0")
        begin_promotion = promotion.index(
            'run_promoter "$STAGE" "$INSTALL" "$tree_receipt"'
        )
        self.assertNotIn('"$PROMOTER"', promotion)

        self.assertLess(receipt, disable_cleanup)
        self.assertLess(disable_cleanup, begin_promotion)

    def test_unexpected_arguments_fail_before_build_preflight(self) -> None:
        implementation = IMPLEMENTATION.read_text(encoding="utf-8")
        guard = 'if [ "$#" -ne 0 ]; then'
        self.assertIn(guard, implementation)
        self.assertIn('die "usage: build_colmap_support.sh"', implementation)
        self.assertLess(
            implementation.index(guard),
            implementation.index("\npreflight\n"),
        )

    def test_builder_reexecutes_with_only_pinned_external_tools(self) -> None:
        script = self.builder_source()
        wrapper = self.wrapper_source()
        for contract in (
            "#!/bin/bash",
            "builtin type -P cmake",
            "builtin type -P ninja",
            "builtin type -P rg",
            "exec /usr/bin/env -i",
            "/bin/bash --noprofile --norc",
            "build_colmap_support_impl.sh",
            'CMAKE_BIN="$BOOTSTRAP_CMAKE_BIN"',
            'NINJA_BIN="$BOOTSTRAP_NINJA_BIN"',
            'RG_BIN="$BOOTSTRAP_RG_BIN"',
        ):
            self.assertIn(contract, script)
        self.assertNotIn("EASYSPLAT_HERMETIC_BUILD", wrapper)
        self.assertNotIn('CMAKE_BIN="$(command -v cmake)"', script)

    def test_checkout_paths_with_whitespace_fail_before_build(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            checkout = Path(temporary) / "source tree"
            toolchain_directory = checkout / "scripts" / "toolchain"
            toolchain_directory.mkdir(parents=True)
            copied_builder = toolchain_directory / BUILDER.name
            shutil.copy2(BUILDER, copied_builder)
            shutil.copy2(IMPLEMENTATION, toolchain_directory / IMPLEMENTATION.name)
            shutil.copy2(CONTROL_FREEZER, toolchain_directory / CONTROL_FREEZER.name)
            shutil.copy2(PROMOTER, toolchain_directory / PROMOTER.name)

            environment = os.environ.copy()
            environment["BASH_FUNC_uname%%"] = "() { printf 'x86_64\\n'; }"
            environment["EASYSPLAT_HERMETIC_BUILD"] = "1"
            environment["EASYSPLAT_BOOTSTRAP_CMAKE"] = "/private/tmp/forged-cmake"

            result = subprocess.run(
                [str(copied_builder)],
                check=False,
                capture_output=True,
                text=True,
                env=environment,
            )

            self.assertNotEqual(result.returncode, 0)
            self.assertIn("checkout path contains whitespace", result.stderr)
            self.assertNotIn("must run natively", result.stderr)

    def test_validation_rejects_host_paths_wrong_architecture_and_newer_macos(
        self,
    ) -> None:
        script = self.builder_source()
        for contract in (
            "compile_commands.json",
            "build.ninja",
            "host-specific compiler tuning entered the build",
            "Homebrew dependency entered the build",
            '"$RG_BIN" -a',
            '"$LIPO_BIN"',
            '"$OTOOL_BIN"',
            '"$VTOOL_BIN" -show-build',
            "newer than macOS 15.0",
            "not a macOS object",
            "archive member metadata is not deterministic",
            "builder_sha256",
            "source_lock_sha256",
            "extractor_sha256",
            "promoter_sha256",
            "builder_implementation_sha256",
            "ittnotify_static.cpp entered the OpenMP build",
            "@rpath/libomp.dylib",
            '"$CODESIGN_BIN" --force --sign - --timestamp=none',
        ):
            self.assertIn(contract, script)

    def test_receipt_hashes_build_tools_and_the_selected_sdk(self) -> None:
        script = self.builder_source()
        self.assertIn("build_tool_sha256", script)
        self.assertIn("macos_sdk_settings_sha256", script)
        self.assertIn("VTOOL_BIN", script)
        self.assertIn("XCODE_DEVELOPER_DIR", script)
        self.assertIn("LD_BIN", script)
        self.assertIn("resolve_xcode_tool", script)
        self.assertIn('"ripgrep": command_version', script)
        self.assertNotIn('CLANG_BIN="/usr/bin/clang"', script)
        self.assertNotIn('PYTHON_BIN="/usr/bin/python3"', script)
        for contract in (
            '-DCMAKE_AR="$AR_BIN"',
            '-DCMAKE_RANLIB="$RANLIB_BIN"',
            '-DCMAKE_LINKER="$LD_BIN"',
            '-DPython3_EXECUTABLE="$PYTHON_BIN"',
            '"$file" "$MACOS_SDK" "$ROOT" "$CLANG_BIN" "$CLANGXX_BIN"',
            '"$PYTHON_BIN" - "$archive" "$metadata" "$AR_BIN"',
            '"$INSTALL_NAME_TOOL_BIN" -id @rpath/libomp.dylib',
            '"$XCODEBUILD_BIN"',
        ):
            self.assertIn(contract, script)

    def test_final_metadata_and_override_environment_are_bounded(self) -> None:
        script = self.builder_source()
        for contract in (
            'NORMALIZED_MTIME_EPOCH="946684800"',
            "normalize_install_metadata",
            "st_mtime_ns",
            "st_uid",
            "st_gid",
            '"$XATTR_BIN" -c -r',
            "extended attributes survived COLMAP support normalization",
            "C_INCLUDE_PATH",
            "CPLUS_INCLUDE_PATH",
            "OBJC_INCLUDE_PATH",
            "OBJCPLUS_INCLUDE_PATH",
            "COMPILER_PATH",
            "GCC_EXEC_PREFIX",
            "LD_LIBRARY_PATH",
            "BASH_ENV",
            "PYTHONPATH",
            "DYLD_*",
        ):
            self.assertIn(contract, script)

    def test_receipt_identity_is_independent_of_the_build_account(self) -> None:
        script = self.builder_source()
        receipt_builder = extract_shell_function(
            IMPLEMENTATION.read_text(encoding="utf-8"), "stage_receipt"
        )
        self.assertIn(
            '"ownership_policy": "invoking-build-user-and-primary-group"',
            script,
        )
        self.assertNotRegex(script, r'"normalized_owner_(?:uid|gid)"\s*:')
        self.assertNotIn("metadata.st_uid", receipt_builder)
        self.assertNotIn("metadata.st_gid", receipt_builder)


class PortableTreeIdentityTests(unittest.TestCase):
    def test_normalized_tree_digest_ignores_simulated_numeric_ownership(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary) / "install"
            root.mkdir()
            payload = root / "payload.bin"
            payload.write_bytes(b"portable payload\n")
            os.chmod(root, 0o755)
            os.chmod(payload, 0o644)
            os.utime(payload, (NORMALIZED_MTIME_EPOCH, NORMALIZED_MTIME_EPOCH))
            os.utime(root, (NORMALIZED_MTIME_EPOCH, NORMALIZED_MTIME_EPOCH))
            expected = install_tree_digest(root)
            original_lstat = Path.lstat

            def alternate_owner(path: Path) -> SimpleNamespace:
                metadata = original_lstat(path)
                return SimpleNamespace(
                    st_mode=metadata.st_mode,
                    st_uid=4_000_000_001,
                    st_gid=4_000_000_002,
                    st_mtime_ns=metadata.st_mtime_ns,
                )

            with mock.patch.object(Path, "lstat", alternate_owner):
                actual = install_tree_digest(root)

            self.assertEqual(actual, expected)


class ArchiveSafetyTests(unittest.TestCase):
    def add_directory(self, archive: tarfile.TarFile, name: str) -> None:
        member = tarfile.TarInfo(name)
        member.type = tarfile.DIRTYPE
        member.mode = 0o755
        archive.addfile(member)

    def add_file(
        self, archive: tarfile.TarFile, name: str, content: bytes, mode: int = 0o644
    ) -> None:
        member = tarfile.TarInfo(name)
        member.size = len(content)
        member.mode = mode
        archive.addfile(member, io.BytesIO(content))

    def add_symlink(self, archive: tarfile.TarFile, name: str, target: str) -> None:
        member = tarfile.TarInfo(name)
        member.type = tarfile.SYMTYPE
        member.linkname = target
        member.mode = 0o777
        archive.addfile(member)

    def run_extractor(
        self, archive: Path, destination: Path
    ) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            ["/usr/bin/python3", str(EXTRACTOR), str(archive), str(destination)],
            check=False,
            capture_output=True,
            text=True,
        )

    def test_stock_python_extracts_regular_files_and_safe_relative_symlinks(
        self,
    ) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            archive_path = root / "valid.tar.gz"
            destination = root / "destination"
            destination.mkdir()
            with tarfile.open(archive_path, "w:gz") as archive:
                self.add_directory(archive, "source")
                self.add_directory(archive, "source/bin")
                self.add_directory(archive, "source/lib")
                self.add_file(archive, "source/lib/tool", b"payload\n", 0o755)
                self.add_symlink(archive, "source/bin/tool", "../lib/tool-link")
                self.add_symlink(archive, "source/lib/tool-link", "tool")

            result = self.run_extractor(archive_path, destination)

            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            extracted = Path(result.stdout.strip())
            self.assertEqual(extracted, (destination / "source").resolve())
            self.assertEqual((extracted / "bin/tool").read_bytes(), b"payload\n")
            self.assertTrue((extracted / "bin/tool").is_symlink())
            self.assertTrue((extracted / "lib/tool-link").is_symlink())
            self.assertTrue(os.access(extracted / "lib/tool", os.X_OK))

    def test_escape_duplicate_hardlink_and_special_members_are_rejected(self) -> None:
        fixtures = (
            (
                "path",
                lambda archive: self.add_file(archive, "source/../../escape", b"x"),
            ),
            (
                "symlink",
                lambda archive: self.add_symlink(
                    archive, "source/link", "../../escape"
                ),
            ),
            (
                "duplicate",
                lambda archive: (
                    self.add_file(archive, "source/file", b"one"),
                    self.add_file(archive, "source/file", b"two"),
                ),
            ),
            (
                "hardlink",
                lambda archive: self._add_link(archive, "source/link", "source/file"),
            ),
            ("fifo", lambda archive: self._add_fifo(archive, "source/fifo")),
        )
        for label, populate in fixtures:
            with self.subTest(label=label), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary)
                archive_path = root / f"{label}.tar"
                destination = root / "destination"
                destination.mkdir()
                with tarfile.open(archive_path, "w") as archive:
                    self.add_directory(archive, "source")
                    if label == "hardlink":
                        self.add_file(archive, "source/file", b"target")
                    populate(archive)

                result = self.run_extractor(archive_path, destination)

                self.assertNotEqual(result.returncode, 0, result.stdout)
                self.assertFalse((root / "escape").exists())

    def test_compressed_payloads_remain_in_archive_order(self) -> None:
        module = load_python_module(EXTRACTOR, "safe_extract_source")
        with tempfile.TemporaryDirectory() as temporary:
            archive_path = Path(temporary) / "reverse-lexical.tar.xz"
            with tarfile.open(archive_path, "w:xz") as archive:
                self.add_directory(archive, "source")
                self.add_file(archive, "source/z-first", b"first")
                self.add_file(archive, "source/a-second", b"second")
            with tarfile.open(archive_path, "r:xz") as archive:
                by_path, _ = module.validate_members(archive.getmembers())

            ordered = module.regular_files_in_archive_order(by_path)

            self.assertEqual(
                [member.name for _, member in ordered],
                ["source/z-first", "source/a-second"],
            )

    def _add_link(self, archive: tarfile.TarFile, name: str, target: str) -> None:
        member = tarfile.TarInfo(name)
        member.type = tarfile.LNKTYPE
        member.linkname = target
        archive.addfile(member)

    def _add_fifo(self, archive: tarfile.TarFile, name: str) -> None:
        member = tarfile.TarInfo(name)
        member.type = tarfile.FIFOTYPE
        archive.addfile(member)


class ReleaseArchiveMetadataTests(unittest.TestCase):
    def test_zip_bytes_ignore_source_group_and_extended_attributes(self) -> None:
        alternate_groups = [group for group in os.getgroups() if group != os.getgid()]
        if not alternate_groups:
            self.skipTest("the current account has no alternate group for the fixture")

        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            archives = []
            for name, group, add_attribute in (
                ("primary", os.getgid(), True),
                ("alternate", alternate_groups[0], False),
            ):
                fixture = root / name / "payload"
                fixture.mkdir(parents=True)
                payload = fixture / "library.dylib"
                payload.write_bytes(b"portable bytes\n")
                os.chown(fixture, os.getuid(), group)
                os.chown(payload, os.getuid(), group)
                os.chmod(fixture, 0o755)
                os.chmod(payload, 0o644)
                os.utime(payload, (NORMALIZED_MTIME_EPOCH, NORMALIZED_MTIME_EPOCH))
                os.utime(fixture, (NORMALIZED_MTIME_EPOCH, NORMALIZED_MTIME_EPOCH))
                if add_attribute:
                    subprocess.run(
                        [
                            "/usr/bin/xattr",
                            "-w",
                            "com.easysplat.metadata-test",
                            "present",
                            str(payload),
                        ],
                        check=True,
                    )
                archive = root / f"{name}.zip"
                subprocess.run(
                    [
                        sys.executable,
                        str(REPRODUCIBLE_ZIP),
                        "--root",
                        str(fixture.parent),
                        "--output",
                        str(archive),
                        "--path",
                        "payload",
                    ],
                    check=True,
                )
                archives.append(archive.read_bytes())

            self.assertEqual(archives[0], archives[1])


class AtomicPromotionTests(unittest.TestCase):
    def test_staged_tree_is_synced_before_first_rename(self) -> None:
        module = load_python_module(PROMOTER, "atomic_swap_sync_before_rename")
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            install = root / "install"
            stage = root / "stage"
            stage.mkdir()
            (stage / "marker").write_text("new", encoding="utf-8")
            events = []
            original_rename = module._rename_exclusive_at
            module.sync_tree = lambda path: events.append(("sync", Path(path)))

            def recording_rename(parent, source, destination):
                events.append(("rename", root / source))
                original_rename(parent, source, destination)

            module._rename_exclusive_at = recording_rename

            module.promote(stage, install)

            self.assertEqual(events[0], ("sync", stage))
            self.assertEqual(events[1], ("rename", stage))

    def test_staged_tree_syncs_files_then_directories_bottom_up(self) -> None:
        module = load_python_module(PROMOTER, "atomic_swap_tree_order")
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary) / "stage"
            nested = root / "a" / "b"
            nested.mkdir(parents=True)
            (root / "root-file").write_text("root", encoding="utf-8")
            (nested / "nested-file").write_text("nested", encoding="utf-8")
            events = []
            module.sync_regular_file = lambda path: events.append(("file", Path(path)))
            module.sync_directory = lambda path: events.append(
                ("directory", Path(path))
            )

            module.sync_tree(root)

            kinds = [kind for kind, _ in events]
            self.assertEqual(
                kinds, ["file", "file", "directory", "directory", "directory"]
            )
            self.assertEqual(
                [path for kind, path in events if kind == "directory"],
                [nested, nested.parent, root],
            )

    def test_staged_tree_sync_failure_leaves_paths_unchanged(self) -> None:
        module = load_python_module(PROMOTER, "atomic_swap_tree_failure")
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            install = root / "install"
            stage = root / "stage"
            install.mkdir()
            stage.mkdir()
            (install / "marker").write_text("old", encoding="utf-8")
            (stage / "marker").write_text("new", encoding="utf-8")
            module.sync_tree = lambda _: (_ for _ in ()).throw(OSError("fsync"))

            with self.assertRaises(OSError):
                module.promote(stage, install)

            self.assertEqual((install / "marker").read_text(encoding="utf-8"), "old")
            self.assertEqual((stage / "marker").read_text(encoding="utf-8"), "new")

    def test_existing_install_is_atomically_swapped_with_staged_install(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            install = root / "install"
            stage = root / "stage"
            install.mkdir()
            stage.mkdir()
            (install / "marker").write_text("old", encoding="utf-8")
            (stage / "marker").write_text("new", encoding="utf-8")

            receipt = subprocess.run(
                [
                    "/usr/bin/python3",
                    str(PROMOTER),
                    "--tree-receipt",
                    str(stage),
                ],
                check=True,
                capture_output=True,
                text=True,
            ).stdout.strip()

            result = subprocess.run(
                [
                    "/usr/bin/python3",
                    str(PROMOTER),
                    str(stage),
                    str(install),
                    receipt,
                ],
                check=False,
                capture_output=True,
                text=True,
            )

            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertEqual((install / "marker").read_text(encoding="utf-8"), "new")
            self.assertEqual((stage / "marker").read_text(encoding="utf-8"), "old")

    def test_invalid_stage_cannot_replace_an_existing_install(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            install = root / "install"
            install.mkdir()
            (install / "marker").write_text("old", encoding="utf-8")

            result = subprocess.run(
                [
                    "/usr/bin/python3",
                    str(PROMOTER),
                    str(root / "missing"),
                    str(install),
                    "tree-v1:" + ("0" * 64),
                ],
                check=False,
                capture_output=True,
                text=True,
            )

            self.assertNotEqual(result.returncode, 0)
            self.assertEqual((install / "marker").read_text(encoding="utf-8"), "old")

    def test_directory_sync_failure_rolls_back_an_existing_install(self) -> None:
        module = load_python_module(PROMOTER, "atomic_swap_existing_sync_failure")
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            install = root / "install"
            stage = root / "stage"
            install.mkdir()
            stage.mkdir()
            (install / "marker").write_text("old", encoding="utf-8")
            (stage / "marker").write_text("new", encoding="utf-8")
            module.sync_directory = lambda _: (_ for _ in ()).throw(OSError("fsync"))

            with self.assertRaises(OSError):
                module.promote(stage, install)

            self.assertEqual((install / "marker").read_text(encoding="utf-8"), "old")
            self.assertEqual((stage / "marker").read_text(encoding="utf-8"), "new")

    def test_directory_sync_failure_rolls_back_a_fresh_install(self) -> None:
        module = load_python_module(PROMOTER, "atomic_swap_fresh_sync_failure")
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            install = root / "install"
            stage = root / "stage"
            stage.mkdir()
            (stage / "marker").write_text("new", encoding="utf-8")
            module.sync_directory = lambda _: (_ for _ in ()).throw(OSError("fsync"))

            with self.assertRaises(OSError):
                module.promote(stage, install)

            self.assertFalse(install.exists())
            self.assertEqual((stage / "marker").read_text(encoding="utf-8"), "new")


class ArtifactTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        configured = os.environ.get("EASYSPLAT_COLMAP_SUPPORT_ROOT")
        cls.install = Path(configured).resolve() if configured else DEFAULT_INSTALL
        if not cls.install.is_dir():
            raise unittest.SkipTest(
                "build_colmap_support.sh has not produced an install"
            )

    def test_file_set_and_linkage_are_bounded(self) -> None:
        symlinks = [path for path in self.install.rglob("*") if path.is_symlink()]
        self.assertEqual(symlinks, [])
        dylibs = {
            path.relative_to(self.install).as_posix()
            for path in self.install.rglob("*.dylib")
        }
        self.assertEqual(dylibs, {"lib/libomp.dylib"})
        static_libraries = {path.name for path in (self.install / "lib").glob("*.a")}
        self.assertEqual(static_libraries, REQUIRED_STATIC_LIBRARIES)
        for path in [self.install, *self.install.rglob("*")]:
            metadata = path.lstat()
            self.assertEqual(
                metadata.st_mtime_ns,
                NORMALIZED_MTIME_EPOCH * 1_000_000_000,
                path,
            )
            self.assertEqual(
                (metadata.st_uid, metadata.st_gid), (os.getuid(), os.getgid()), path
            )
            if path.is_file():
                self.assertTrue(stat.S_ISREG(metadata.st_mode), path)
                expected_mode = 0o755 if path.suffix == ".dylib" else 0o644
            else:
                self.assertTrue(stat.S_ISDIR(metadata.st_mode), path)
                expected_mode = 0o755
            self.assertEqual(stat.S_IMODE(metadata.st_mode), expected_mode, path)
        attributes = subprocess.run(
            ["/usr/bin/xattr", "-l", "-r", str(self.install)],
            check=True,
            capture_output=True,
        ).stdout
        self.assertEqual(attributes, b"")

    def test_libraries_are_arm64_and_target_macos_15_or_earlier(self) -> None:
        libraries = sorted((self.install / "lib").glob("*.a"))
        libraries.append(self.install / "lib" / "libomp.dylib")
        for library in libraries:
            with self.subTest(library=library.name):
                architecture = subprocess.run(
                    [str(selected_xcode_tool("lipo")), "-info", str(library)],
                    check=True,
                    capture_output=True,
                    text=True,
                ).stdout
                self.assertRegex(architecture, r"architecture: arm64$")
                if library.suffix == ".a":
                    load_commands = subprocess.run(
                        [str(selected_xcode_tool("otool")), "-l", str(library)],
                        check=True,
                        capture_output=True,
                        text=True,
                    ).stdout
                    versions = re.findall(
                        r"^\s*minos\s+([0-9.]+)$", load_commands, re.MULTILINE
                    )
                    platforms = re.findall(
                        r"^\s*platform\s+([0-9]+)$", load_commands, re.MULTILINE
                    )
                    self.assertTrue(versions, library)
                    self.assertTrue(
                        all(
                            tuple(map(int, value.split("."))) <= (15, 0)
                            for value in versions
                        )
                    )
                    self.assertEqual(
                        set(platforms), {"1"}, f"not a macOS object: {library}"
                    )
                    members = subprocess.run(
                        [str(selected_xcode_tool("ar")), "-t", str(library)],
                        check=True,
                        capture_output=True,
                        text=True,
                    ).stdout.splitlines()
                    object_members = [
                        member
                        for member in members
                        if not member.startswith("__.SYMDEF")
                    ]
                    self.assertEqual(len(platforms), len(object_members), library)
                    self.assertEqual(len(versions), len(object_members), library)
                    self.assert_archive_headers_are_deterministic(library)
                else:
                    metadata = subprocess.run(
                        [
                            str(selected_xcode_tool("vtool")),
                            "-show-build",
                            str(library),
                        ],
                        check=True,
                        capture_output=True,
                        text=True,
                    ).stdout
                    match = re.search(r"^\s*minos\s+([0-9.]+)$", metadata, re.MULTILINE)
                    self.assertIsNotNone(match, library)
                    assert match is not None
                    self.assertLessEqual(
                        tuple(map(int, match.group(1).split("."))), (15, 0)
                    )
                    self.assertIsNotNone(
                        re.search(r"^\s*platform\s+MACOS$", metadata, re.MULTILINE),
                        library,
                    )

    def assert_archive_headers_are_deterministic(self, archive: Path) -> None:
        data = archive.read_bytes()
        self.assertTrue(data.startswith(b"!<arch>\n"), archive)
        offset = 8
        while offset < len(data):
            header = data[offset : offset + 60]
            self.assertEqual(len(header), 60, archive)
            self.assertEqual(header[58:60], b"`\n", archive)
            timestamp = int(header[16:28].decode("ascii").strip() or "0")
            owner = int(header[28:34].decode("ascii").strip() or "0")
            group = int(header[34:40].decode("ascii").strip() or "0")
            mode = header[40:48].decode("ascii").strip()
            self.assertEqual(
                (timestamp, owner, group),
                (0, 0, 0),
                f"archive member metadata is not deterministic: {archive}",
            )
            raw_name = header[:16].decode("ascii").strip()
            name = raw_name
            size = int(header[48:58].decode("ascii").strip())
            if raw_name.startswith("#1/"):
                name_size = int(raw_name[3:])
                name = (
                    data[offset + 60 : offset + 60 + name_size]
                    .rstrip(b"\0")
                    .decode("utf-8", errors="replace")
                )
            expected_mode = "100644" if name.startswith("__.SYMDEF") else "644"
            self.assertEqual(mode, expected_mode, archive)
            offset += 60 + size + (size % 2)
        self.assertEqual(offset, len(data), archive)

    def test_installed_bytes_do_not_contain_build_or_homebrew_dependency_paths(
        self,
    ) -> None:
        forbidden = (
            str(ROOT),
            "/opt/homebrew/",
            "/usr/local/",
        )
        candidates = sorted((self.install / "lib").glob("*.a"))
        candidates.append(self.install / "lib" / "libomp.dylib")
        candidates.extend(sorted((self.install / "lib/cmake").rglob("*.cmake")))
        for candidate in candidates:
            with self.subTest(candidate=candidate.relative_to(self.install)):
                strings = subprocess.run(
                    ["/usr/bin/strings", str(candidate)],
                    check=True,
                    capture_output=True,
                    text=True,
                    errors="replace",
                ).stdout
                for value in forbidden:
                    self.assertNotIn(value, strings)

    def test_cmake_packages_resolve_after_prefix_move(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            moved = root / "moved"
            subprocess.run(
                ["/usr/bin/ditto", str(self.install), str(moved)], check=True
            )
            source = root / "source"
            build = root / "build"
            source.mkdir()
            (source / "CMakeLists.txt").write_text(
                "\n".join(
                    (
                        "cmake_minimum_required(VERSION 3.25)",
                        "project(RelocatedSupport LANGUAGES CXX)",
                        "find_package(Boost 1.90.0 EXACT REQUIRED COMPONENTS graph program_options)",
                        "find_package(gflags CONFIG REQUIRED)",
                        "find_package(glog CONFIG REQUIRED)",
                        "add_executable(relocation_smoke main.cc)",
                        "target_link_libraries(relocation_smoke PRIVATE Boost::graph Boost::program_options gflags glog::glog)",
                    )
                )
                + "\n",
                encoding="utf-8",
            )
            (source / "main.cc").write_text(
                "\n".join(
                    (
                        "#include <boost/program_options.hpp>",
                        "#include <gflags/gflags.h>",
                        "#include <glog/logging.h>",
                        "int main(int argc, char** argv) {",
                        "  google::InitGoogleLogging(argv[0]);",
                        '  boost::program_options::options_description options("Options");',
                        '  options.add_options()("help", "show help");',
                        "  return argc > 0 && !options.options().empty() ? 0 : 1;",
                        "}",
                    )
                )
                + "\n",
                encoding="utf-8",
            )
            result = subprocess.run(
                [
                    "cmake",
                    "-S",
                    str(source),
                    "-B",
                    str(build),
                    "-DCMAKE_FIND_USE_PACKAGE_REGISTRY=OFF",
                    "-DCMAKE_FIND_USE_SYSTEM_PACKAGE_REGISTRY=OFF",
                    f"-DCMAKE_PREFIX_PATH={moved}",
                    f"-DBoost_DIR={moved / 'lib/cmake/Boost-1.90.0'}",
                    f"-Dgflags_DIR={moved / 'lib/cmake/gflags'}",
                    f"-Dglog_DIR={moved / 'lib/cmake/glog'}",
                ],
                check=False,
                capture_output=True,
                text=True,
            )
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            result = subprocess.run(
                ["cmake", "--build", str(build), "--parallel", "2"],
                check=False,
                capture_output=True,
                text=True,
            )
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_openmp_has_only_relative_or_system_load_commands(self) -> None:
        library = self.install / "lib" / "libomp.dylib"
        dependencies = subprocess.run(
            [str(selected_xcode_tool("otool")), "-L", str(library)],
            check=True,
            capture_output=True,
            text=True,
        ).stdout.splitlines()[1:]
        names = [line.strip().split(" ", 1)[0] for line in dependencies]
        self.assertEqual(names[0], "@rpath/libomp.dylib")
        for dependency in names[1:]:
            self.assertTrue(
                dependency.startswith("/usr/lib/")
                or dependency.startswith("/System/Library/"),
                dependency,
            )
        signature = subprocess.run(
            ["/usr/bin/codesign", "--verify", "--strict", str(library)],
            check=False,
            capture_output=True,
            text=True,
        )
        self.assertEqual(signature.returncode, 0, signature.stdout + signature.stderr)

    def test_openmp_runs_from_a_relocated_prefix_without_loader_overrides(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            moved = root / "moved"
            subprocess.run(
                ["/usr/bin/ditto", str(self.install), str(moved)], check=True
            )
            source = root / "openmp-smoke.c"
            executable = moved / "bin" / "openmp-smoke"
            executable.parent.mkdir()
            source.write_text(
                "\n".join(
                    (
                        "#include <omp.h>",
                        "int main(void) {",
                        "  int workers = 0;",
                        "#pragma omp parallel reduction(+:workers)",
                        "  workers += 1;",
                        "  return workers > 0 ? 0 : 1;",
                        "}",
                    )
                )
                + "\n",
                encoding="utf-8",
            )
            environment = {
                "DEVELOPER_DIR": str(selected_developer_directory()),
                "HOME": str(root),
                "LANG": "C",
                "LC_ALL": "C",
                "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
                "TMPDIR": str(root),
            }
            compile_result = subprocess.run(
                [
                    str(selected_xcode_tool("clang")),
                    "-arch",
                    "arm64",
                    "-mmacosx-version-min=15.0",
                    "-isysroot",
                    str(selected_macos_sdk()),
                    "-Xpreprocessor",
                    "-fopenmp",
                    f"-I{moved / 'include'}",
                    str(source),
                    f"-L{moved / 'lib'}",
                    "-Wl,-rpath,@executable_path/../lib",
                    "-lomp",
                    "-o",
                    str(executable),
                ],
                check=False,
                capture_output=True,
                text=True,
                env=environment,
            )
            self.assertEqual(
                compile_result.returncode,
                0,
                compile_result.stdout + compile_result.stderr,
            )
            environment.pop("DEVELOPER_DIR")
            run_result = subprocess.run(
                [str(executable)],
                check=False,
                capture_output=True,
                text=True,
                env=environment,
            )
            self.assertEqual(
                run_result.returncode,
                0,
                run_result.stdout + run_result.stderr,
            )

    def test_receipt_matches_lock_and_final_bytes(self) -> None:
        receipt_path = self.install / "build_info.json"
        receipt = json.loads(receipt_path.read_text(encoding="utf-8"))
        lock = json.loads(LOCK.read_text(encoding="utf-8"))
        self.assertEqual(receipt["toolchain_name"], "colmap-support")
        self.assertEqual(receipt["deployment_target"], "macOS 15.0")
        self.assertNotIn("build_timestamp", receipt)
        frozen_control_digests = (
            "control_freezer_sha256",
            "builder_sha256",
            "builder_implementation_sha256",
            "promoter_sha256",
        )
        if not all(field in receipt for field in frozen_control_digests):
            self.skipTest("installed artifact predates frozen-control attestation")
        for field in frozen_control_digests:
            self.assertRegex(receipt[field], r"\A[0-9a-f]{64}\Z", field)
        self.assertEqual(receipt["source_lock_sha256"], sha256(LOCK))
        self.assertEqual(receipt["extractor_sha256"], sha256(EXTRACTOR))
        self.assertEqual(receipt["source_date_epoch"], 0)
        self.assertEqual(receipt["normalized_mtime_epoch"], NORMALIZED_MTIME_EPOCH)
        self.assertEqual(
            receipt["ownership_policy"],
            "invoking-build-user-and-primary-group",
        )
        self.assertNotIn("normalized_owner_uid", receipt)
        self.assertNotIn("normalized_owner_gid", receipt)
        self.assertEqual(
            receipt["dependencies"]["libomp"]["license"],
            "Apache-2.0 WITH LLVM-exception",
        )
        self.assertEqual(
            receipt["dependencies"]["libomp"]["license_files"],
            ["licenses/COLMAPSupport/OpenMP-LICENSE.txt"],
        )
        self.assertIn("LIBOMP_USE_ITT_NOTIFY=OFF", receipt["build_options"]["openmp"])
        self.assertEqual(
            set(receipt["build_tools"]),
            {"clang", "cmake", "macos_sdk", "ninja", "python", "ripgrep", "xcode"},
        )
        self.assertEqual(set(receipt["build_tool_sha256"]), EXPECTED_TOOL_HASH_KEYS)
        located = {name: shutil.which(name) for name in ("cmake", "ninja", "rg")}
        self.assertTrue(all(located.values()), located)
        developer = selected_developer_directory()
        tool_paths = {
            "ar": selected_xcode_tool("ar"),
            "clang": selected_xcode_tool("clang"),
            "clangxx": selected_xcode_tool("clang++"),
            "cmake": Path(located["cmake"]),
            "codesign": Path("/usr/bin/codesign"),
            "curl": Path("/usr/bin/curl"),
            "install_name_tool": selected_xcode_tool("install_name_tool"),
            "ld": selected_xcode_tool("ld"),
            "lipo": selected_xcode_tool("lipo"),
            "lockf": Path("/usr/bin/lockf"),
            "ninja": Path(located["ninja"]),
            "otool": selected_xcode_tool("otool"),
            "python": selected_xcode_tool("python3"),
            "ranlib": selected_xcode_tool("ranlib"),
            "ripgrep": Path(located["rg"]),
            "shasum": Path("/usr/bin/shasum"),
            "vtool": selected_xcode_tool("vtool"),
            "xattr": Path("/usr/bin/xattr"),
            "xcodebuild": developer / "usr/bin/xcodebuild",
            "xcrun": Path("/usr/bin/xcrun"),
        }
        self.assertEqual(
            receipt["build_tool_sha256"],
            {name: sha256(path) for name, path in sorted(tool_paths.items())},
        )
        sdk = selected_macos_sdk()
        self.assertEqual(
            receipt["macos_sdk_settings_sha256"], sha256(sdk / "SDKSettings.json")
        )
        shim_hash = sha256(Path("/usr/bin/clang"))
        for name in (
            "ar",
            "clang",
            "clangxx",
            "install_name_tool",
            "ld",
            "lipo",
            "otool",
            "python",
            "ranlib",
            "vtool",
        ):
            self.assertNotEqual(receipt["build_tool_sha256"][name], shim_hash, name)
        self.assertEqual(set(receipt["dependencies"]), set(DEPENDENCIES))
        self.assertNotIn("metis", receipt["build_options"])
        for name in DEPENDENCIES:
            expected = lock["dependencies"][name]
            actual = receipt["dependencies"][name]
            self.assertEqual(actual["source_url"], expected["source"]["url"])
            self.assertEqual(actual["source_sha256"], expected["source"]["sha256"])
            self.assertEqual(actual["source_version"], expected["version"])
            self.assertEqual(actual["license"], expected["license"])
        for relative, expected_hash in receipt["library_sha256"].items():
            self.assertEqual(sha256(self.install / relative), expected_hash)
        self.assertEqual(
            receipt["install_tree_sha256"], install_tree_digest(self.install)
        )


if __name__ == "__main__":
    unittest.main(verbosity=2)
