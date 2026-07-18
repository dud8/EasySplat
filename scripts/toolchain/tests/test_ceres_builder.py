#!/usr/bin/env python3
"""Contracts and artifact checks for the portable Ceres build."""

from __future__ import annotations

import hashlib
import importlib.util
import json
import os
import shutil
import stat
import subprocess
import tarfile
import tempfile
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest import mock


ROOT = Path(__file__).resolve().parents[3]
BUILDER = ROOT / "scripts/toolchain/build_ceres.sh"
IMPLEMENTATION = ROOT / "scripts/toolchain/build_ceres_impl.sh"
LOCK = ROOT / "scripts/toolchain/ceres-lock.json"
EXTRACTOR = ROOT / "scripts/toolchain/safe_extract_source.py"
PROMOTER = ROOT / "scripts/toolchain/atomic_swap_install.py"
SUPPORT = ROOT / "Toolchains/build/colmap-support/install"
INSTALL = ROOT / "Toolchains/build/ceres/install"
EXPECTED = {
    "ceres": {
        "version": "2.2.0",
        "commit": "85331393dc0dff09f6fb9903ab0c4bfa3e134b01",
        "sha256": "4cdd9f11f5afb34f8c9a043396a574b4a0a888f866710e7d65acb5b88ce64bcb",
        "license": "BSD-3-Clause",
    },
    "eigen": {
        "version": "3.4.0",
        "commit": "3147391d946bb4b6c68edd901f2add6ac1f31f8c",
        "sha256": "0c8c490764f9c2a793133491adca0cd073b73e0bde965c68cbe58d91b5ed4261",
        "license": "MPL-2.0",
    },
}


def load_module(name: str, path: Path):
    spec = importlib.util.spec_from_file_location(name, path)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"could not load {path}")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for block in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def tree_digest(root: Path, *, exclude_receipt: bool = True) -> str:
    digest = hashlib.sha256()
    paths = [
        root,
        *sorted(root.rglob("*"), key=lambda item: item.relative_to(root).as_posix()),
    ]
    for path in paths:
        relative = "." if path == root else path.relative_to(root).as_posix()
        if exclude_receipt and relative == "build_info.json":
            continue
        metadata = path.lstat()
        mode = stat.S_IMODE(metadata.st_mode)
        if stat.S_ISDIR(metadata.st_mode):
            kind, content = "directory", ""
        elif stat.S_ISREG(metadata.st_mode):
            kind, content = "file", sha256(path)
        else:
            raise AssertionError(f"unsupported install entry: {relative}")
        for value in (relative, kind, f"{mode:o}", str(metadata.st_mtime_ns), content):
            digest.update(value.encode())
            digest.update(b"\0")
    return digest.hexdigest()


class SourceContractTests(unittest.TestCase):
    def source(self) -> str:
        self.assertTrue(BUILDER.is_file(), BUILDER)
        self.assertTrue(IMPLEMENTATION.is_file(), IMPLEMENTATION)
        return (
            BUILDER.read_text(encoding="utf-8")
            + "\n"
            + IMPLEMENTATION.read_text(encoding="utf-8")
        )

    def test_reviewed_source_lock_is_exact(self) -> None:
        lock = json.loads(LOCK.read_text(encoding="utf-8"))
        self.assertEqual(lock["schemaVersion"], 1)
        self.assertEqual(set(lock["dependencies"]), set(EXPECTED))
        for name, expected in EXPECTED.items():
            dependency = lock["dependencies"][name]
            self.assertEqual(dependency["version"], expected["version"])
            self.assertEqual(dependency["commit"], expected["commit"])
            self.assertEqual(dependency["license"], expected["license"])
            self.assertRegex(dependency["source"]["url"], r"^https://")
            self.assertEqual(dependency["source"]["sha256"], expected["sha256"])

    def test_wrapper_is_one_way_and_ignores_hostile_shell_state(self) -> None:
        wrapper = BUILDER.read_text(encoding="utf-8")
        for contract in (
            "builtin type -P cmake",
            "builtin type -P ninja",
            "builtin type -P rg",
            "exec /usr/bin/env -i",
            "/bin/bash --noprofile --norc",
            "build_ceres_impl.sh",
        ):
            self.assertIn(contract, wrapper)
        self.assertNotIn("EASYSPLAT_HERMETIC_BUILD", wrapper)

        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            script_dir = root / "scripts/toolchain"
            tools = root / "tools"
            script_dir.mkdir(parents=True)
            tools.mkdir()
            copied = script_dir / BUILDER.name
            shutil.copy2(BUILDER, copied)
            output = root / "environment.json"
            stub = script_dir / IMPLEMENTATION.name
            stub.write_text(
                "#!/bin/bash\n"
                "/usr/bin/python3 - \"$1\" <<'PY'\n"
                "import json, os, sys\n"
                "json.dump(dict(os.environ), open(sys.argv[1], 'w'))\n"
                "PY\n",
                encoding="utf-8",
            )
            for name in ("cmake", "ninja", "rg"):
                path = tools / name
                path.write_text("#!/bin/sh\nexit 0\n", encoding="utf-8")
                path.chmod(0o755)
            environment = os.environ.copy()
            environment.update(
                {
                    "PATH": f"{tools}:/usr/bin:/bin:/usr/sbin:/sbin",
                    "BASH_FUNC_cmake%%": "() { exit 86; }",
                    "EASYSPLAT_BOOTSTRAP_CMAKE": "/private/tmp/forged-cmake",
                    "CMAKE_TOOLCHAIN_FILE": "/private/tmp/hostile.cmake",
                    "DYLD_INSERT_LIBRARIES": "/private/tmp/hostile.dylib",
                }
            )
            result = subprocess.run(
                [str(copied), str(output)],
                check=False,
                capture_output=True,
                text=True,
                env=environment,
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            received = json.loads(output.read_text(encoding="utf-8"))
            self.assertEqual(
                received["EASYSPLAT_BOOTSTRAP_CMAKE"], str(tools / "cmake")
            )
            self.assertNotIn("CMAKE_TOOLCHAIN_FILE", received)
            self.assertNotIn("DYLD_INSERT_LIBRARIES", received)
            self.assertFalse(any(key.startswith("BASH_FUNC_") for key in received))

    def test_impl_is_non_executable_and_uses_pinned_xcode_tools(self) -> None:
        source = self.source()
        self.assertFalse(os.access(IMPLEMENTATION, os.X_OK))
        for contract in (
            'CMAKE_BIN="$BOOTSTRAP_CMAKE_BIN"',
            'NINJA_BIN="$BOOTSTRAP_NINJA_BIN"',
            'RG_BIN="$BOOTSTRAP_RG_BIN"',
            'XCODE_DEVELOPER_DIR="$(/usr/bin/xcode-select -p)"',
            "resolve_xcode_tool clang",
            "resolve_xcode_tool clang++",
            "resolve_xcode_tool ar",
            "resolve_xcode_tool ranlib",
            "resolve_xcode_tool lipo",
            "resolve_xcode_tool vtool",
            "--show-sdk-path",
            "--show-sdk-version",
            "Python3_EXECUTABLE",
        ):
            self.assertIn(contract, source)
        self.assertNotIn('CLANG_BIN="/usr/bin/clang"', source)
        self.assertNotIn('PYTHON_BIN="/usr/bin/python3"', source)

    def test_build_is_static_arm64_macos15_and_has_exact_options(self) -> None:
        source = self.source()
        for contract in (
            "CMAKE_OSX_ARCHITECTURES=arm64",
            'DEPLOYMENT_TARGET="15.0"',
            '-DCMAKE_OSX_DEPLOYMENT_TARGET="$DEPLOYMENT_TARGET"',
            "CMAKE_OSX_SYSROOT",
            "BUILD_SHARED_LIBS=OFF",
            "SUITESPARSE=OFF",
            "ACCELERATESPARSE=ON",
            "EIGENSPARSE=ON",
            "EIGENMETIS=OFF",
            "USE_CUDA=OFF",
            "MINIGLOG=OFF",
            "GFLAGS=ON",
            "miniglog source entered the Ceres build",
            "static glog/gflags support did not enter the Ceres build",
            "BUILD_TESTING=OFF",
            "BUILD_EXAMPLES=OFF",
            "BUILD_BENCHMARKS=OFF",
            "BUILD_DOCUMENTATION=OFF",
            "ZERO_AR_DATE=1",
            "SOURCE_DATE_EPOCH=0",
            "-ffile-prefix-map=",
            "-fdebug-prefix-map=",
            "CMAKE_FIND_USE_PACKAGE_REGISTRY=OFF",
            "CMAKE_FIND_USE_SYSTEM_PACKAGE_REGISTRY=OFF",
            "CMAKE_IGNORE_PREFIX_PATH=/opt/homebrew;/usr/local",
            "CMAKE_Fortran_COMPILER=NOTFOUND",
            "unpinned Fortran compiler entered the Eigen configure",
        ):
            self.assertIn(contract, source)
        self.assertNotRegex(source, r"-(?:mcpu|march)(?:=|\s+)native")
        for forbidden in (
            "git clone",
            "brew --prefix",
            "$(pkg-config",
            "BUILD_SHARED_LIBS=ON",
        ):
            self.assertNotIn(forbidden, source)

    def test_build_binds_support_and_promotes_only_after_independent_validation(
        self,
    ) -> None:
        source = self.source()
        for contract in (
            "Toolchains/build/colmap-support/install",
            "support_install_tree_sha256",
            "support_receipt_sha256",
            "safe_extract_source.py",
            "atomic_swap_install.py",
            "install.stage.",
            ".build.lock",
            '"$LOCKF_BIN" -s -t 0 9',
            "validate_install_tree",
            "validate_receipt",
            "--validate-only",
            "prior Ceres install restored",
            "install_tree_sha256",
            "builder_sha256",
            "builder_implementation_sha256",
            "source_lock_sha256",
            "extractor_sha256",
            "promoter_sha256",
        ):
            self.assertIn(contract, source)
        validation_before = source.index('validate_install_tree "$STAGE"')
        promotion = source.index('"$PYTHON_BIN" "$PROMOTER" "$STAGE" "$INSTALL"')
        validation_after = source.index('validate_install_tree "$INSTALL"')
        self.assertLess(validation_before, promotion)
        self.assertLess(promotion, validation_after)

    def test_receipt_identity_is_independent_of_the_build_account(self) -> None:
        source = self.source()
        self.assertIn(
            '"ownership_policy": "invoking-build-user-and-primary-group"',
            source,
        )
        self.assertNotRegex(source, r'"normalized_owner_(?:uid|gid)"\s*:')
        self.assertEqual(source.count("metadata.st_uid"), 2)
        self.assertEqual(source.count("metadata.st_gid"), 2)

    def test_output_and_relocation_gates_are_executable_contracts(self) -> None:
        source = self.source()
        for contract in (
            "lib/libceres.a",
            "CeresConfig.cmake",
            "Eigen3Config.cmake",
            "licenses/Ceres/LICENSE",
            "licenses/Eigen/COPYING.MPL2",
            "duplicate archive member",
            "expected Ceres symbols are missing",
            "forbidden Ceres symbol",
            "optional CUDA or SuiteSparse archive member survived",
            '"$AR_BIN" -d',
            "checkout path leaked into Ceres prefix",
            "relocated Ceres consumer",
            "find_package(Ceres CONFIG REQUIRED)",
            "Ceres::ceres",
            "final_cost",
            '"$LIPO_BIN" -archs',
            "newer than macOS 15.0",
            "libceres",
            "cholmod",
        ):
            self.assertIn(contract, source)


class ArchiveSafetyTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.extractor = load_module("ceres_safe_extract", EXTRACTOR)

    def create_archive(
        self, path: Path, entries: list[tuple[str, bytes, str | None]]
    ) -> None:
        with tarfile.open(path, "w:gz") as archive:
            for name, payload, link_target in entries:
                info = tarfile.TarInfo(name)
                if link_target is not None:
                    info.type = tarfile.SYMTYPE
                    info.linkname = link_target
                    archive.addfile(info)
                else:
                    info.size = len(payload)
                    import io

                    archive.addfile(info, io.BytesIO(payload))

    def test_safe_extractor_rejects_traversal_and_escaping_link(self) -> None:
        for entries in (
            [("source/../escape", b"x", None)],
            [("source/link", b"", "/private/tmp/escape")],
        ):
            with (
                self.subTest(entries=entries),
                tempfile.TemporaryDirectory() as temporary,
            ):
                root = Path(temporary)
                archive = root / "source.tar.gz"
                destination = root / "destination"
                destination.mkdir()
                self.create_archive(archive, entries)
                with self.assertRaises(self.extractor.ExtractionError):
                    self.extractor.extract(archive, destination)


class AtomicPromotionTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.promoter = load_module("ceres_atomic_swap", PROMOTER)

    def test_failed_parent_sync_rolls_back_existing_install(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            stage = root / "install.stage"
            install = root / "install"
            stage.mkdir()
            install.mkdir()
            (stage / "value").write_text("new", encoding="utf-8")
            (install / "value").write_text("old", encoding="utf-8")
            original_sync = self.promoter.sync_directory

            def failing_sync(path: Path) -> None:
                if path.resolve() == root.resolve():
                    raise OSError("fixture sync failure")
                original_sync(path)

            self.promoter.sync_directory = failing_sync
            try:
                with self.assertRaisesRegex(OSError, "fixture sync failure"):
                    self.promoter.promote(stage, install)
            finally:
                self.promoter.sync_directory = original_sync
            self.assertEqual((install / "value").read_text(encoding="utf-8"), "old")
            self.assertEqual((stage / "value").read_text(encoding="utf-8"), "new")


class ArtifactTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        if not INSTALL.is_dir():
            raise unittest.SkipTest(f"Ceres install is not built: {INSTALL}")
        cls.receipt = json.loads(
            (INSTALL / "build_info.json").read_text(encoding="utf-8")
        )

    def test_tree_is_metadata_complete_and_path_clean(self) -> None:
        self.assertEqual(self.receipt["install_tree_sha256"], tree_digest(INSTALL))
        for path in [INSTALL, *INSTALL.rglob("*")]:
            metadata = path.lstat()
            self.assertEqual(
                (metadata.st_uid, metadata.st_gid),
                (os.getuid(), os.getgid()),
                path,
            )
        allowed_roots = {"include", "lib", "licenses", "share", "build_info.json"}
        self.assertTrue({path.name for path in INSTALL.iterdir()} <= allowed_roots)
        self.assertFalse(any(path.is_symlink() for path in INSTALL.rglob("*")))
        payload = b"\n".join(
            path.read_bytes() for path in INSTALL.rglob("*") if path.is_file()
        )
        for forbidden in (
            b"/Users/",
            b"/private/tmp/",
            b"/opt/homebrew/",
            b"-march=native",
            b"-mcpu=native",
        ):
            self.assertNotIn(forbidden, payload)

    def test_receipt_binds_sources_support_tools_and_payload(self) -> None:
        self.assertEqual(self.receipt["toolchain_name"], "ceres-static")
        self.assertEqual(
            self.receipt["source_url"],
            json.loads(LOCK.read_text())["dependencies"]["ceres"]["source"]["url"],
        )
        self.assertEqual(self.receipt["source_commit"], EXPECTED["ceres"]["commit"])
        self.assertEqual(self.receipt["source_version"], EXPECTED["ceres"]["version"])
        self.assertEqual(self.receipt["license"], EXPECTED["ceres"]["license"])
        self.assertEqual(self.receipt["architecture"], "arm64")
        self.assertEqual(self.receipt["deployment_target"], "macOS 15.0")
        self.assertFalse(self.receipt["shared_libraries"])
        self.assertFalse(self.receipt["suitesparse"])
        self.assertFalse(self.receipt["cuda"])
        self.assertEqual(self.receipt["logging"], "glog")
        self.assertEqual(
            self.receipt["ownership_policy"],
            "invoking-build-user-and-primary-group",
        )
        self.assertNotIn("normalized_owner_uid", self.receipt)
        self.assertNotIn("normalized_owner_gid", self.receipt)
        self.assertEqual(
            self.receipt["library_sha256"]["lib/libceres.a"],
            sha256(INSTALL / "lib/libceres.a"),
        )
        self.assertEqual(
            self.receipt["support_receipt_sha256"], sha256(SUPPORT / "build_info.json")
        )
        self.assertEqual(
            self.receipt["support_install_tree_sha256"],
            json.loads((SUPPORT / "build_info.json").read_text())[
                "install_tree_sha256"
            ],
        )
        for key in (
            "builder_sha256",
            "builder_implementation_sha256",
            "source_lock_sha256",
            "extractor_sha256",
            "promoter_sha256",
            "build_tool_sha256",
            "macos_sdk_settings_sha256",
        ):
            self.assertIn(key, self.receipt)

    def test_install_has_only_static_ceres_and_relocatable_configs(self) -> None:
        self.assertTrue((INSTALL / "lib/libceres.a").is_file())
        self.assertFalse(list(INSTALL.rglob("*.dylib")))
        self.assertFalse(list(INSTALL.rglob("*.pc")))
        self.assertFalse((INSTALL / "bin").exists())
        for config in list(INSTALL.rglob("*.cmake")):
            text = config.read_text(encoding="utf-8")
            self.assertNotIn(str(INSTALL), text)
            self.assertNotIn(str(ROOT), text)

    def test_receipt_and_tree_mutations_are_detectable(self) -> None:
        original = self.receipt["install_tree_sha256"]
        with tempfile.TemporaryDirectory() as temporary:
            copy = Path(temporary) / "install"
            shutil.copytree(INSTALL, copy)
            header = next((copy / "include").rglob("*.h"))
            header.write_bytes(header.read_bytes() + b"\n")
            self.assertNotEqual(original, tree_digest(copy))
            header.write_bytes(header.read_bytes()[:-1])
            added = copy / "include/forged.h"
            added.write_text("forged", encoding="utf-8")
            self.assertNotEqual(original, tree_digest(copy))

    def test_standalone_validator_rechecks_the_relocated_consumer(self) -> None:
        result = subprocess.run(
            [str(BUILDER), "--validate-only", str(INSTALL)],
            check=False,
            capture_output=True,
            text=True,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("Validated Ceres install", result.stdout)

    def test_standalone_validator_rejects_receipt_and_tree_mutations(self) -> None:
        epoch_ns = self.receipt["normalized_mtime_epoch"] * 1_000_000_000
        fixtures = (
            "receipt",
            "dependency",
            "tool",
            "ownership",
            "numeric-owner",
            "tree",
        )
        for fixture in fixtures:
            with (
                self.subTest(fixture=fixture),
                tempfile.TemporaryDirectory() as temporary,
            ):
                copy = Path(temporary) / "install"
                shutil.copytree(INSTALL, copy)
                if fixture == "receipt":
                    receipt_path = copy / "build_info.json"
                    receipt = json.loads(receipt_path.read_text(encoding="utf-8"))
                    receipt["architecture"] = "x86_64"
                    receipt_path.write_text(
                        json.dumps(receipt, indent=2, sort_keys=True) + "\n",
                        encoding="utf-8",
                    )
                    os.utime(receipt_path, ns=(epoch_ns, epoch_ns))
                elif fixture == "dependency":
                    receipt_path = copy / "build_info.json"
                    receipt = json.loads(receipt_path.read_text(encoding="utf-8"))
                    receipt["dependencies"]["eigen"]["source_commit"] = "0" * 40
                    receipt_path.write_text(
                        json.dumps(receipt, indent=2, sort_keys=True) + "\n",
                        encoding="utf-8",
                    )
                    os.utime(receipt_path, ns=(epoch_ns, epoch_ns))
                elif fixture == "tool":
                    receipt_path = copy / "build_info.json"
                    receipt = json.loads(receipt_path.read_text(encoding="utf-8"))
                    receipt["build_tool_sha256"]["cmake"] = "0" * 64
                    receipt_path.write_text(
                        json.dumps(receipt, indent=2, sort_keys=True) + "\n",
                        encoding="utf-8",
                    )
                    os.utime(receipt_path, ns=(epoch_ns, epoch_ns))
                elif fixture == "ownership":
                    receipt_path = copy / "build_info.json"
                    receipt = json.loads(receipt_path.read_text(encoding="utf-8"))
                    receipt["ownership_policy"] = "numeric-owner-encoded"
                    receipt_path.write_text(
                        json.dumps(receipt, indent=2, sort_keys=True) + "\n",
                        encoding="utf-8",
                    )
                    os.utime(receipt_path, ns=(epoch_ns, epoch_ns))
                elif fixture == "numeric-owner":
                    receipt_path = copy / "build_info.json"
                    receipt = json.loads(receipt_path.read_text(encoding="utf-8"))
                    receipt["normalized_owner_uid"] = 501
                    receipt_path.write_text(
                        json.dumps(receipt, indent=2, sort_keys=True) + "\n",
                        encoding="utf-8",
                    )
                    os.utime(receipt_path, ns=(epoch_ns, epoch_ns))
                else:
                    header = next((copy / "include/ceres").glob("*.h"))
                    header.write_bytes(header.read_bytes() + b"\n")
                    os.utime(header, ns=(epoch_ns, epoch_ns))
                result = subprocess.run(
                    [str(BUILDER), "--validate-only", str(copy)],
                    check=False,
                    capture_output=True,
                    text=True,
                )
                self.assertNotEqual(result.returncode, 0)


class PortableTreeIdentityTests(unittest.TestCase):
    def test_normalized_tree_digest_ignores_simulated_numeric_ownership(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary) / "install"
            root.mkdir()
            payload = root / "payload.bin"
            payload.write_bytes(b"portable payload\n")
            os.chmod(root, 0o755)
            os.chmod(payload, 0o644)
            os.utime(payload, (946684800, 946684800))
            os.utime(root, (946684800, 946684800))
            expected = tree_digest(root)
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
                actual = tree_digest(root)

            self.assertEqual(actual, expected)


class ReproducibilityTests(unittest.TestCase):
    def test_two_supplied_install_roots_match_byte_for_byte(self) -> None:
        first_raw = os.environ.get("EASYSPLAT_CERES_REPRO_FIRST")
        second_raw = os.environ.get("EASYSPLAT_CERES_REPRO_SECOND")
        if not first_raw or not second_raw:
            raise unittest.SkipTest("set both EASYSPLAT_CERES_REPRO_FIRST and _SECOND")
        first = Path(first_raw)
        second = Path(second_raw)
        self.assertEqual(
            tree_digest(first, exclude_receipt=False),
            tree_digest(second, exclude_receipt=False),
        )
        self.assertEqual(
            (first / "build_info.json").read_bytes(),
            (second / "build_info.json").read_bytes(),
        )


if __name__ == "__main__":
    unittest.main()
