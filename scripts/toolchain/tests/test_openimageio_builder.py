#!/usr/bin/env python3
"""Contracts for EasySplat's static JPEG/PNG OpenImageIO closure."""

from __future__ import annotations

import fcntl
import hashlib
import io
import json
import os
import re
import shutil
import stat
import struct
import subprocess
import tarfile
import tempfile
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest import mock


ROOT = Path(__file__).resolve().parents[3]
BUILDER = ROOT / "scripts/toolchain/build_openimageio.sh"
IMPLEMENTATION = ROOT / "scripts/toolchain/build_openimageio_impl.sh"
CONTROL_FREEZER = ROOT / "scripts/toolchain/freeze_build_controls.py"
LOCK = ROOT / "scripts/toolchain/openimageio-lock.json"
EXTRACTOR = ROOT / "scripts/toolchain/safe_extract_source.py"
PROMOTER = ROOT / "scripts/toolchain/atomic_swap_install.py"
SUPPORT = ROOT / "Toolchains/build/colmap-support/install"
DEFAULT_INSTALL = ROOT / "Toolchains/build/openimageio/install"
DEPENDENCIES = (
    "openimageio",
    "fmt",
    "robin-map",
    "imath",
    "libjpeg-turbo",
    "libpng",
)
EXPECTED_VERSIONS = {
    "openimageio": "2.5.19.1+f32bf6e6f8de38ab6d197a72fd72366b66fd30a3",
    "fmt": "10.0.0",
    "robin-map": "0.6.2",
    "imath": "3.2.2",
    "libjpeg-turbo": "3.2.0",
    "libpng": "1.6.58",
}
EXPECTED_ARCHIVES = {
    "openimageio": "5de71b0e92a27b8353c901a45aaa4d99004b652f3d9a7cdba5161d99f1420ac4",
    "fmt": "2da863d7d454814286c48ef90c9b461a5d27834f026ed9472eed53bd6abbc426",
    "robin-map": "374dcfa5933eb2ae1b86123691198991bade6c4d1263e62ccc6a76f56304e1a1",
    "imath": "b4275d83fb95521510e389b8d13af10298ed5bed1c8e13efd961d91b1105e462",
    "libjpeg-turbo": "980dd81f425082aa6d7c9e47fef27554ce7a9ffc8e2f6e863b97d263c5c50858",
    "libpng": "a9d4df463d36a6e5f9c29bd6f4967312d17e996c1854f3511f833924eb1993cf",
}
NORMALIZED_MTIME_EPOCH = 946684800
CONTROL_FREEZER_BEGIN = "# EASYSPLAT_CONTROL_FREEZER_BEGIN"
CONTROL_FREEZER_END = "# EASYSPLAT_CONTROL_FREEZER_END"
FREEZER_BOOTSTRAP_BEGIN = "# EASYSPLAT_FREEZER_BOOTSTRAP_BEGIN"
FREEZER_BOOTSTRAP_END = "# EASYSPLAT_FREEZER_BOOTSTRAP_END"


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
        if stat.S_ISDIR(metadata.st_mode):
            kind, content = "directory", ""
        elif stat.S_ISREG(metadata.st_mode):
            kind, content = "file", sha256(path)
        else:
            raise AssertionError(f"unsupported install entry: {path}")
        for field in (
            relative,
            kind,
            f"{mode:o}",
            str(metadata.st_mtime_ns),
            content,
        ):
            digest.update(field.encode("utf-8"))
            digest.update(b"\0")
    return digest.hexdigest()


def normalize_fixture_ownership(root: Path) -> None:
    uid = os.getuid()
    gid = os.getgid()
    for path in [root, *root.rglob("*")]:
        os.chown(path, uid, gid, follow_symlinks=False)


def static_archive_build_targets(path: Path) -> list[tuple[int, int]]:
    data = path.read_bytes()
    if not data.startswith(b"!<arch>\n"):
        raise AssertionError(f"not a regular static archive: {path}")
    targets: list[tuple[int, int]] = []
    offset = 8
    while offset < len(data):
        header = data[offset : offset + 60]
        size = int(header[48:58].decode("ascii", "strict").strip())
        raw_name = header[:16].decode("ascii", "strict").strip()
        payload = data[offset + 60 : offset + 60 + size]
        name = raw_name.rstrip("/")
        if raw_name.startswith("#1/"):
            name_length = int(raw_name[3:])
            name = payload[:name_length].rstrip(b"\0").decode("utf-8", "strict")
            payload = payload[name_length:]
        if not name.startswith("__.SYMDEF") and name not in {"", "/", "//"}:
            _, _, _, file_type, command_count, command_bytes, _, _ = struct.unpack_from(
                "<IIIIIIII", payload, 0
            )
            if file_type != 1:
                raise AssertionError(f"archive member is not MH_OBJECT: {path}: {name}")
            command_offset = 32
            command_end = command_offset + command_bytes
            member_targets: list[tuple[int, int]] = []
            for _ in range(command_count):
                command, command_size = struct.unpack_from(
                    "<II", payload, command_offset
                )
                if command == 0x32:
                    platform, minimum_os = struct.unpack_from(
                        "<II", payload, command_offset + 8
                    )
                    member_targets.append((platform, minimum_os))
                elif command == 0x24:
                    minimum_os = struct.unpack_from("<I", payload, command_offset + 8)[
                        0
                    ]
                    member_targets.append((1, minimum_os))
                command_offset += command_size
            if command_offset != command_end or len(member_targets) != 1:
                raise AssertionError(f"invalid deployment commands: {path}: {name}")
            targets.extend(member_targets)
        offset += 60 + size
        if offset % 2:
            offset += 1
    return targets


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
            original = b'#!/bin/bash\nprintf "%s\\n" original >"$1"\n'
            implementation.write_bytes(original)
            descriptor, digest = freeze(implementation)
            try:
                implementation.write_text(
                    '#!/bin/bash\nprintf "%s\\n" replacement >"$1"\n', encoding="utf-8"
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
                self.assertEqual(digest, hashlib.sha256(original).hexdigest())
                self.assertEqual(metadata.st_nlink, 0)
                self.assertEqual(stat.S_IMODE(metadata.st_mode), 0o400)
                self.assertEqual(
                    fcntl.fcntl(descriptor, fcntl.F_GETFL) & os.O_ACCMODE, os.O_RDONLY
                )
            finally:
                os.close(descriptor)

    def test_promoter_replacement_cannot_change_cleanup_or_promotion_bytes(
        self,
    ) -> None:
        freeze, _ = load_control_freezer()
        implementation_source = IMPLEMENTATION.read_text(encoding="utf-8")
        self.assertIn("run_promoter() {", implementation_source)
        runner = extract_shell_function(implementation_source, "run_promoter")
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            promoter = root / "promoter.py"
            output = root / "operations"
            promoter.write_text(
                "from pathlib import Path\nimport sys\n"
                "with Path(sys.argv[2]).open('a', encoding='utf-8') as handle:\n"
                "    handle.write(f'original:{sys.argv[1]}\\n')\n",
                encoding="utf-8",
            )
            descriptor, digest = freeze(promoter)
            try:
                promoter.write_text(
                    "from pathlib import Path\nimport sys\n"
                    "Path(sys.argv[2]).write_text('replacement\\n', encoding='utf-8')\n",
                    encoding="utf-8",
                )
                harness = root / "promoter-harness.sh"
                harness.write_text(
                    "#!/bin/bash\nset -euo pipefail\n"
                    'FROZEN_PROMOTER_FD="$1"\nFROZEN_PROMOTER_SHA256="$2"\n'
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
            '"builder_implementation_sha256": implementation_sha256', implementation
        )
        self.assertIn('"promoter_sha256": promoter_sha256', implementation)
        for stale in (
            '"builder_sha256": file_sha256(Path(wrapper_raw))',
            '"builder_implementation_sha256": file_sha256(Path(implementation_raw))',
            '"promoter_sha256": file_sha256(Path(promoter_raw))',
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
    def sources(self) -> str:
        self.assertTrue(BUILDER.is_file(), BUILDER)
        self.assertTrue(IMPLEMENTATION.is_file(), IMPLEMENTATION)
        return BUILDER.read_text(encoding="utf-8") + IMPLEMENTATION.read_text(
            encoding="utf-8"
        )

    def test_reviewed_https_archive_lock_is_complete(self) -> None:
        lock = json.loads(LOCK.read_text(encoding="utf-8"))
        self.assertEqual(lock["schemaVersion"], 1)
        self.assertEqual(set(lock["dependencies"]), set(DEPENDENCIES))
        for name in DEPENDENCIES:
            entry = lock["dependencies"][name]
            self.assertEqual(entry["version"], EXPECTED_VERSIONS[name])
            self.assertRegex(entry["source"]["url"], r"^https://")
            self.assertEqual(entry["source"]["sha256"], EXPECTED_ARCHIVES[name])
            self.assertTrue(entry["license"])

    def test_wrapper_is_a_one_way_clean_environment_boundary(self) -> None:
        wrapper = BUILDER.read_text(encoding="utf-8")
        bootstrap = wrapper.split(FREEZER_BOOTSTRAP_BEGIN, 1)[1].split(
            FREEZER_BOOTSTRAP_END, 1
        )[0]
        executable_shell = wrapper.replace(bootstrap, "")
        self.assertTrue(os.access(BUILDER, os.X_OK))
        self.assertTrue(IMPLEMENTATION.is_file())
        self.assertFalse(os.access(IMPLEMENTATION, os.X_OK))
        for contract in (
            "builtin type -P cmake",
            "builtin type -P ninja",
            "builtin type -P rg",
            "/usr/bin/env -i",
            "/bin/bash --noprofile --norc",
            "EASYSPLAT_BOOTSTRAP_CMAKE=",
            "EASYSPLAT_BOOTSTRAP_NINJA=",
            "EASYSPLAT_BOOTSTRAP_RG=",
        ):
            self.assertIn(contract, wrapper)
        self.assertNotRegex(executable_shell, r"(?m)^\s*(?:builtin\s+)?source(?:\s|$)")
        self.assertNotRegex(executable_shell, r"(?m)^\s*(?:builtin\s+)?eval(?:\s|$)")

    def test_implementation_selects_and_binds_one_xcode_toolchain(self) -> None:
        script = self.sources()
        for contract in (
            "/usr/bin/xcode-select -p",
            "resolve_xcode_tool clang",
            "resolve_xcode_tool clang++",
            "resolve_xcode_tool ld",
            "resolve_xcode_tool ar",
            "resolve_xcode_tool ranlib",
            "resolve_xcode_tool lipo",
            "resolve_xcode_tool vtool",
            "resolve_xcode_tool python3",
            "SDKSettings.json",
            "CMAKE_C_COMPILER=",
            "CMAKE_CXX_COMPILER=",
            "CMAKE_MAKE_PROGRAM=",
            "Python3_EXECUTABLE=",
            "build_tool_sha256",
            "macos_sdk_settings_sha256",
        ):
            self.assertIn(contract, script)
        common_flags = re.search(r'^  COMMON_C_FLAGS="([^"]+)"$', script, re.MULTILINE)
        self.assertIsNotNone(common_flags)
        self.assertNotRegex(common_flags.group(1), r"-(?:mcpu|march)(?:=|\s+)native")

    def test_build_is_static_arm64_macos_15_and_format_minimal(self) -> None:
        script = self.sources()
        for contract in (
            "CMAKE_OSX_ARCHITECTURES=arm64",
            "CMAKE_OSX_DEPLOYMENT_TARGET=15.0",
            "BUILD_SHARED_LIBS=OFF",
            "LINKSTATIC=ON",
            "EMBEDPLUGINS=ON",
            "ENABLE_JPEG=ON",
            "ENABLE_PNG=ON",
            "USE_OPENEXR=OFF",
            "USE_TIFF=OFF",
            "OIIO_BUILD_TOOLS=OFF",
            "OIIO_BUILD_TESTS=OFF",
            "USE_PYTHON=OFF",
            "PNG_SHARED=OFF",
            "PNG_STATIC=ON",
            "ENABLE_SHARED=OFF",
            "ENABLE_STATIC=ON",
            "WITH_TOOLS=OFF",
            "IMATH_INSTALL_PKG_CONFIG=OFF",
            "set (USE_TIFF OFF CACHE BOOL",
            "set (USE_OPENEXR OFF CACHE BOOL",
            "set (ENABLE_JPEG ON CACHE BOOL",
            "set (ENABLE_PNG ON CACHE BOOL",
            "ZERO_AR_DATE=1",
            "SOURCE_DATE_EPOCH=0",
            "-ffile-prefix-map=",
            "-fdebug-prefix-map=",
        ):
            self.assertIn(contract, script)
        self.assertIn("required_plugins = {'jpeg.imageio', 'png.imageio'}", script)

    def test_jpeg_exif_support_uses_an_internal_tiff_free_abi(self) -> None:
        script = self.sources()
        for contract in (
            "install_tiff_free_exif_compatibility",
            "enum TIFFDataType",
            "#define TIFF_VERSION_BIG 43",
            "TIFFTAG_ORIENTATION = 274",
            "TIFFTAG_EXIFIFD = 34665",
            "TIFFTAG_GPSIFD = 34853",
            "TIFFTAG_INTEROPERABILITYIFD = 40965",
            "TIFF-free EXIF compatibility types",
            "reviewed xmp.cpp redundant libtiff include changed upstream",
        ):
            self.assertIn(contract, script)

    def test_no_homebrew_registry_clone_or_dynamic_runtime_surface(self) -> None:
        script = self.sources()
        for forbidden in (
            "brew --prefix",
            "git clone",
            "git fetch",
            "BUILD_SHARED_LIBS=ON",
            "LINKSTATIC=OFF",
            "USE_TIFF=ON",
            "USE_OPENEXR=ON",
            "pkg-config --",
        ):
            self.assertNotIn(forbidden, script)
        for contract in (
            "CMAKE_FIND_USE_PACKAGE_REGISTRY=OFF",
            "CMAKE_FIND_USE_SYSTEM_PACKAGE_REGISTRY=OFF",
            "CMAKE_FIND_USE_CMAKE_ENVIRONMENT_PATH=OFF",
            "PKG_CONFIG_LIBDIR=/dev/null",
            "safe_extract_source.py",
            "--proto '=https'",
            "link_dependency_fields =",
        ):
            self.assertIn(contract, script)
        self.assertNotRegex(
            script,
            r"RG_BIN.*build\.ninja.*compile_commands\.json",
        )

    def test_support_prefix_is_verified_but_not_copied(self) -> None:
        script = self.sources()
        for contract in (
            "colmap-support/install",
            "support_receipt_sha256",
            "support_install_tree_sha256",
            "verify_support_prefix",
            "libboost_thread.a",
            "Boost_NO_BOOST_CMAKE",
        ):
            self.assertIn(contract, script)
        self.assertNotRegex(script, r"cp .*(?:include/boost|libboost)")

    def test_download_staging_normalization_and_atomic_promotion_fail_closed(
        self,
    ) -> None:
        script = self.sources()
        for contract in (
            "install.stage.",
            ".build.lock",
            '"$LOCKF_BIN" -s -t 0 9',
            '"$SHASUM_BIN" -a 256',
            "safe_extract_source.py",
            "atomic_swap_install.py",
            "normalize_install_metadata",
            "install_tree_sha256",
            "validate_receipt",
            "validate_static_archive",
            "compare_reproducibility",
        ):
            self.assertIn(contract, script)
        self.assertNotIn("install.previous.", script)

    def test_pruning_preserves_the_promoter_owned_stage_root(self) -> None:
        script = self.sources()
        function = re.search(
            r"^prune_install\(\) \{\n(.*?)^\}\n\nstage_licenses",
            script,
            re.MULTILINE | re.DOTALL,
        )
        self.assertIsNotNone(function)
        body = function.group(1)
        self.assertIn('"$INSTALL_STAGE_DEVICE"', body)
        self.assertIn('"$INSTALL_STAGE_INODE"', body)
        self.assertIn("os.O_NOFOLLOW", body)
        self.assertIn("dir_fd=source_fd", body)
        self.assertIn("os.rename(", body)
        self.assertNotIn("shutil.rmtree(source)", body)
        self.assertNotIn("destination.replace(source)", body)

    def test_normalization_overrides_parent_directory_ownership(self) -> None:
        script = self.sources()
        self.assertIn('current_uid="$(/usr/bin/id -u)"', script)
        self.assertIn('current_gid="$(/usr/bin/id -g)"', script)
        self.assertIn('"$CHOWN_BIN" -R "$current_uid:$current_gid" "$STAGE"', script)

    def test_archive_validation_binds_every_member_to_macos_15(self) -> None:
        script = self.sources()
        for contract in (
            "LC_VERSION_MIN_MACOSX = 0x24",
            "LC_BUILD_VERSION = 0x32",
            "PLATFORM_MACOS = 1",
            "EXPECTED_MINIMUM_OS = 15 << 16",
            "archive member has no deployment command",
        ):
            self.assertIn(contract, script)

    def test_failed_post_promotion_restore_is_never_swallowed(self) -> None:
        script = self.sources()
        function = re.search(
            r"^promote_install\(\) \{\n(.*?)^\}\n",
            script,
            re.MULTILINE | re.DOTALL,
        )
        self.assertIsNotNone(function)
        body = function.group(1)
        self.assertNotIn("|| true", body)
        self.assertIn("STAGE_CLEANUP_ALLOWED=0", body)
        self.assertGreater(
            body.index("STAGE_CLEANUP_ALLOWED=0"),
            body.index("--tree-receipt"),
        )
        self.assertLess(
            body.index("STAGE_CLEANUP_ALLOWED=0"),
            body.index('run_promoter "$STAGE"'),
        )
        self.assertIn("run_promoter --recover", body)
        self.assertIn("run_promoter --commit", body)
        self.assertNotIn('"$PROMOTER"', body)
        self.assertIn("rollback failed", body)

    def test_receipt_is_deterministic_and_metadata_complete(self) -> None:
        script = self.sources()
        for contract in (
            "builder_sha256",
            "builder_implementation_sha256",
            "source_lock_sha256",
            "extractor_sha256",
            "promoter_sha256",
            "tests_sha256",
            "source_url",
            "source_sha256",
            "source_version",
            "license_files",
            "library_sha256",
            "enabled_formats",
            "static",
            "architecture",
            "deployment_target",
            "normalized_mtime_epoch",
            "build_options",
            "dependencies",
        ):
            self.assertIn(contract, script)
        self.assertNotIn("datetime.now", script)
        self.assertNotIn("build_timestamp", script)

    def test_receipt_identity_is_independent_of_the_build_account(self) -> None:
        script = self.sources()
        receipt_contract = extract_shell_function(script, "receipt_contract")
        self.assertIn(
            '"ownership_policy": "invoking-build-user-and-primary-group"',
            receipt_contract,
        )
        self.assertNotRegex(receipt_contract, r'"normalized_owner_(?:uid|gid)"\s*:')
        self.assertNotIn("metadata.st_uid", receipt_contract)
        self.assertNotIn("metadata.st_gid", receipt_contract)

    def test_consumer_and_plugin_audits_are_executable_build_gates(self) -> None:
        script = self.sources()
        for contract in (
            "install_minimal_embedded_plugin_catalog",
            "PLUGENTRY(jpeg);\nPLUGENTRY(png);",
            "DECLAREPLUG (jpeg);\n    DECLAREPLUG (png);",
            '"$NM_BIN" -g -U -C',
            "find_package(OpenImageIO CONFIG REQUIRED)",
            "OpenImageIO::OpenImageIO",
            "jpeg_input_imageio_create",
            "jpeg_output_imageio_create",
            "png_input_imageio_create",
            "png_output_imageio_create",
            "tiff_input_imageio_create",
            "OpenEXR",
            "ImageOutput::create",
            "ImageInput::open",
            "OIIO::geterror()",
            "smoke-consumer-relocated",
            "vtool",
        ):
            self.assertIn(contract, script)

    def test_smoke_reads_apple_imageio_exif_metadata_independently(self) -> None:
        script = self.sources()
        for contract in (
            "<ImageIO/ImageIO.h>",
            "CGImageDestinationCreateWithURL",
            "kCGImagePropertyOrientation",
            "kCGImagePropertyTIFFMake",
            "kCGImagePropertyTIFFModel",
            "kCGImagePropertyExifFocalLength",
            'get_string_attribute("Make")',
            'get_string_attribute("Model")',
            'get_float_attribute("Exif:FocalLength"',
            "apple_imageio_metadata_interop",
        ):
            self.assertIn(contract, script)

    def test_validate_only_is_authoritative_and_never_builds_or_promotes(self) -> None:
        script = self.sources()
        self.assertIn("--validate-only", script)
        branch = re.search(
            r"^  validate\)\n(.*?)^    ;;$", script, re.MULTILINE | re.DOTALL
        )
        self.assertIsNotNone(branch)
        body = branch.group(1)
        for required in ("validate_install_prefix", "run_relocated_consumer"):
            self.assertIn(required, body)
        for forbidden in (
            "download_verified",
            "prepare_sources",
            "build_openimageio",
            "promote_install",
        ):
            self.assertNotIn(forbidden, body)

    def test_build_gate_runs_the_complete_builder_suite_against_staging(self) -> None:
        script = self.sources()
        branch = re.search(
            r"^  build\)\n(.*?)^    ;;$", script, re.MULTILINE | re.DOTALL
        )
        self.assertIsNotNone(branch)
        body = branch.group(1)
        self.assertIn('EASYSPLAT_OPENIMAGEIO_ROOT="$STAGE"', body)
        self.assertIn('"$PYTHON_BIN" "$TESTS"', body)
        self.assertNotIn('"$TESTS" ArtifactTests', body)

    def test_build_and_validation_scratch_is_process_private(self) -> None:
        script = self.sources()
        self.assertIn(
            'SCRATCH="$(/usr/bin/mktemp -d "$WORK/scratch.XXXXXXXX")"', script
        )
        self.assertIn('BUILD_HOME="$SCRATCH/home"', script)
        self.assertIn('BUILD_TMP="$SCRATCH/tmp"', script)
        self.assertIn('rm -rf -- "$SCRATCH"', script)
        self.assertNotIn('local smoke_root="$WORK/smoke-consumer-relocated"', script)

    def test_sanitizer_removes_caller_build_and_loader_influence(self) -> None:
        script = self.sources()
        for variable in (
            "BASH_ENV",
            "CMAKE_PROJECT_INCLUDE",
            "CMAKE_TOOLCHAIN_FILE",
            "CPATH",
            "DYLD_INSERT_LIBRARIES",
            "DYLD_LIBRARY_PATH",
            "MAKEFLAGS",
            "PKG_CONFIG_PATH",
            "PYTHONPATH",
            "SDKROOT",
        ):
            self.assertIn(variable, script)
        self.assertIn("builtin declare -F", script)
        self.assertIn("builtin unalias -a", script)


class WrapperHostileEnvironmentTests(unittest.TestCase):
    def test_exported_functions_and_forged_bootstrap_values_cannot_cross_wrapper(
        self,
    ) -> None:
        wrapper = BUILDER.read_text(encoding="utf-8")
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            copied_wrapper = root / BUILDER.name
            copied_impl = root / IMPLEMENTATION.name
            copied_freezer = root / CONTROL_FREEZER.name
            copied_promoter = root / PROMOTER.name
            copied_wrapper.write_text(wrapper, encoding="utf-8")
            copied_wrapper.chmod(0o755)
            copied_impl.write_text(
                "#!/bin/bash\n"
                "set -euo pipefail\n"
                "builtin declare -F\n"
                "/usr/bin/env | /usr/bin/sort\n"
                "builtin printf 'args=%s\\n' \"$*\"\n",
                encoding="utf-8",
            )
            copied_impl.chmod(0o644)
            shutil.copyfile(CONTROL_FREEZER, copied_freezer)
            copied_freezer.chmod(0o644)
            shutil.copyfile(PROMOTER, copied_promoter)
            copied_promoter.chmod(0o755)
            environment = dict(os.environ)
            environment.update(
                {
                    "EASYSPLAT_BOOTSTRAP_CMAKE": "/tmp/forged-cmake",
                    "EASYSPLAT_BOOTSTRAP_NINJA": "/tmp/forged-ninja",
                    "EASYSPLAT_BOOTSTRAP_RG": "/tmp/forged-rg",
                    "BASH_FUNC_cmake%%": "() { echo forged; }",
                    "DYLD_INSERT_LIBRARIES": "/tmp/forged.dylib",
                    "CMAKE_PROJECT_INCLUDE": "/tmp/forged.cmake",
                }
            )
            result = subprocess.run(
                [str(copied_wrapper), "--validate-only", "/tmp/example"],
                capture_output=True,
                text=True,
                env=environment,
                check=True,
            )
            self.assertNotIn("forged", result.stdout)
            self.assertNotIn("DYLD_", result.stdout)
            self.assertNotIn("CMAKE_PROJECT_INCLUDE", result.stdout)
            self.assertRegex(result.stdout, r"EASYSPLAT_BOOTSTRAP_CMAKE=/.*cmake")
            self.assertRegex(result.stdout, r"EASYSPLAT_BOOTSTRAP_NINJA=/.*ninja")
            self.assertRegex(result.stdout, r"EASYSPLAT_BOOTSTRAP_RG=/.*rg")
            self.assertIn("args=--validate-only /tmp/example", result.stdout)


class ArchiveSafetyTests(unittest.TestCase):
    def run_extractor(
        self, archive: Path, destination: Path
    ) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            ["/usr/bin/python3", str(EXTRACTOR), str(archive), str(destination)],
            capture_output=True,
            text=True,
        )

    def test_safe_single_root_archive_extracts(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            archive = root / "source.tar.gz"
            output = root / "out"
            output.mkdir()
            with tarfile.open(archive, "w:gz") as handle:
                directory = tarfile.TarInfo("source")
                directory.type = tarfile.DIRTYPE
                directory.mode = 0o755
                handle.addfile(directory)
                info = tarfile.TarInfo("source/LICENSE")
                payload = b"license\n"
                info.size = len(payload)
                info.mode = 0o644
                handle.addfile(info, io.BytesIO(payload))
            result = self.run_extractor(archive, output)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(
                (Path(result.stdout.strip()) / "LICENSE").read_bytes(), b"license\n"
            )

    def test_traversal_and_escaping_symlink_are_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            for name, member in (
                ("traversal", "source/../../escape"),
                ("symlink", "source/link"),
            ):
                archive = root / f"{name}.tar.gz"
                output = root / f"out-{name}"
                output.mkdir()
                with tarfile.open(archive, "w:gz") as handle:
                    if name == "traversal":
                        info = tarfile.TarInfo(member)
                        info.size = 1
                        handle.addfile(info, io.BytesIO(b"x"))
                    else:
                        info = tarfile.TarInfo(member)
                        info.type = tarfile.SYMTYPE
                        info.linkname = "../../escape"
                        handle.addfile(info)
                self.assertNotEqual(self.run_extractor(archive, output).returncode, 0)


class AtomicPromotionTests(unittest.TestCase):
    def test_pruning_execution_preserves_owned_root_identity(self) -> None:
        script = IMPLEMENTATION.read_text(encoding="utf-8")
        function = re.search(
            r"^prune_install\(\) \{\n(.*?)^\}\n\nstage_licenses",
            script,
            re.MULTILINE | re.DOTALL,
        )
        self.assertIsNotNone(function)
        program = re.search(
            r"<<'PY'\n(.*?)\nPY$",
            function.group(1),
            re.MULTILINE | re.DOTALL,
        )
        self.assertIsNotNone(program)
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            stage = root / "install.stage"
            pruned = root / "install.pruned"
            (stage / "include/OpenImageIO").mkdir(parents=True)
            (stage / "include/OpenImageIO/imageio.h").write_text(
                "fixture\n", encoding="utf-8"
            )
            (stage / "lib").mkdir()
            for name in (
                "libOpenImageIO.a",
                "libOpenImageIO_Util.a",
                "libImath-3_2.a",
                "libjpeg.a",
                "libpng16.a",
            ):
                (stage / "lib" / name).write_bytes(name.encode("ascii"))
            (stage / "unwanted").write_text("remove me\n", encoding="utf-8")
            before = stage.lstat()
            result = subprocess.run(
                [
                    "/usr/bin/python3",
                    "-",
                    str(stage),
                    str(pruned),
                    str(before.st_dev),
                    str(before.st_ino),
                ],
                input=program.group(1),
                capture_output=True,
                text=True,
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            after = stage.lstat()
            self.assertEqual(
                (after.st_dev, after.st_ino),
                (before.st_dev, before.st_ino),
            )
            self.assertFalse((stage / "unwanted").exists())
            self.assertTrue((stage / "include/OpenImageIO/imageio.h").is_file())
            self.assertTrue((stage / "lib/libOpenImageIO.a").is_file())
            self.assertTrue(
                (stage / "lib/cmake/OpenImageIO/OpenImageIOConfig.cmake").is_file()
            )
            self.assertFalse(pruned.exists())

    def test_failed_promotion_restores_previous_install(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            staged = root / "stage"
            live = root / "install"
            staged.mkdir()
            live.mkdir()
            (staged / "value").write_text("new", encoding="utf-8")
            (live / "value").write_text("old", encoding="utf-8")
            (staged / "unsafe").symlink_to("value")
            result = subprocess.run(
                [
                    "/usr/bin/python3",
                    str(PROMOTER),
                    str(staged),
                    str(live),
                    "tree-v1:" + ("0" * 64),
                ],
                capture_output=True,
                text=True,
            )
            self.assertNotEqual(result.returncode, 0)
            self.assertEqual((live / "value").read_text(encoding="utf-8"), "old")

    def test_post_promotion_restore_failure_preserves_old_install_for_recovery(
        self,
    ) -> None:
        script = IMPLEMENTATION.read_text(encoding="utf-8")
        runner = extract_shell_function(script, "run_promoter")
        function = re.search(
            r"(^promote_install\(\) \{\n.*?^\})\n",
            script,
            re.MULTILINE | re.DOTALL,
        )
        self.assertIsNotNone(function)
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            stage = root / "stage"
            live = root / "install"
            stage.mkdir()
            live.mkdir()
            (stage / "value").write_text("new", encoding="utf-8")
            (live / "value").write_text("old", encoding="utf-8")
            counter = root / "promoter-count"
            promoter = root / "promoter.py"
            promoter.write_text(
                "import os\n"
                "import sys\n"
                "from pathlib import Path\n"
                "arguments = sys.argv[1:]\n"
                "if arguments[0] == '--tree-receipt':\n"
                "    print('tree-v1:' + ('0' * 64))\n"
                "    raise SystemExit(0)\n"
                "counter = Path(os.environ['PROMOTER_COUNTER'])\n"
                "count = int(counter.read_text()) if counter.exists() else 0\n"
                "counter.write_text(str(count + 1))\n"
                "if arguments[0] == '--recover':\n"
                "    raise SystemExit(1)\n"
                "if arguments[0] == '--commit':\n"
                "    raise SystemExit(0)\n"
                "stage, live = map(Path, arguments[:2])\n"
                "temporary = stage.with_name('swap-temporary')\n"
                "stage.rename(temporary)\n"
                "live.rename(stage)\n"
                "temporary.rename(live)\n",
                encoding="utf-8",
            )
            freeze, _ = load_control_freezer()
            descriptor, digest = freeze(promoter)
            try:
                harness = root / "harness.sh"
                harness.write_text(
                    "#!/bin/bash\n"
                    "set -u\n"
                    f"STAGE={stage!s}\n"
                    f"INSTALL={live!s}\n"
                    f"FROZEN_PROMOTER_FD={descriptor}\n"
                    f"FROZEN_PROMOTER_SHA256={digest}\n"
                    f"PROMOTER_COUNTER={counter!s}\n"
                    "export PROMOTER_COUNTER\n"
                    "STAGE_CLEANUP_ALLOWED=1\n"
                    f"INSTALL_STAGE_DEVICE={stage.lstat().st_dev}\n"
                    f"INSTALL_STAGE_INODE={stage.lstat().st_ino}\n"
                    'trap \'status=$?; printf "status=%s cleanup=%s\\\\n" "$status" "$STAGE_CLEANUP_ALLOWED"\' EXIT\n'
                    "die() { printf 'error=%s\\n' \"$*\"; exit 1; }\n"
                    "validate_install_prefix() { return 1; }\n"
                    f"{runner}\n"
                    f"{function.group(1)}\n"
                    "promote_install\n",
                    encoding="utf-8",
                )
                result = subprocess.run(
                    ["/bin/bash", "--noprofile", "--norc", str(harness)],
                    capture_output=True,
                    text=True,
                    pass_fds=(descriptor,),
                )
            finally:
                os.close(descriptor)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("rollback failed", result.stdout)
            self.assertIn("cleanup=0", result.stdout)
            self.assertNotIn("previous state restored", result.stdout)
            self.assertEqual((stage / "value").read_text(encoding="utf-8"), "old")
            self.assertEqual((live / "value").read_text(encoding="utf-8"), "new")


class ArtifactTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        explicit = os.environ.get("EASYSPLAT_OPENIMAGEIO_ROOT")
        if not explicit and DEFAULT_INSTALL.is_dir():
            explicit = str(DEFAULT_INSTALL)
        if not explicit:
            raise unittest.SkipTest(
                "set EASYSPLAT_OPENIMAGEIO_ROOT to validate an artifact"
            )
        cls.install = Path(explicit).resolve()
        cls.receipt = json.loads(
            (cls.install / "build_info.json").read_text(encoding="utf-8")
        )

    def test_receipt_and_tree_bind_final_bytes(self) -> None:
        self.assertEqual(self.receipt["schema_version"], 1)
        self.assertEqual(self.receipt["toolchain_name"], "openimageio-static")
        self.assertEqual(self.receipt["architecture"], "arm64")
        self.assertEqual(self.receipt["deployment_target"], "macOS 15.0")
        self.assertEqual(self.receipt["enabled_formats"], ["JPEG", "PNG"])
        self.assertEqual(self.receipt["linkage"], "static")
        self.assertEqual(
            self.receipt["ownership_policy"],
            "invoking-build-user-and-primary-group",
        )
        self.assertNotIn("normalized_owner_uid", self.receipt)
        self.assertNotIn("normalized_owner_gid", self.receipt)
        self.assertTrue(self.receipt["smoke_test"]["jpeg_exif_orientation_roundtrip"])
        self.assertTrue(self.receipt["smoke_test"]["apple_imageio_metadata_interop"])
        self.assertEqual(
            self.receipt["install_tree_sha256"], install_tree_digest(self.install)
        )
        for relative, expected in self.receipt["library_sha256"].items():
            self.assertEqual(sha256(self.install / relative), expected)

    def test_install_surface_is_static_relocatable_and_canonical(self) -> None:
        self.assertTrue((self.install / "include/OpenImageIO/imageio.h").is_file())
        self.assertTrue(
            (self.install / "lib/cmake/OpenImageIO/OpenImageIOConfig.cmake").is_file()
        )
        self.assertTrue((self.install / "lib/libOpenImageIO.a").is_file())
        self.assertTrue((self.install / "lib/libOpenImageIO_Util.a").is_file())
        for path in [self.install, *self.install.rglob("*")]:
            metadata = path.lstat()
            self.assertFalse(path.is_symlink(), path)
            self.assertIn(stat.S_IFMT(metadata.st_mode), {stat.S_IFDIR, stat.S_IFREG})
            expected_mode = 0o755 if path.is_dir() else 0o644
            self.assertEqual(stat.S_IMODE(metadata.st_mode), expected_mode, path)
            self.assertEqual(
                (metadata.st_uid, metadata.st_gid),
                (os.getuid(), os.getgid()),
                path,
            )
            self.assertEqual(
                metadata.st_mtime_ns, NORMALIZED_MTIME_EPOCH * 1_000_000_000, path
            )
        forbidden = {
            "bin",
            "doc",
            "docs",
            "man",
            "plugins",
            "pkgconfig",
            "python",
            "share",
        }
        self.assertFalse(
            any(
                part.lower() in forbidden
                for path in self.install.rglob("*")
                for part in path.parts
            )
        )
        self.assertFalse(list(self.install.rglob("*.dylib")))
        self.assertFalse(list(self.install.rglob("*.so")))

    def test_public_exif_header_has_no_libtiff_dependency(self) -> None:
        header = (self.install / "include/OpenImageIO/tiffutils.h").read_text(
            encoding="utf-8"
        )
        self.assertNotIn('#include "tiff.h"', header)
        self.assertIn("enum TIFFDataType", header)
        self.assertIn("TIFFTAG_ORIENTATION = 274", header)

    def test_no_build_or_private_host_paths_survive(self) -> None:
        forbidden = re.compile(rb"/(?:Users|private/tmp|opt/homebrew)/")
        for path in self.install.rglob("*"):
            if path.is_file():
                self.assertIsNone(forbidden.search(path.read_bytes()), path)

    def test_static_archive_architectures_and_plugin_factories(self) -> None:
        developer = subprocess.run(
            ["/usr/bin/xcode-select", "-p"], check=True, capture_output=True, text=True
        ).stdout.strip()
        environment = {"DEVELOPER_DIR": developer}
        lipo = subprocess.run(
            ["/usr/bin/xcrun", "--find", "lipo"],
            check=True,
            capture_output=True,
            text=True,
            env=environment,
        ).stdout.strip()
        nm = subprocess.run(
            ["/usr/bin/xcrun", "--find", "nm"],
            check=True,
            capture_output=True,
            text=True,
            env=environment,
        ).stdout.strip()
        for archive in self.install.glob("lib/*.a"):
            architectures = subprocess.run(
                [lipo, "-archs", str(archive)],
                check=True,
                capture_output=True,
                text=True,
            ).stdout.strip()
            self.assertEqual(architectures, "arm64", archive)
            targets = static_archive_build_targets(archive)
            self.assertTrue(targets, archive)
            self.assertEqual(set(targets), {(1, 15 << 16)}, archive)
        symbols = subprocess.run(
            [nm, "-g", "-U", "-C", str(self.install / "lib/libOpenImageIO.a")],
            check=True,
            capture_output=True,
            text=True,
        ).stdout
        factories = set(
            re.findall(
                r"\b([a-z][a-z0-9]*_(?:input|output)_imageio_create)\(\)", symbols
            )
        )
        self.assertEqual(
            factories,
            {
                "jpeg_input_imageio_create",
                "jpeg_output_imageio_create",
                "png_input_imageio_create",
                "png_output_imageio_create",
            },
        )


class ReceiptMutationTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        explicit = os.environ.get("EASYSPLAT_OPENIMAGEIO_ROOT")
        if not explicit and DEFAULT_INSTALL.is_dir():
            explicit = str(DEFAULT_INSTALL)
        if not explicit:
            raise unittest.SkipTest(
                "set EASYSPLAT_OPENIMAGEIO_ROOT to exercise receipt mutation"
            )
        cls.install = Path(explicit).resolve()

    def validate(self, prefix: Path) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            [str(BUILDER), "--validate-only", str(prefix)],
            capture_output=True,
            text=True,
        )

    def test_tree_library_receipt_and_provenance_mutations_are_rejected(self) -> None:
        for mutation in (
            "header",
            "library",
            "receipt",
            "ownership-policy",
            "numeric-owner",
            "source-lock",
            "support-tree",
        ):
            with tempfile.TemporaryDirectory() as temporary:
                candidate = Path(temporary) / mutation
                shutil.copytree(self.install, candidate)
                normalize_fixture_ownership(candidate)
                if mutation == "header":
                    header = candidate / "include/OpenImageIO/imageio.h"
                    header.write_bytes(header.read_bytes() + b"\n// forged\n")
                    mutated_path = header
                elif mutation == "library":
                    library = candidate / "lib/libOpenImageIO.a"
                    library.write_bytes(library.read_bytes() + b"forged")
                    mutated_path = library
                else:
                    receipt_path = candidate / "build_info.json"
                    receipt = json.loads(receipt_path.read_text(encoding="utf-8"))
                    if mutation == "receipt":
                        receipt["enabled_formats"] = ["JPEG", "PNG", "TIFF"]
                    elif mutation == "ownership-policy":
                        receipt["ownership_policy"] = "numeric-owner-encoded"
                    elif mutation == "numeric-owner":
                        receipt["normalized_owner_gid"] = 20
                    elif mutation == "source-lock":
                        receipt["source_lock_sha256"] = "0" * 64
                    else:
                        receipt["support_install_tree_sha256"] = "0" * 64
                    receipt_path.write_text(
                        json.dumps(receipt, sort_keys=True) + "\n", encoding="utf-8"
                    )
                    mutated_path = receipt_path
                os.utime(
                    mutated_path,
                    ns=(
                        NORMALIZED_MTIME_EPOCH * 1_000_000_000,
                        NORMALIZED_MTIME_EPOCH * 1_000_000_000,
                    ),
                    follow_symlinks=False,
                )
                result = self.validate(candidate)
                self.assertNotEqual(result.returncode, 0, mutation)
                self.assertIn(
                    "build_info.json does not match reconstructed contract",
                    result.stdout + result.stderr,
                    mutation,
                )


class PortableTreeIdentityTests(unittest.TestCase):
    def test_normalized_tree_digest_ignores_simulated_numeric_ownership(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary) / "install"
            root.mkdir()
            payload = root / "payload.bin"
            payload.write_bytes(b"portable payload\n")
            os.chmod(root, 0o700)
            os.chmod(payload, 0o600)
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


if __name__ == "__main__":
    unittest.main()
