#!/usr/bin/env python3
"""Regression tests for the local toolchain launcher."""

from __future__ import annotations

import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest
import zipfile


ROOT = Path(__file__).resolve().parents[3]
LAUNCHER = ROOT / "scripts/run.sh"


class LocalLauncherTests(unittest.TestCase):
    @staticmethod
    def write_executable(path: Path, source: str) -> None:
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(source, encoding="utf-8")
        path.chmod(0o755)

    @staticmethod
    def write_archive(path: Path, files: dict[str, bytes]) -> None:
        path.parent.mkdir(parents=True, exist_ok=True)
        with zipfile.ZipFile(path, "w", compression=zipfile.ZIP_STORED) as archive:
            for name, contents in sorted(files.items()):
                archive.writestr(name, contents)

    @staticmethod
    def write_signed_native_executable(path: Path) -> None:
        path.parent.mkdir(parents=True, exist_ok=True)
        subprocess.run(
            ["/usr/bin/xcrun", "clang", "-x", "c", "-", "-o", str(path)],
            input="int main(void) { return 0; }\n",
            check=True,
            capture_output=True,
            text=True,
        )
        path.chmod(0o755)
        subprocess.run(
            [
                "/usr/bin/codesign",
                "--force",
                "--sign",
                "-",
                "--timestamp=none",
                str(path),
            ],
            check=True,
            capture_output=True,
            text=True,
        )

    def copy_launcher(self, fixture: Path, validator_source: str) -> Path:
        launcher = fixture / "scripts/run.sh"
        launcher.parent.mkdir(parents=True)
        shutil.copy2(LAUNCHER, launcher)
        self.write_executable(
            fixture / "scripts/toolchain/validate_native_msplat.sh",
            validator_source,
        )
        return launcher

    def test_fast_mode_accepts_core_without_optional_da3(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            fixture = Path(temporary)
            launcher = self.copy_launcher(
                fixture, "#!/usr/bin/env bash\nexit 0\n"
            )

            toolchain = fixture / "Toolchains/dev/2.0.0"
            for directory in (
                toolchain / "bin",
                toolchain / "lib",
                toolchain / "licenses/EasySplat",
                toolchain / "msplat",
                toolchain / "provenance",
                toolchain / "supply-chain",
            ):
                directory.mkdir(parents=True, exist_ok=True)

            colmap = toolchain / "bin/colmap"
            self.write_signed_native_executable(colmap)
            self.write_executable(
                toolchain / "bin/easysplat-train",
                "#!/usr/bin/env bash\nexit 0\n",
            )
            for relative in (
                "bin/default.metallib",
                "lib/libomp.dylib",
                "licenses/EasySplat/LICENSE",
                "msplat/build_info.json",
                "msplat/LICENSE",
                "provenance/colmap.json",
                "provenance/colmap-support.json",
                "provenance/ceres.json",
                "provenance/openimageio.json",
                "supply-chain/components.json",
            ):
                (toolchain / relative).write_text("fixture\n", encoding="utf-8")

            stub_bin = fixture / "stub-bin"
            stub_bin.mkdir()
            swift_log = fixture / "swift.log"
            swift = stub_bin / "swift"
            self.write_executable(
                swift,
                "#!/usr/bin/env bash\n"
                "set -euo pipefail\n"
                "printf '%s\\n' \"${EASYSPLAT_LOCAL_TOOLCHAIN_ROOT:-}\" > \"$SWIFT_LOG\"\n"
                "printf '%s\\n' \"$*\" >> \"$SWIFT_LOG\"\n",
            )

            environment = os.environ.copy()
            environment["PATH"] = f"{stub_bin}:{environment['PATH']}"
            environment["SWIFT_LOG"] = str(swift_log)
            completed = subprocess.run(
                [
                    str(launcher),
                    "--fast",
                    "--toolchain-root",
                    str(toolchain),
                ],
                cwd=fixture,
                env=environment,
                capture_output=True,
                text=True,
            )

            self.assertEqual(
                completed.returncode,
                0,
                msg=f"stdout:\n{completed.stdout}\nstderr:\n{completed.stderr}",
            )
            self.assertFalse((toolchain / "da3_mps").exists())
            self.assertEqual(
                swift_log.read_text(encoding="utf-8").splitlines(),
                [
                    str(toolchain.resolve()),
                    f"run --package-path {fixture} EasySplatApp",
                ],
            )

    def test_cached_archives_enforce_component_ownership(self) -> None:
        archive_cases = {
            "valid": (None, None, None),
            "core-unexpected": ("core", "bin/unreviewed-helper", None),
            "base": (
                "base",
                "da3_mps/models/DA3-LARGE/model.safetensors",
                None,
            ),
            "small-unexpected": (
                "small",
                "da3_mps/app/unexpected.py",
                None,
            ),
            "core-missing": (
                "core",
                None,
                "supply-chain/components.json",
            ),
            "base-missing": (
                "base",
                None,
                "da3_mps/models/DA3-BASE/easysplat_model_info.json",
            ),
            "small-missing": (
                "small",
                None,
                "da3_mps/models/DA3-SMALL/LICENSE",
            ),
        }
        for label, (component, unexpected, missing) in archive_cases.items():
            with self.subTest(label=label), tempfile.TemporaryDirectory() as temporary:
                fixture = Path(temporary)
                launcher = self.copy_launcher(
                    fixture, "#!/usr/bin/env bash\nexit 0\n"
                )
                (fixture / "Tools/Da3Sfm").mkdir(parents=True)
                (fixture / "Tools/MsplatNative").mkdir(parents=True)

                signed_colmap = fixture / "signed-colmap"
                self.write_signed_native_executable(signed_colmap)

                core_files = {
                    "bin/colmap": signed_colmap.read_bytes(),
                    "bin/easysplat-train": b"trainer",
                    "bin/default.metallib": b"metal",
                    "lib/libomp.dylib": b"openmp",
                    "licenses/EasySplat/LICENSE": b"license",
                    "msplat/build_info.json": b"{}",
                    "msplat/LICENSE": b"license",
                    "provenance/colmap.json": b"{}",
                    "provenance/colmap-support.json": b"{}",
                    "provenance/ceres.json": b"{}",
                    "provenance/openimageio.json": b"{}",
                    "supply-chain/components.json": b"{}",
                }
                base_files = {
                    "da3_mps/bin/easysplat_da3_sfm": b"runner",
                    "da3_mps/python/bin/python3": b"python",
                    "da3_mps/build_info.json": b"{}",
                    "da3_mps/app/easysplat_da3_sfm/run.py": b"pass\n",
                    "da3_mps/vendor/depth-anything-3/src/depth_anything_3/api.py": b"pass\n",
                    "da3_mps/licenses/DA3/LICENSE": b"license",
                    "da3_mps/models/DA3-BASE/LICENSE": b"license",
                    "da3_mps/models/DA3-BASE/config.json": b"{}",
                    "da3_mps/models/DA3-BASE/model.safetensors": b"weights",
                    "da3_mps/models/DA3-BASE/easysplat_model_info.json": b"{}",
                }
                small_files = {
                    "da3_mps/models/DA3-SMALL/LICENSE": b"license",
                    "da3_mps/models/DA3-SMALL/config.json": b"{}",
                    "da3_mps/models/DA3-SMALL/model.safetensors": b"weights",
                    "da3_mps/models/DA3-SMALL/easysplat_model_info.json": b"{}",
                }
                files_by_component = {
                    "core": core_files,
                    "base": base_files,
                    "small": small_files,
                }
                if component is not None and unexpected is not None:
                    files_by_component[component][unexpected] = b"unexpected"
                if component is not None and missing is not None:
                    del files_by_component[component][missing]

                output = fixture / "Toolchains/out"
                core_archive = output / "toolchain-macos-arm64-2.0.0-core.zip"
                self.write_archive(core_archive, core_files)
                self.write_archive(
                    output / "toolchain-geometry-da3-base-2.0.0.zip",
                    base_files,
                )
                self.write_archive(
                    output / "toolchain-geometry-da3-small-2.0.0.zip",
                    small_files,
                )

                self.write_executable(
                    fixture / "scripts/toolchain/build_colmap_support.sh",
                    "#!/usr/bin/env bash\nexit 41\n",
                )
                stub_bin = fixture / "stub-bin"
                self.write_executable(
                    stub_bin / "swift", "#!/usr/bin/env bash\nexit 42\n"
                )
                future = core_archive.stat().st_mtime_ns + 2_000_000_000
                os.utime(core_archive, ns=(future, future))

                environment = os.environ.copy()
                environment["PATH"] = f"{stub_bin}:{environment['PATH']}"
                completed = subprocess.run(
                    [
                        str(launcher),
                        "--toolchain-root",
                        str(fixture / "Toolchains/dev/2.0.0"),
                    ],
                    cwd=fixture,
                    env=environment,
                    capture_output=True,
                    text=True,
                )
                self.assertEqual(
                    completed.returncode,
                    42 if component is None else 41,
                    msg=f"stdout:\n{completed.stdout}\nstderr:\n{completed.stderr}",
                )

    def test_clean_clone_runs_native_builders_in_dependency_order(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            fixture = Path(temporary)
            launcher = self.copy_launcher(
                fixture,
                "#!/usr/bin/env bash\n"
                "set -euo pipefail\n"
                "if [ \"${1:-}\" = --source ]; then\n"
                "  test -f \"${2:-}/build_info.json\"\n"
                "fi\n",
            )
            (fixture / "Tools/Da3Sfm").mkdir(parents=True)
            (fixture / "Tools/MsplatNative").mkdir(parents=True)

            for builder in (
                "build_colmap_support.sh",
                "build_ceres.sh",
                "build_openimageio.sh",
                "build_colmap.sh",
            ):
                self.write_executable(
                    fixture / "scripts/toolchain" / builder,
                    "#!/usr/bin/env bash\n"
                    "set -euo pipefail\n"
                    f"printf '%s\\n' '{builder}' >> \"$BUILD_LOG\"\n",
                )

            self.write_executable(
                fixture / "scripts/toolchain/build_msplat.sh",
                "#!/usr/bin/env bash\n"
                "set -euo pipefail\n"
                "printf '%s\\n' 'build_msplat.sh' >> \"$BUILD_LOG\"\n"
                "root=\"$FIXTURE_ROOT/Toolchains/build/msplat/install/msplat\"\n"
                "mkdir -p \"$root\"\n"
                "printf '%s\\n' '{}' > \"$root/build_info.json\"\n",
            )
            self.write_executable(
                fixture / "scripts/toolchain/build_da3_mps.sh",
                "#!/usr/bin/env bash\n"
                "set -euo pipefail\n"
                "printf '%s\\n' 'build_da3_mps.sh' >> \"$BUILD_LOG\"\n"
                "root=\"$FIXTURE_ROOT/Toolchains/build/da3_mps/install/da3_mps\"\n"
                "mkdir -p \"$root/bin\" \"$root/python/bin\" \"$root/app/easysplat_da3_sfm\"\n"
                "mkdir -p \"$root/vendor/depth-anything-3/src/depth_anything_3\"\n"
                "mkdir -p \"$root/models/DA3-BASE\" \"$root/models/DA3-SMALL\"\n"
                "printf '#!/usr/bin/env bash\\nexit 0\\n' > \"$root/bin/easysplat_da3_sfm\"\n"
                "chmod +x \"$root/bin/easysplat_da3_sfm\"\n"
                "ln -s /usr/bin/python3 \"$root/python/bin/python3\"\n"
                "printf 'pass\\n' > \"$root/app/easysplat_da3_sfm/run.py\"\n"
                "printf 'pass\\n' > \"$root/vendor/depth-anything-3/src/depth_anything_3/api.py\"\n"
                "for model in DA3-BASE DA3-SMALL; do\n"
                "  printf '{}\\n' > \"$root/models/$model/config.json\"\n"
                "  printf '{}\\n' > \"$root/models/$model/easysplat_model_info.json\"\n"
                "  printf 'weights\\n' > \"$root/models/$model/model.safetensors\"\n"
                "done\n"
                "printf '%s\\n' "
                "'{\"toolchain_name\":\"da3_mps\",\"source_path\":\"fixture\","
                "\"python_version\":\"3\",\"torch_version\":\"fixture\","
                "\"torchvision_version\":\"fixture\"}' "
                "> \"$root/build_info.json\"\n",
            )
            self.write_executable(
                fixture / "scripts/toolchain/package_toolchain.sh",
                "#!/usr/bin/env bash\n"
                "set -euo pipefail\n"
                "printf '%s\\n' 'package_toolchain.sh' >> \"$BUILD_LOG\"\n"
                "exit 37\n",
            )

            build_log = fixture / "build.log"
            environment = os.environ.copy()
            environment["BUILD_LOG"] = str(build_log)
            environment["FIXTURE_ROOT"] = str(fixture)
            completed = subprocess.run(
                [
                    str(launcher),
                    "--rebuild",
                    "--toolchain-root",
                    str(fixture / "Toolchains/dev/2.0.0"),
                ],
                cwd=fixture,
                env=environment,
                capture_output=True,
                text=True,
            )
            self.assertEqual(
                completed.returncode,
                37,
                msg=f"stdout:\n{completed.stdout}\nstderr:\n{completed.stderr}",
            )
            self.assertEqual(
                build_log.read_text(encoding="utf-8").splitlines(),
                [
                    "build_colmap_support.sh",
                    "build_ceres.sh",
                    "build_openimageio.sh",
                    "build_colmap.sh",
                    "build_msplat.sh",
                    "build_da3_mps.sh",
                    "package_toolchain.sh",
                ],
            )

    def test_component_validators_are_wired_to_the_launcher(self) -> None:
        source = LAUNCHER.read_text(encoding="utf-8")

        core = source.split("core_zip_valid() {", 1)[1].split("\n}", 1)[0]
        self.assertIn('archive_component_owned "$CORE_ZIP" "core"', core)

        base = source.split("da3_base_zip_valid() {", 1)[1].split("\n}", 1)[0]
        self.assertIn('archive_component_owned "$zip_path" "da3-base"', base)

        small = source.split("da3_small_zip_valid() {", 1)[1].split("\n}", 1)[0]
        self.assertIn('archive_component_owned "$zip_path" "da3-small"', small)


if __name__ == "__main__":
    unittest.main()
