import email
import base64
import hashlib
import importlib.util
import json
import tempfile
import unittest
import subprocess
from pathlib import Path
from unittest import mock


SCRIPT = Path(__file__).resolve().parents[1] / "generate_supply_chain_manifest.py"
SPEC = importlib.util.spec_from_file_location("generate_supply_chain_manifest", SCRIPT)
assert SPEC and SPEC.loader
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


COLMAP_SOURCE_COMMIT = "a0d785fba74b2664f31edc4a29026a8b27c00f67"
FAISS_SOURCE_COMMIT = "5622e93733b64b2e033362dbdfda019b2ab33ef0"
ANTLR_LICENSE_SHA256 = (
    "b1b379fcaf3219593a4c433feb1b35c780bed23fafaae440b1ae2771a9521e3a"
)


class PythonLicenseTests(unittest.TestCase):
    def test_current_closure_license_expressions_are_recognized(self) -> None:
        expressions = {
            "Apache 2.0 License": "Apache-2.0",
            "Apache-2.0 AND CNRI-Python": "Apache-2.0 AND CNRI-Python",
            "Apache-2.0 OR BSD-2-Clause": "Apache-2.0 OR BSD-2-Clause",
            "BSD-2-Clause": "BSD-2-Clause",
            "BSD-3-Clause": "BSD-3-Clause",
            "ISC License": "ISC",
            "MIT": "MIT",
            "MIT-CMU": "MIT-CMU",
            "MPL-2.0 AND MIT": "MPL-2.0 AND MIT",
            "PSF-2.0": "PSF-2.0",
            "Apache-2.0 WITH LLVM-exception": "Apache-2.0 WITH LLVM-exception",
            "IJG AND BSD-3-Clause AND Zlib": "IJG AND BSD-3-Clause AND Zlib",
            "libpng-2.0": "libpng-2.0",
        }
        for raw, expected in expressions.items():
            with self.subTest(raw=raw):
                self.assertEqual(MODULE.normalize_license(raw), expected)

    def test_arbitrary_or_nonredistributable_license_is_rejected(self) -> None:
        for expression in ("Proprietary", "SSPL-1.0", "Not-A-License"):
            with self.subTest(expression=expression):
                with self.assertRaisesRegex(SystemExit, "unreviewed license"):
                    MODULE.normalize_license(expression)

    def test_forbidden_copyleft_license_fails_closed(self) -> None:
        with self.assertRaisesRegex(SystemExit, "forbidden release license"):
            MODULE.normalize_license("GPL-3.0-only")

    def test_unknown_legacy_field_falls_through_to_unambiguous_classifier(self) -> None:
        metadata = email.message_from_string(
            "Name: addict\n"
            "License: UNKNOWN\n"
            "Classifier: License :: OSI Approved :: MIT License\n"
        )

        self.assertEqual(MODULE.metadata_license(metadata), "MIT")

    def test_unknown_license_without_classifier_still_fails_closed(self) -> None:
        metadata = email.message_from_string("Name: mystery\nLicense: UNKNOWN\n")

        with self.assertRaisesRegex(SystemExit, "no unambiguous license metadata"):
            MODULE.metadata_license(metadata)

    def test_distribution_scan_does_not_promote_vendored_dist_info(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            python_root = Path(temporary)
            site_packages = python_root / "lib/python3.13/site-packages"
            top_level = site_packages / "setuptools-83.0.0.dist-info/METADATA"
            vendored = (
                site_packages
                / "setuptools/_vendor/autocommand-2.2.2.dist-info/METADATA"
            )
            top_level.parent.mkdir(parents=True)
            vendored.parent.mkdir(parents=True)
            top_level.write_text("Name: setuptools\n", encoding="utf-8")
            vendored.write_text("Name: autocommand\n", encoding="utf-8")

            self.assertEqual(
                MODULE.distribution_metadata_paths(python_root),
                [top_level],
            )

    def test_python_license_receipts_are_regenerated_without_stale_entries(
        self,
    ) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            stale = root / "licenses/python-packages/removed-package/LICENSE"
            stale.parent.mkdir(parents=True)
            stale.write_text("stale\n", encoding="utf-8")

            receipt_root = MODULE.reset_python_license_receipts(root)

            self.assertEqual(receipt_root, root / "licenses/python-packages")
            self.assertTrue(receipt_root.is_dir())
            self.assertEqual(list(receipt_root.iterdir()), [])

    def test_undeclared_dist_info_license_files_are_preserved(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            dist_info = Path(temporary) / "package-1.0.dist-info"
            metadata_path = dist_info / "METADATA"
            root_license = dist_info / "LICENSE"
            nested_license = dist_info / "licenses/COPYING.txt"
            nested_license.parent.mkdir(parents=True)
            metadata_path.write_text("Name: package\nLicense: MIT\n", encoding="utf-8")
            root_license.write_text("MIT\n", encoding="utf-8")
            nested_license.write_text("Copyright\n", encoding="utf-8")
            metadata = email.message_from_bytes(metadata_path.read_bytes())

            self.assertEqual(
                MODULE.distribution_license_sources(metadata_path, metadata),
                [root_license, nested_license],
            )

    def test_declared_license_path_cannot_escape_dist_info(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            dist_info = Path(temporary) / "package-1.0.dist-info"
            metadata_path = dist_info / "METADATA"
            dist_info.mkdir()
            metadata_path.write_text(
                "Name: package\nLicense: MIT\nLicense-File: ../escape\n",
                encoding="utf-8",
            )
            metadata = email.message_from_bytes(metadata_path.read_bytes())

            with self.assertRaisesRegex(SystemExit, "unsafe license path"):
                MODULE.distribution_license_sources(metadata_path, metadata)

    def test_distribution_without_physical_license_notice_fails_closed(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            dist_info = Path(temporary) / "package-1.0.dist-info"
            metadata_path = dist_info / "METADATA"
            dist_info.mkdir()
            metadata_path.write_text("Name: package\nLicense: MIT\n", encoding="utf-8")
            metadata = email.message_from_bytes(metadata_path.read_bytes())

            with self.assertRaisesRegex(SystemExit, "no physical license notice"):
                MODULE.distribution_license_sources(metadata_path, metadata)


class SupplementalLicenseTests(unittest.TestCase):
    def test_reviewed_notice_hashes_are_pinned(self) -> None:
        self.assertEqual(
            MODULE.REVIEWED_SUPPLEMENTAL_LICENSES["antlr4-python3-runtime"][
                "artifactSha256"
            ],
            ANTLR_LICENSE_SHA256,
        )
        self.assertEqual(
            set(MODULE.REVIEWED_SUPPLEMENTAL_LICENSES),
            {"antlr4-python3-runtime"},
        )

    def _write_fixture(self, root: Path) -> dict[str, dict[str, str]]:
        notices = []
        entries = ((
            "antlr4-python3-runtime",
            "4.9.3",
            "BSD-3-Clause",
            "antlr4_python3_runtime-4.9.3.dist-info",
            "UPSTREAM_LICENSE.txt",
            b"antlr license",
        ),)
        reviewed: dict[str, dict[str, str]] = {}
        for package, version, license_name, dist_info, filename, content in entries:
            path = (
                root
                / "da3_mps/python/lib/python3.13/site-packages"
                / dist_info
                / "licenses"
                / filename
            )
            path.parent.mkdir(parents=True)
            path.write_bytes(content)
            digest = hashlib.sha256(content).hexdigest()
            reviewed[package] = {
                "package": package,
                "version": version,
                "license": license_name,
                "source": f"https://example.com/{package}",
                "sourceCommit": "a" * 40,
                "artifact": f"https://example.com/{package}/LICENSE",
                "artifactSha256": digest,
                "distInfo": dist_info,
                "filename": filename,
            }
            notices.append(
                reviewed[package] | {"installedPath": path.relative_to(root).as_posix()}
            )
        manifest = root / "da3_mps/licenses/python-package-upstream-notices.json"
        manifest.parent.mkdir(parents=True)
        manifest.write_text(
            json.dumps({"schemaVersion": 1, "notices": notices}), encoding="utf-8"
        )
        return reviewed

    def test_supplemental_notice_receipt_binds_physical_files(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            reviewed = self._write_fixture(root)

            ownership = MODULE.validate_supplemental_license_receipts(
                root, reviewed=reviewed
            )
            installed = (
                root
                / "da3_mps/python/lib/python3.13/site-packages"
                / "antlr4_python3_runtime-4.9.3.dist-info/licenses/UPSTREAM_LICENSE.txt"
            )
            self.assertEqual(
                ownership,
                {installed.resolve(): "python:antlr4-python3-runtime"},
            )

            notice = json.loads(
                (
                    root / "da3_mps/licenses/python-package-upstream-notices.json"
                ).read_text(encoding="utf-8")
            )["notices"][0]
            (root / notice["installedPath"]).write_bytes(b"tampered")
            with self.assertRaisesRegex(SystemExit, "artifact hash"):
                MODULE.validate_supplemental_license_receipts(root, reviewed=reviewed)


class MachOPortabilityTests(unittest.TestCase):
    def test_macos_gate_rejects_other_apple_platforms(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            fixture = Path(temporary) / "ios-binary"
            fixture.write_bytes(b"native")
            original_run = MODULE.run
            try:
                MODULE.run = lambda *args, **kwargs: (
                    "Load command 1\n"
                    "      cmd LC_BUILD_VERSION\n"
                    " platform IOS\n"
                    "    minos 14.0\n"
                )
                with self.assertRaisesRegex(SystemExit, "platform IOS"):
                    MODULE.validate_macos_15_compatibility(fixture)
            finally:
                MODULE.run = original_run

    def test_architecture_gate_accepts_only_thin_arm64_macho(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            fixture = Path(temporary) / "native"
            original_run = MODULE.run
            try:
                fixture.write_bytes(b"\xcf\xfa\xed\xfe" + b"\x00" * 8)
                MODULE.run = lambda *args, **kwargs: "arm64\n"
                MODULE.validate_arm64_only(fixture)
                for reported in ("x86_64 arm64\n", "arm64e\n", "x86_64\n", ""):
                    MODULE.run = lambda *args, value=reported, **kwargs: value
                    with self.assertRaisesRegex(SystemExit, "arm64-only"):
                        MODULE.validate_arm64_only(fixture)

                fixture.write_bytes(b"\xca\xfe\xba\xbe" + b"\x00" * 8)
                MODULE.run = lambda *args, **kwargs: "arm64\n"
                with self.assertRaisesRegex(SystemExit, "thin 64-bit"):
                    MODULE.validate_arm64_only(fixture)
            finally:
                MODULE.run = original_run

    def test_absolute_dylib_self_id_is_not_an_external_dependency(self) -> None:
        MODULE.validate_macho_dependencies(
            "python/libSelf.dylib",
            ["/wheel-placeholder/libSelf.dylib", "/usr/lib/libSystem.B.dylib"],
            "/wheel-placeholder/libSelf.dylib",
        )

    def test_other_absolute_dependency_still_fails(self) -> None:
        with self.assertRaisesRegex(SystemExit, "unportable dependency"):
            MODULE.validate_macho_dependencies(
                "python/extension.so",
                ["/opt/local/libEscape.dylib"],
                None,
            )

    def test_tokenized_dependencies_must_resolve_inside_packaged_closure(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            source = root / "python/package/extension.so"
            dependency = root / "python/package/.dylibs/libNeeded.dylib"
            source.parent.mkdir(parents=True)
            dependency.parent.mkdir()
            source.write_bytes(b"extension")
            dependency.write_bytes(b"dependency")
            packaged = {source.resolve(), dependency.resolve()}

            MODULE.validate_macho_dependencies(
                "python/package/extension.so",
                ["@loader_path/.dylibs/libNeeded.dylib"],
                None,
                root=root,
                source=source,
                packaged_machos=packaged,
            )
            with self.assertRaisesRegex(SystemExit, "escapes|traversal"):
                MODULE.validate_macho_dependencies(
                    "python/package/extension.so",
                    ["@loader_path/../../outside.dylib"],
                    None,
                    root=root,
                    source=source,
                    packaged_machos=packaged,
                )
            with self.assertRaisesRegex(SystemExit, "missing packaged dependency"):
                MODULE.validate_macho_dependencies(
                    "python/package/extension.so",
                    ["@rpath/libMissing.dylib"],
                    None,
                    root=root,
                    source=source,
                    packaged_machos=packaged,
                )


class FilesystemSafetyTests(unittest.TestCase):
    def test_tracked_source_inputs_pin_current_colmap_patch(self) -> None:
        source = SCRIPT.read_text(encoding="utf-8")
        self.assertIn(
            '"scripts/toolchain/patches/colmap-4.1.1-easysplat.patch"',
            source,
        )
        self.assertNotIn("colmap-4.1.0-easysplat.patch", source)

    def test_file_closure_is_sorted_by_relative_path(self) -> None:
        source = SCRIPT.read_text(encoding="utf-8")
        sort_files = source.index('files.sort(key=lambda entry: entry["path"])')
        write_payload = source.index('"files": files,')
        self.assertLess(sort_files, write_payload)

    def test_nested_zip_files_are_not_exempt_from_inventory(self) -> None:
        source = SCRIPT.read_text(encoding="utf-8")
        self.assertNotIn('path.name.endswith(".zip")', source)

    def test_materialized_symlink_must_remain_inside_toolchain(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            fixture = Path(temporary)
            root = fixture / "root"
            root.mkdir()
            target = root / "python3.13"
            target.write_bytes(b"python-runtime")
            alias = root / "python3"
            alias.symlink_to("python3.13")

            self.assertEqual(MODULE.materialized_source(alias, root), target.resolve())

            outside = fixture / "outside"
            outside.write_bytes(b"outside")
            escaping = root / "escaping"
            escaping.symlink_to(outside)
            with self.assertRaisesRegex(SystemExit, "cannot be materialized"):
                MODULE.materialized_source(escaping, root)


class BuildCommandTests(unittest.TestCase):
    def test_components_map_only_to_current_reproducible_builders(self) -> None:
        self.assertEqual(
            MODULE.component_build_command("colmap", {}),
            "./scripts/toolchain/build_colmap.sh",
        )
        self.assertEqual(
            MODULE.component_build_command("colmap-support:libomp", {}),
            "./scripts/toolchain/build_colmap_support.sh",
        )
        self.assertEqual(
            MODULE.component_build_command("ceres:eigen", {}),
            "./scripts/toolchain/build_ceres.sh",
        )
        self.assertEqual(
            MODULE.component_build_command("openimageio:libpng", {}),
            "./scripts/toolchain/build_openimageio.sh",
        )
        self.assertEqual(
            MODULE.component_build_command("python:numpy", {}),
            "./scripts/toolchain/build_da3_mps.sh",
        )
        self.assertEqual(
            MODULE.component_build_command("easysplat-da3-runner", {}),
            "./scripts/toolchain/build_da3_mps.sh",
        )
        self.assertEqual(
            MODULE.component_build_command("msplat", {}),
            "./scripts/toolchain/build_msplat.sh",
        )
        self.assertEqual(
            MODULE.component_build_command("easysplat-distribution-signing", {}),
            "./scripts/release/finalize_signed_toolchain.py",
        )
        with self.assertRaisesRegex(SystemExit, "no reviewed build command"):
            MODULE.component_build_command("unreviewed-component", {})


class DependencyClosureTests(unittest.TestCase):
    def test_missing_runtime_dependency_fails_closed(self) -> None:
        components = {
            "bridge": {
                "type": "executable-wrapper",
                "dependencies": ["missing-runtime"],
            }
        }

        with self.assertRaisesRegex(SystemExit, "missing-runtime"):
            MODULE.resolve_installed_dependencies(components)

    def test_uninstalled_python_extra_is_omitted(self) -> None:
        components = {
            "python:package": {
                "type": "python-package",
                "dependencies": ["python:installed", "python:optional-extra"],
            },
            "python:installed": {
                "type": "python-package",
                "dependencies": [],
            },
        }

        MODULE.resolve_installed_dependencies(components)

        self.assertEqual(
            components["python:package"]["dependencies"], ["python:installed"]
        )

    def test_component_urls_reject_credentials_query_and_fragment(self) -> None:
        base = {
            "component": {
                "source": "https://example.com/source",
                "sourceArtifacts": [],
            }
        }
        MODULE.validate_component_urls(base)
        for url in (
            "https://user:secret@example.com/source",
            "https://example.com/source?token=secret",
            "https://example.com/source#fragment",
        ):
            with self.subTest(url=url):
                bad = {"component": {"source": url, "sourceArtifacts": []}}
                with self.assertRaisesRegex(SystemExit, "public HTTPS URL"):
                    MODULE.validate_component_urls(bad)


class PythonRecordTests(unittest.TestCase):
    def test_record_hash_and_size_bind_installed_file(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            path = root / "package/native.so"
            path.parent.mkdir()
            path.write_bytes(b"native bytes")
            digest = (
                base64.urlsafe_b64encode(hashlib.sha256(path.read_bytes()).digest())
                .rstrip(b"=")
                .decode("ascii")
            )

            self.assertTrue(
                MODULE.validate_record_member(
                    path,
                    f"sha256={digest}",
                    str(path.stat().st_size),
                    python_root=root,
                    distribution="package",
                )
            )

            path.write_bytes(b"mutated")
            with self.assertRaisesRegex(SystemExit, "RECORD hash mismatch"):
                MODULE.validate_record_member(
                    path,
                    f"sha256={digest}",
                    "",
                    python_root=root,
                    distribution="package",
                )

    def test_only_unhashed_missing_bytecode_record_members_are_ignored(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            with self.assertRaisesRegex(SystemExit, "RECORD member is missing"):
                MODULE.validate_record_member(
                    root / "missing.dylib",
                    "",
                    "",
                    python_root=root,
                    distribution="package",
                )
            self.assertFalse(
                MODULE.validate_record_member(
                    root / "__pycache__/optional.pyc",
                    "",
                    "",
                    python_root=root,
                    distribution="package",
                )
            )
            with self.assertRaisesRegex(SystemExit, "RECORD member is missing"):
                MODULE.validate_record_member(
                    root / "__pycache__/bound.pyc",
                    "sha256=" + "A" * 43,
                    "1",
                    python_root=root,
                    distribution="package",
                )

    def _python_fixture(self, root: Path, *, extra: bool = False) -> None:
        site = root / "da3_mps/python/lib/python3.13/site-packages"
        dist = site / "sample-1.0.dist-info"
        module = site / "sample"
        dist.mkdir(parents=True)
        module.mkdir()
        metadata = dist / "METADATA"
        license_path = dist / "LICENSE"
        source = module / "__init__.py"
        (site / "README.txt").write_text(
            "This directory exists so that third-party packages can be installed.\n",
            encoding="utf-8",
        )
        metadata.write_text(
            "Metadata-Version: 2.4\nName: sample\nVersion: 1.0\n"
            "License-Expression: MIT\n\n",
            encoding="utf-8",
        )
        license_path.write_text("MIT\n", encoding="utf-8")
        source.write_text("__all__ = []\n", encoding="utf-8")

        def row(path: Path) -> str:
            digest = base64.urlsafe_b64encode(
                hashlib.sha256(path.read_bytes()).digest()
            ).rstrip(b"=").decode("ascii")
            return (
                f"{path.relative_to(site).as_posix()},sha256={digest},"
                f"{path.stat().st_size}\n"
            )

        record = dist / "RECORD"
        record.write_text(
            row(metadata)
            + row(license_path)
            + row(source)
            + "sample-1.0.dist-info/RECORD,,\n",
            encoding="utf-8",
        )
        lock = root / "da3_mps/licenses/python-packages-requirements.txt"
        lock.parent.mkdir(parents=True)
        lock.write_text("sample==1.0 \\\n    --hash=sha256:" + "a" * 64 + "\n", encoding="utf-8")
        report = root / "da3_mps/licenses/python-packages-install-report.json"
        report.write_text(
            json.dumps(
                {
                    "install": [
                        {
                            "metadata": {"name": "sample", "version": "1.0"},
                            "download_info": {
                                "url": "https://example.com/sample.whl",
                                "archive_info": {"hashes": {"sha256": "a" * 64}},
                            },
                        }
                    ]
                }
            ),
            encoding="utf-8",
        )
        if extra:
            (site / "evil.py").write_text("evil\n", encoding="utf-8")

    def test_python_lock_report_dist_info_and_record_ownership_are_exact(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            self._python_fixture(root)
            components, ownership = MODULE.python_components(root)
            self.assertEqual(set(components), {"python:sample"})
            self.assertIn(
                (root / "da3_mps/python/lib/python3.13/site-packages/sample/__init__.py").resolve(),
                ownership,
            )

            root = Path(temporary) / "extra"
            self._python_fixture(root, extra=True)
            with self.assertRaisesRegex(SystemExit, "no exact Python RECORD owner"):
                MODULE.python_components(root)

    def test_python_lock_report_and_installed_versions_must_match(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            self._python_fixture(root)
            lock = root / "da3_mps/licenses/python-packages-requirements.txt"
            lock.write_text(
                "different==1.0 \\\n    --hash=sha256:" + "a" * 64 + "\n",
                encoding="utf-8",
            )
            with self.assertRaisesRegex(SystemExit, "must match exactly"):
                MODULE.python_components(root)

    def test_python_report_artifact_hash_must_be_allowed_by_lock(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            self._python_fixture(root)
            report = root / "da3_mps/licenses/python-packages-install-report.json"
            payload = json.loads(report.read_text(encoding="utf-8"))
            payload["install"][0]["download_info"]["archive_info"]["hashes"][
                "sha256"
            ] = "b" * 64
            report.write_text(json.dumps(payload), encoding="utf-8")

            with self.assertRaisesRegex(SystemExit, "artifact hash"):
                MODULE.python_components(root)


class NativeColmapComponentTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary_directory = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary_directory.name)
        (self.root / "bin").mkdir()
        (self.root / "provenance").mkdir()
        (self.root / "licenses" / "COLMAP").mkdir(parents=True)
        self.executable = self.root / "bin" / "colmap"
        self.executable.write_bytes(b"native colmap")
        for name in ("COPYING.txt", "FAISS-LICENSE", "PoseLib-LICENSE", "VLFeat-LICENSE"):
            (self.root / "licenses" / "COLMAP" / name).write_text(
                "license\n", encoding="utf-8"
            )
        self.receipt = {
            "schema_version": 2,
            "toolchain_name": "colmap",
            "source_url": "https://github.com/colmap/colmap.git",
            "source_version": "4.1.1",
            "source_commit": COLMAP_SOURCE_COMMIT,
            "license": "BSD-3-Clause",
            "executable_sha256": hashlib.sha256(self.executable.read_bytes()).hexdigest(),
            "dependencies": {
                "faiss": {
                    "source_url": "https://github.com/facebookresearch/faiss.git",
                    "source_version": "1.14.1",
                    "source_commit": FAISS_SOURCE_COMMIT,
                    "license": "MIT",
                    "license_files": ["licenses/COLMAP/FAISS-LICENSE"],
                    "linkage": "compiled-in",
                },
                "poselib": {
                    "source_url": "https://github.com/PoseLib/PoseLib.git",
                    "source_version": "fixture",
                    "source_commit": "b" * 40,
                    "license": "BSD-3-Clause",
                    "license_files": ["licenses/COLMAP/PoseLib-LICENSE"],
                    "linkage": "compiled-in",
                },
                "vlfeat": {
                    "source_url": "https://github.com/colmap/colmap/tree/fixture/src/thirdparty/VLFeat",
                    "source_version": "vendored",
                    "source_commit": COLMAP_SOURCE_COMMIT,
                    "license": "BSD-2-Clause",
                    "license_files": ["licenses/COLMAP/VLFeat-LICENSE"],
                    "linkage": "compiled-in",
                },
            },
        }
        (self.root / "provenance" / "colmap.json").write_text(
            json.dumps(self.receipt), encoding="utf-8"
        )

    def tearDown(self) -> None:
        self.temporary_directory.cleanup()

    def _write_receipt(self) -> None:
        (self.root / "provenance" / "colmap.json").write_text(
            json.dumps(self.receipt), encoding="utf-8"
        )

    def test_native_colmap_owns_binary_without_python_runtime_dependency(self) -> None:
        components = MODULE.native_colmap_components(self.root)
        component = components["colmap"]

        self.assertEqual(component["id"], "colmap")
        self.assertEqual(component["linkage"], "native-executable")
        self.assertNotIn("python:pycolmap", component["dependencies"])
        self.assertEqual(
            {"colmap:faiss", "colmap:poselib", "colmap:vlfeat"},
            set(component["dependencies"]),
        )

    def test_native_colmap_rejects_receipt_not_bound_to_packaged_executable(self) -> None:
        self.receipt["executable_sha256"] = "f" * 64
        self._write_receipt()

        with self.assertRaisesRegex(SystemExit, "installed executable"):
            MODULE.native_colmap_components(self.root)

    def test_native_colmap_accepts_only_exact_distribution_signing_bridge(self) -> None:
        unsigned = self.receipt["executable_sha256"]
        self.executable.write_bytes(b"Developer ID signed colmap")
        signed = hashlib.sha256(self.executable.read_bytes()).hexdigest()
        distribution = {
            "machOFiles": [
                {
                    "path": "bin/colmap",
                    "preSignSHA256": unsigned,
                    "postSignSHA256": signed,
                }
            ]
        }
        component = MODULE.native_colmap_components(self.root, distribution)["colmap"]
        self.assertEqual(component["id"], "colmap")

        distribution["machOFiles"][0]["preSignSHA256"] = "f" * 64
        with self.assertRaisesRegex(SystemExit, "installed executable"):
            MODULE.native_colmap_components(self.root, distribution)

    def test_native_dependency_records_pinned_source_archive(self) -> None:
        component = MODULE.receipt_dependency_component(
            "openimageio:libpng",
            "libpng",
            {
                "source_url": "https://example.com/libpng-1.6.58.tar.gz",
                "source_version": "1.6.58",
                "source_sha256": "a" * 64,
                "license": "libpng-2.0",
                "license_files": ["licenses/OpenImageIO/libpng-LICENSE"],
                "linkage": "static",
            },
            incorporated_into="openimageio",
        )

        self.assertEqual(component["artifact"], "https://example.com/libpng-1.6.58.tar.gz")
        self.assertEqual(component["artifactSha256"], "a" * 64)


class DistributionSigningReceiptTests(unittest.TestCase):
    def fixture(self, root: Path) -> tuple[Path, set[Path], dict[str, object]]:
        repository_root = SCRIPT.parents[2]
        executable = root / "bin/colmap"
        executable.parent.mkdir(parents=True)
        executable.write_bytes(b"signed Mach-O")
        source_row = {
            "path": "bin/colmap",
            "component": "colmap",
            "kind": "mach-o",
            "sha256": "a" * 64,
            "size": len(b"unsigned Mach-O"),
        }
        manifest = root / "supply-chain/components.json"
        manifest.parent.mkdir(parents=True)
        manifest.write_text(
            json.dumps(
                {
                    "schemaVersion": 1,
                    "toolchainVersion": "2.0.0",
                    "components": [],
                    "files": [source_row],
                }
            ),
            encoding="utf-8",
        )
        commit = subprocess.run(
            ["git", "-C", str(repository_root), "rev-parse", "HEAD"],
            check=True,
            capture_output=True,
            text=True,
        ).stdout.strip()
        source_inputs = [
            {
                "path": relative,
                "sha256": MODULE.sha256(repository_root / relative),
            }
            for relative in sorted(MODULE.DISTRIBUTION_SIGNING_SOURCE_INPUTS)
        ]
        receipt: dict[str, object] = {
            "schemaVersion": 1,
            "kind": "easysplat-distribution-signing",
            "toolchainVersion": "2.0.0",
            "identityFingerprintSHA1": "A" * 40,
            "teamID": "TEAMID1234",
            "signedAt": "2026-07-18T00:00:00Z",
            "sourceCommit": commit,
            "sourceInputs": source_inputs,
            "unsignedComponentArchives": [
                {
                    "component": component,
                    "name": f"{component}.zip",
                    "sha256": character * 64,
                    "size": 100,
                }
                for component, character in (
                    ("core", "1"),
                    ("base", "2"),
                    ("small", "3"),
                )
            ],
            "builderAttestedUnsignedRequestSHA256": "4" * 64,
            "builderAttestedUnsignedManifestSHA256": "5" * 64,
            "unsignedSupplyChainSHA256": MODULE.sha256(manifest),
            "machOFiles": [
                {
                    "path": "bin/colmap",
                    "component": "colmap",
                    "preSignSHA256": "a" * 64,
                    "postSignSHA256": MODULE.sha256(executable),
                    "preSignProvenance": [
                        {
                            "kind": "supply-chain",
                            "path": "supply-chain/components.json",
                            "component": "colmap",
                            "sha256": "a" * 64,
                        }
                    ],
                    "codesign": {
                        "teamIdentifier": "TEAMID1234",
                        "hardenedRuntime": True,
                    },
                }
            ],
            "recordRepairs": [],
        }
        path = root / "provenance/distribution-signing.json"
        path.parent.mkdir()
        path.write_text(json.dumps(receipt), encoding="utf-8")
        return path, {executable.resolve()}, receipt

    def test_internal_receipt_binds_source_and_signed_bytes(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            path, machos, receipt = self.fixture(root)
            self.assertEqual(
                MODULE.load_distribution_signing_receipt(
                    root, path, "2.0.0", machos
                ),
                receipt,
            )

            receipt["machOFiles"][0]["postSignSHA256"] = "f" * 64
            path.write_text(json.dumps(receipt), encoding="utf-8")
            with self.assertRaisesRegex(SystemExit, "stale or invalid"):
                MODULE.load_distribution_signing_receipt(root, path, "2.0.0", machos)

    def test_internal_receipt_requires_release_request_and_manifest_digests(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            path, machos, receipt = self.fixture(root)
            for field in (
                "builderAttestedUnsignedRequestSHA256",
                "builderAttestedUnsignedManifestSHA256",
            ):
                with self.subTest(field=field):
                    mutated = dict(receipt)
                    mutated[field] = "f" * 63
                    path.write_text(json.dumps(mutated), encoding="utf-8")
                    with self.assertRaisesRegex(SystemExit, "identity or version"):
                        MODULE.load_distribution_signing_receipt(
                            root, path, "2.0.0", machos
                        )


class Da3ModelComponentTests(unittest.TestCase):
    MODEL_REVISIONS = {
        "DA3-BASE": (
            "depth-anything/DA3-BASE",
            "f4a6c9b3c95e41c82048423d3493a81ec3fa810e",
        ),
        "DA3-SMALL": (
            "depth-anything/DA3-SMALL",
            "e08cab65ca0ec38e7826075418411ab90cab4da3",
        ),
    }

    def setUp(self) -> None:
        self.temporary_directory = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary_directory.name) / "Toolchains/out/stage"
        self.root.mkdir(parents=True)
        requirements = self.root / "da3_mps/licenses/python-packages-requirements.txt"
        requirements.parent.mkdir(parents=True)
        requirements.write_text("numpy==2.3.5\n", encoding="utf-8")
        da3_receipt = {
            "source_repo": "https://github.com/ByteDance-Seed/Depth-Anything-3.git",
            "source_ref": "41736238f5bced4debf3f2a12375d2466874866d",
            "source_commit": "41736238f5bced4debf3f2a12375d2466874866d",
            "requirements_lock_sha256": hashlib.sha256(
                requirements.read_bytes()
            ).hexdigest(),
            "python_standalone_url": "https://example.com/python.tar.gz",
            "python_standalone_sha256": "a" * 64,
            "python_version": "3.13.11",
            "model_lock": "scripts/toolchain/da3-model-lock.json",
            "model_lock_sha256": "0" * 64,
        }
        (self.root / "da3_mps/build_info.json").write_text(
            json.dumps(da3_receipt), encoding="utf-8"
        )
        msplat_receipt = {
            "source_url": "https://github.com/rayanht/msplat",
            "source_commit": "b" * 40,
            "source_version": "fixture",
            "dependencies": {
                "cli11_v2.4.2_sha256": "c" * 64,
                "nanoflann_v1.5.5_sha256": "d" * 64,
                "nlohmann_json_v3.11.3_sha256": "e" * 64,
            },
        }
        (self.root / "msplat").mkdir()
        (self.root / "msplat/build_info.json").write_text(
            json.dumps(msplat_receipt), encoding="utf-8"
        )
        for relative in (
            "msplat/LICENSE",
            "licenses/msplat/CLI11/LICENSE",
            "licenses/msplat/nanoflann/COPYING",
            "licenses/msplat/nlohmann-json/LICENSE.MIT",
            "licenses/EasySplat/LICENSE",
            "da3_mps/vendor/depth-anything-3/LICENSE",
            "da3_mps/licenses/python-build-standalone/PYTHON.json",
        ):
            path = self.root / relative
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text("license\n", encoding="utf-8")
        (self.root / "da3_mps/licenses/python-build-standalone/licenses").mkdir(
            parents=True
        )
        for model, (repo_id, revision) in self.MODEL_REVISIONS.items():
            model_root = self.root / "da3_mps/models" / model
            model_root.mkdir(parents=True)
            (model_root / "LICENSE").write_text("Apache-2.0\n", encoding="utf-8")
            (model_root / "config.json").write_text(
                json.dumps({"model": model}) + "\n", encoding="utf-8"
            )
            (model_root / "model.safetensors").write_bytes(
                f"{model}:weights\n".encode()
            )
            artifacts = {
                filename: {
                    "sha256": hashlib.sha256(
                        (model_root / filename).read_bytes()
                    ).hexdigest(),
                    "size_bytes": (model_root / filename).stat().st_size,
                }
                for filename in ("config.json", "model.safetensors")
            }
            (model_root / "easysplat_model_info.json").write_text(
                json.dumps(
                    {
                        "repo_id": repo_id,
                        "requested_revision": revision,
                        "resolved_sha": revision,
                        "license": "apache-2.0",
                        "artifacts": artifacts,
                    }
                ),
                encoding="utf-8",
            )
        self.model_lock = (
            Path(self.temporary_directory.name) / "fixture-model-lock.json"
        )
        self.model_lock.write_text(
            json.dumps(
                {
                    "schema_version": 1,
                    "models": {
                        model: json.loads(
                            (
                                self.root
                                / "da3_mps/models"
                                / model
                                / "easysplat_model_info.json"
                            ).read_text(encoding="utf-8")
                        )
                        for model in self.MODEL_REVISIONS
                    },
                }
            ),
            encoding="utf-8",
        )
        da3_receipt_path = self.root / "da3_mps/build_info.json"
        da3_receipt = json.loads(da3_receipt_path.read_text(encoding="utf-8"))
        da3_receipt["model_lock_sha256"] = hashlib.sha256(
            self.model_lock.read_bytes()
        ).hexdigest()
        da3_receipt_path.write_text(json.dumps(da3_receipt), encoding="utf-8")

    def tearDown(self) -> None:
        self.temporary_directory.cleanup()

    def components(self) -> dict[str, dict]:
        with (
            mock.patch.object(MODULE, "aggregate_native_components", return_value={}),
            mock.patch.object(MODULE, "run", return_value="f" * 40 + "\n"),
            mock.patch.object(MODULE, "DA3_MODEL_LOCK", self.model_lock),
        ):
            return MODULE.builder_components(self.root, "2.0.0", {})

    def test_model_components_publish_exact_source_artifact_hashes(self) -> None:
        components = self.components()

        for model, (repo_id, revision) in self.MODEL_REVISIONS.items():
            model_root = self.root / "da3_mps/models" / model
            self.assertEqual(
                components[f"model:{model.lower()}"]["sourceArtifacts"],
                [
                    {
                        "name": filename,
                        "sha256": hashlib.sha256(
                            (model_root / filename).read_bytes()
                        ).hexdigest(),
                        "size": (model_root / filename).stat().st_size,
                        "url": (
                            f"https://huggingface.co/{repo_id}/resolve/"
                            f"{revision}/{filename}"
                        ),
                    }
                    for filename in ("config.json", "model.safetensors")
                ],
            )

    def test_builder_revision_uses_tracked_repository_root(self) -> None:
        calls: list[Path | None] = []

        def capture_run(*_command: str, cwd=None) -> str:
            calls.append(cwd)
            return "f" * 40 + "\n"

        with (
            mock.patch.object(MODULE, "aggregate_native_components", return_value={}),
            mock.patch.object(MODULE, "run", side_effect=capture_run),
            mock.patch.object(MODULE, "DA3_MODEL_LOCK", self.model_lock),
        ):
            MODULE.builder_components(self.root, "2.0.0", {})

        self.assertEqual(calls, [SCRIPT.parents[2]])

    def test_model_component_rejects_bytes_that_do_not_match_provenance(self) -> None:
        path = self.root / "da3_mps/models/DA3-BASE/model.safetensors"
        content = path.read_bytes()
        path.write_bytes(bytes([content[0] ^ 1]) + content[1:])

        with self.assertRaisesRegex(SystemExit, "artifact SHA-256"):
            self.components()


class PackageScriptTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.script = (SCRIPT.parent / "package_toolchain.sh").read_text(
            encoding="utf-8"
        )

    def test_package_uses_native_colmap_and_only_bundles_libomp(self) -> None:
        self.assertIn('COLMAP_INSTALL="${COLMAP_INSTALL:-', self.script)
        self.assertIn('CERES_INSTALL="${CERES_INSTALL:-', self.script)
        self.assertIn('OPENIMAGEIO_INSTALL="${OPENIMAGEIO_INSTALL:-', self.script)
        self.assertIn('install -m 0755 "$COLMAP_INSTALL/bin/colmap" "$BIN/colmap"', self.script)
        self.assertIn('install -m 0755 "$COLMAP_SUPPORT_INSTALL/lib/libomp.dylib"', self.script)
        self.assertNotIn('da3_mps/bin/easysplat_colmap" "$BIN/colmap', self.script)
        self.assertNotIn("SUITESPARSE_INSTALL", self.script)
        self.assertNotIn("EIGEN_INSTALL", self.script)

    def test_package_validates_semver_before_constructing_archive_paths(self) -> None:
        validation = self.script.index("SEMVER_PATTERN=")
        archive_path = self.script.index('CORE_ZIP="$OUT/')
        self.assertLess(validation, archive_path)

    def test_package_requires_clean_committed_packaging_source_closure(self) -> None:
        self.assertIn("require_committed_packaging_sources", self.script)
        self.assertNotIn("require_committed_bridge_sources", self.script)
        for source in (
            "LICENSE",
            "Tools/Da3Sfm",
            "Tools/MsplatNative",
            "scripts/toolchain/build_da3_mps.sh",
            "scripts/toolchain/build_msplat.sh",
            "scripts/toolchain/generate_supply_chain_manifest.py",
            "scripts/toolchain/package_toolchain.sh",
            "scripts/toolchain/secure_colmap_build.py",
            "scripts/toolchain/validate_native_msplat.sh",
        ):
            self.assertIn(source, self.script)
        self.assertIn("status --porcelain", self.script)
        self.assertNotIn("--ignored", self.script)

    def test_package_probes_exact_native_command_and_option_surface(self) -> None:
        for command in (
            "feature_extractor", "matches_importer", "local_vocab_retriever",
            "mapper", "point_triangulator", "bundle_adjuster",
            "model_analyzer", "image_undistorter", "model_converter",
        ):
            self.assertIn(command, self.script)
        self.assertIn("Mapper.min_num_matches", self.script)
        self.assertIn("TwoViewGeometry.random_seed", self.script)
        self.assertIn("FeatureExtraction.max_image_size", self.script)
        self.assertNotIn("SiftExtraction.max_image_size", self.script)
        self.assertIn("BundleAdjustmentCeres.max_num_iterations", self.script)
        self.assertNotIn('"$BIN/colmap" --self-check', self.script)
        self.assertNotIn('"$BIN/colmap" global_mapper', self.script)

    def test_package_preserves_signed_native_bytes(self) -> None:
        self.assertNotIn("lipo -thin", self.script)
        self.assertNotIn("codesign --force", self.script)
        self.assertIn('/usr/bin/codesign --verify --strict "$file"', self.script)

    def test_package_checks_native_receipts_and_dependency_hashes(
        self,
    ) -> None:
        self.assertIn('"executable_sha256"', self.script)
        self.assertIn('"dependency_receipt_sha256"', self.script)
        self.assertNotIn('"dependency_receipt_canonical_sha256"', self.script)
        self.assertIn('"dependency_library_sha256"', self.script)
        self.assertIn('"dependency_tree_sha256"', self.script)
        self.assertIn("metadata.st_mtime_ns", self.script)
        self.assertIn('relative = "." if path == root', self.script)
        self.assertNotIn('"colmap_launcher_sha256"', self.script)

    def test_portability_check_distinguishes_dylib_self_id(self) -> None:
        self.assertIn('otool -D "$file"', self.script)
        self.assertIn('[ "$dependency" = "$install_id" ]', self.script)

    def test_package_prunes_regenerable_python_bytecode_before_manifest(self) -> None:
        delete_bytecode = self.script.index(
            "find \"$OUT/da3_mps/python\" -type f -name '*.pyc' -delete"
        )
        delete_caches = self.script.index(
            "find \"$OUT/da3_mps/python\" -type d -name '__pycache__' -empty -delete"
        )
        generate_manifest = self.script.index('"$SUPPLY_CHAIN_GENERATOR" --toolchain-root')
        self.assertLess(delete_bytecode, generate_manifest)
        self.assertLess(delete_caches, generate_manifest)

    def test_package_validates_and_copies_only_the_exact_da3_runtime(self) -> None:
        self.assertIn('DA3_PAYLOAD_VALIDATOR="$ROOT/scripts/toolchain/validate_da3_payload.py"', self.script)
        self.assertEqual(
            self.script.count('python3 "$DA3_PAYLOAD_VALIDATOR" --root'),
            2,
        )
        self.assertNotIn('cp -R "$DA3_ROOT" "$OUT/da3_mps"', self.script)
        for relative in ("bin", "python", "app", "vendor", "licenses"):
            self.assertIn(f'cp -R "$DA3_ROOT/{relative}" "$OUT/da3_mps/{relative}"', self.script)
        self.assertIn(
            'install -m 0644 "$DA3_ROOT/build_info.json" "$OUT/da3_mps/build_info.json"',
            self.script,
        )

    def test_forbidden_payload_scan_consumes_find_output(self) -> None:
        self.assertNotIn("grep -Eqi", self.script)
        self.assertIn("grep -Ei", self.script)


class Da3BuilderLicenseTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.script = (SCRIPT.parent / "build_da3_mps.sh").read_text(encoding="utf-8")

    def test_builder_installs_checksum_pinned_missing_notices(self) -> None:
        for expected in (
            "e4c1a74c66bd5290364ea2b36c97cd724b247357",
            ANTLR_LICENSE_SHA256,
            "python-package-upstream-notices.json",
            "UPSTREAM_LICENSE.txt",
        ):
            self.assertIn(expected, self.script)
        self.assertNotIn("FAISS_LICENSE", self.script)
        self.assertNotIn("TOKENIZERS_LICENSE", self.script)

    def test_builder_records_and_validates_exact_staged_runtime(self) -> None:
        self.assertIn('"supplemental_license_manifest_sha256"', self.script)
        self.assertIn(
            'DA3_PAYLOAD_VALIDATOR="$ROOT/scripts/toolchain/validate_da3_payload.py"',
            self.script,
        )
        materialize = self.script.rindex("materialize_runtime_symlinks")
        validate = self.script.rindex('python3 "$DA3_PAYLOAD_VALIDATOR" --root')
        self.assertLess(materialize, validate)

    def test_builder_verifies_reviewed_model_bytes_before_recording_metadata(
        self,
    ) -> None:
        self.assertIn(
            'DA3_MODEL_LOCK="$ROOT/scripts/toolchain/da3-model-lock.json"',
            self.script,
        )
        verify_size = self.script.index('path.stat().st_size != artifact["size_bytes"]')
        verify_hash = self.script.index('sha256(path) != artifact["sha256"]')
        write_metadata = self.script.index(
            '(target / "easysplat_model_info.json").write_text('
        )
        self.assertLess(verify_size, write_metadata)
        self.assertLess(verify_hash, write_metadata)

    def test_builder_pins_whitespace_clean_runtime_patch(self) -> None:
        self.assertIn(
            'DA3_RUNTIME_PATCH_SHA256="885ade24b466ab3dff04169ff47dd3813d64c40ffd0bdb7dd9b779de97a370eb"',
            self.script,
        )

    def test_builder_recreates_complete_install_and_rejects_stale_opencv(self) -> None:
        clean = self.script.index('rm -rf "$INSTALL_DIR"')
        install = self.script.index("pip_install \\\n")
        reject = self.script.index("opencv-python-headless survived the clean install")
        self.assertIn('case "$INSTALL_DIR" in', self.script)
        self.assertNotIn('rm -rf "$PYTHON_DIR"', self.script)
        self.assertLess(clean, install)
        self.assertLess(install, reject)

    def test_builder_removes_build_only_pip_from_shipping_runtime(self) -> None:
        install = self.script.index("pip_install \\\n")
        strip_tools = self.script.rindex("remove_build_only_python_tools")
        verify_runtime = self.script.rindex("verify_torch_mps")
        self.assertIn('"$PYTHON_DIR/lib/python3.13/ensurepip"', self.script)
        self.assertIn('"$site_packages"/pip-*.dist-info', self.script)
        self.assertIn('rm -f "$PYTHON_DIR/bin/pip"', self.script)
        self.assertLess(install, strip_tools)
        self.assertLess(strip_tools, verify_runtime)


class RetiredDa3ColmapBridgeTests(unittest.TestCase):
    def test_bridge_sources_and_tests_are_deleted(self) -> None:
        root = SCRIPT.parents[2]
        for relative in (
            "Tools/Da3Sfm/colmap_launcher.c",
            "Tools/Da3Sfm/easysplat_da3_sfm/colmap_cli.py",
            "Tools/Da3Sfm/tests/test_colmap_cli.py",
        ):
            self.assertFalse((root / relative).exists(), relative)

    def test_da3_builder_and_lock_have_no_python_colmap_runtime(self) -> None:
        root = SCRIPT.parents[2]
        surfaces = "\n".join(
            (root / relative).read_text(encoding="utf-8")
            for relative in (
                "Tools/Da3Sfm/requirements.in",
                "Tools/Da3Sfm/requirements.txt",
                "scripts/toolchain/build_da3_mps.sh",
            )
        )
        for retired in (
            "pycolmap",
            "easysplat_colmap",
            "colmap_cli",
            "COLMAP_LAUNCHER",
            "colmap_launcher",
            "--self-check",
        ):
            self.assertNotIn(retired, surfaces)

    def test_supply_chain_has_no_retired_python_colmap_component(self) -> None:
        source = SCRIPT.read_text(encoding="utf-8")
        for retired in (
            "PYCOLMAP_VERSION",
            "faiss_component",
            '"easysplat-da3-bridge"',
            'if slug == "pycolmap"',
        ):
            self.assertNotIn(retired, source)
        self.assertIn('"easysplat-da3-runner"', source)


if __name__ == "__main__":
    unittest.main()
