import email
import base64
import hashlib
import importlib.util
import json
import tempfile
import unittest
from pathlib import Path


SCRIPT = Path(__file__).resolve().parents[1] / "generate_supply_chain_manifest.py"
SPEC = importlib.util.spec_from_file_location("generate_supply_chain_manifest", SCRIPT)
assert SPEC and SPEC.loader
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


PYCOLMAP_WHEEL_SHA256 = (
    "46d2108eaa1191584796a63f17a5f0204d59e30ec5f2778489ce44e19fff6ac2"
)
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
            top_level = site_packages / "setuptools-81.0.0.dist-info/METADATA"
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

    def _write_fixture(self, root: Path) -> dict[str, dict[str, str]]:
        notices = []
        entries = (
            (
                "antlr4-python3-runtime",
                "4.9.3",
                "antlr4_python3_runtime-4.9.3.dist-info",
                "UPSTREAM_LICENSE.txt",
                b"antlr license",
            ),
        )
        reviewed: dict[str, dict[str, str]] = {}
        for package, version, dist_info, filename, content in entries:
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
                "license": "BSD-3-Clause",
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

            MODULE.validate_supplemental_license_receipts(root, reviewed=reviewed)

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
            MODULE.component_build_command("easysplat-colmap-bridge", {}),
            "./scripts/toolchain/build_da3_mps.sh",
        )
        self.assertEqual(
            MODULE.component_build_command("python:numpy", {}),
            "./scripts/toolchain/build_da3_mps.sh",
        )
        self.assertEqual(
            MODULE.component_build_command("msplat", {}),
            "./scripts/toolchain/build_msplat.sh",
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

    def test_missing_non_bytecode_record_member_fails_closed(self) -> None:
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


class ColmapBridgeComponentTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary_directory = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary_directory.name)
        (self.root / "bin").mkdir()
        (self.root / "provenance").mkdir()
        (self.root / "da3_mps").mkdir()
        (self.root / "licenses" / "EasySplat").mkdir(parents=True)
        self.executable = self.root / "bin" / "colmap"
        self.executable.write_bytes(b"signed bridge")
        (self.root / "licenses" / "EasySplat" / "LICENSE").write_text(
            "MIT\n", encoding="utf-8"
        )
        self.receipt = {
            "toolchain_name": "colmap",
            "source_url": "https://github.com/colmap/colmap",
            "source_repo": "https://github.com/colmap/colmap",
            "source_version": "3.13.0",
            "source_commit": f"sha256:{PYCOLMAP_WHEEL_SHA256}",
            "license": "BSD-3-Clause",
            "backend": "pycolmap",
            "runtime": "bundled-python",
            "bridge_source": "Tools/Da3Sfm/easysplat_da3_sfm/colmap_cli.py",
            "bridge_source_sha256": "1" * 64,
            "supplemental_license_manifest_sha256": "2" * 64,
            "executable_sha256": hashlib.sha256(
                self.executable.read_bytes()
            ).hexdigest(),
        }
        (self.root / "da3_mps" / "build_info.json").write_text(
            json.dumps(
                {
                    "colmap_bridge_source": self.receipt["bridge_source"],
                    "colmap_bridge_source_sha256": self.receipt["bridge_source_sha256"],
                    "supplemental_license_manifest_sha256": self.receipt[
                        "supplemental_license_manifest_sha256"
                    ],
                }
            ),
            encoding="utf-8",
        )
        self._write_receipt()
        self.python_components = {
            "python:pycolmap": {
                "version": "3.13.0",
                "artifactSha256": PYCOLMAP_WHEEL_SHA256,
            },
        }

    def tearDown(self) -> None:
        self.temporary_directory.cleanup()

    def _write_receipt(self) -> None:
        (self.root / "provenance" / "colmap.json").write_text(
            json.dumps(self.receipt), encoding="utf-8"
        )

    def test_bridge_owns_launcher_and_depends_on_exact_python_runtime(self) -> None:
        component = MODULE.colmap_bridge_component(
            self.root,
            version="2.0.0",
            repository_revision="a" * 40,
            python_components=self.python_components,
        )

        self.assertEqual(component["id"], "easysplat-colmap-bridge")
        self.assertEqual(component["linkage"], "python-launcher")
        self.assertEqual(
            component["dependencies"],
            [
                "python-build-standalone",
                "python:pycolmap",
            ],
        )

    def test_bridge_rejects_receipt_not_bound_to_packaged_executable(self) -> None:
        self.receipt["executable_sha256"] = "f" * 64
        self._write_receipt()

        with self.assertRaisesRegex(SystemExit, "installed executable"):
            MODULE.colmap_bridge_component(
                self.root,
                version="2.0.0",
                repository_revision="a" * 40,
                python_components=self.python_components,
            )

    def test_bridge_rejects_receipt_not_bound_to_pycolmap_wheel(self) -> None:
        self.receipt["source_commit"] = f"sha256:{'f' * 64}"
        self._write_receipt()

        with self.assertRaisesRegex(SystemExit, "PyCOLMAP wheel"):
            MODULE.colmap_bridge_component(
                self.root,
                version="2.0.0",
                repository_revision="a" * 40,
                python_components=self.python_components,
            )


class Da3BridgeReceiptTests(unittest.TestCase):
    def test_receipt_binds_final_staged_launcher_and_bridge_source(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            launcher = root / "da3_mps/bin/easysplat_colmap"
            bridge = root / "da3_mps/app/easysplat_da3_sfm/colmap_cli.py"
            manifest = root / "da3_mps/licenses/python-package-upstream-notices.json"
            for path, content in (
                (launcher, b"launcher"),
                (bridge, b"bridge"),
                (manifest, b"manifest"),
            ):
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_bytes(content)
            receipt = {
                "colmap_launcher_sha256": hashlib.sha256(
                    launcher.read_bytes()
                ).hexdigest(),
                "colmap_bridge_source_sha256": hashlib.sha256(
                    bridge.read_bytes()
                ).hexdigest(),
                "supplemental_license_manifest_sha256": hashlib.sha256(
                    manifest.read_bytes()
                ).hexdigest(),
            }

            MODULE.validate_da3_bridge_receipt(root, receipt)
            launcher.write_bytes(b"mutated")
            with self.assertRaisesRegex(SystemExit, "launcher hash"):
                MODULE.validate_da3_bridge_receipt(root, receipt)


class PackageScriptTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.script = (SCRIPT.parent / "package_toolchain.sh").read_text(
            encoding="utf-8"
        )

    def test_package_uses_staged_pycolmap_bridge_without_native_stack(self) -> None:
        self.assertIn('da3_mps/bin/easysplat_colmap" "$BIN/colmap', self.script)
        for obsolete in (
            "COLMAP_INSTALL",
            "CERES_INSTALL",
            "SUITESPARSE_INSTALL",
            "OPENIMAGEIO_INSTALL",
            "dependency-origins.tsv",
            "--dependency-origins",
        ):
            self.assertNotIn(obsolete, self.script)

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
            "scripts/toolchain/validate_native_msplat.sh",
        ):
            self.assertIn(source, self.script)
        self.assertIn("status --porcelain", self.script)
        self.assertNotIn("--ignored", self.script)

    def test_package_probes_only_commands_exposed_by_bridge(self) -> None:
        self.assertIn('"$BIN/colmap" point_triangulator -h', self.script)
        self.assertIn('"$BIN/colmap" image_undistorter -h', self.script)
        self.assertNotIn('"$BIN/colmap" global_mapper -h', self.script)

    def test_package_preserves_signed_wheel_bytes(self) -> None:
        self.assertNotIn("lipo -thin", self.script)
        self.assertNotIn("codesign --force", self.script)
        self.assertIn('/usr/bin/codesign --verify --strict "$file"', self.script)

    def test_package_checks_staged_colmap_launcher_against_builder_receipt(
        self,
    ) -> None:
        self.assertIn('"colmap_launcher_sha256"', self.script)
        self.assertIn("DA3 COLMAP launcher does not match build_info.json", self.script)

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
        generate_manifest = self.script.index('"$SUPPLY_CHAIN_GENERATOR" \\\n')
        self.assertLess(delete_bytecode, generate_manifest)
        self.assertLess(delete_caches, generate_manifest)

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
        self.assertNotIn("TOKENIZERS_LICENSE", self.script)

    def test_builder_records_exact_staged_bridge_sources(self) -> None:
        self.assertIn('"colmap_bridge_source_sha256"', self.script)
        self.assertIn('"supplemental_license_manifest_sha256"', self.script)

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


if __name__ == "__main__":
    unittest.main()
