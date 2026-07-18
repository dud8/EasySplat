#!/usr/bin/env python3
from __future__ import annotations

import hashlib
import json
import os
import re
import shutil
import sqlite3
import stat
import struct
import subprocess
import tempfile
import unittest
import zlib
from pathlib import Path


ROOT = Path(__file__).resolve().parents[3]
BUILD_SCRIPT = ROOT / "scripts/toolchain/build_colmap.sh"
BUILD_IMPLEMENTATION = ROOT / "scripts/toolchain/build_colmap_impl.sh"
RELEASE_SCRIPT_TEST = ROOT / "scripts/ci/test_release_scripts.sh"
OVERLAY_ROOT = ROOT / "Tools/NativeColmap"
PATCH_PATH = ROOT / "scripts/toolchain/patches/colmap-4.1.0-easysplat.patch"

REQUIRED_OPTIONS = (
    "database_path",
    "output_pair_list_path",
    "query_image_list_path",
    "excluded_pair_list_path",
    "num_images",
    "returned_neighbor_count",
    "minimum_frame_separation",
    "num_visual_words",
    "max_features_per_image",
    "max_training_descriptors",
    "memory_budget_bytes",
    "num_iterations",
    "num_rounds",
    "num_checks",
    "num_threads",
)

SHIPPING_COMMANDS = (
    "feature_extractor",
    "matches_importer",
    "local_vocab_retriever",
    "mapper",
    "point_triangulator",
    "bundle_adjuster",
    "model_analyzer",
    "image_undistorter",
    "model_converter",
)

PATCHED_COLMAP_PATHS = (
    "CMakeLists.txt",
    "cmake/FindDependencies.cmake",
    "src/colmap/controllers/CMakeLists.txt",
    "src/colmap/controllers/feature_extraction.cc",
    "src/colmap/controllers/option_manager.cc",
    "src/colmap/controllers/option_manager.h",
    "src/colmap/controllers/option_manager_test.cc",
    "src/colmap/controllers/undistorters.cc",
    "src/colmap/controllers/undistorters.h",
    "src/colmap/estimators/CMakeLists.txt",
    "src/colmap/exe/CMakeLists.txt",
    "src/colmap/exe/colmap.cc",
    "src/colmap/exe/image.cc",
    "src/colmap/exe/sfm.cc",
    "src/colmap/exe/sfm.h",
    "src/colmap/feature/CMakeLists.txt",
    "src/colmap/feature/extractor.cc",
    "src/colmap/feature/extractor.h",
    "src/colmap/feature/matcher.cc",
    "src/colmap/feature/matcher.h",
    "src/colmap/feature/sift.cc",
    "src/colmap/feature/sift.h",
    "src/colmap/feature/types.cc",
    "src/colmap/feature/types.h",
    "src/colmap/math/CMakeLists.txt",
    "src/colmap/optim/CMakeLists.txt",
    "src/colmap/retrieval/resources.cc",
    "src/colmap/retrieval/resources.h",
    "src/colmap/scene/CMakeLists.txt",
    "src/colmap/sfm/CMakeLists.txt",
    "src/thirdparty/CMakeLists.txt",
)

FROZEN_ORACLE_OUTPUTS = {
    "mixed_keypoints": (
        b"000-alpha.jpg 001-bravo.jpg\n"
        b"000-alpha.jpg 002-charlie.jpg\n"
        b"001-bravo.jpg 002-charlie.jpg\n"
        b"003-delta.jpg 000-alpha.jpg\n"
        b"003-delta.jpg 001-bravo.jpg\n"
    ),
    "sampled_features": (
        b"000.jpg 001.jpg\n"
        b"000.jpg 002.jpg\n"
        b"001.jpg 002.jpg\n"
        b"003.jpg 000.jpg\n"
        b"003.jpg 001.jpg\n"
    ),
    "tied_scales": (
        b"000.jpg 001.jpg\n"
        b"000.jpg 002.jpg\n"
        b"001.jpg 002.jpg\n"
        b"001.jpg 003.jpg\n"
        b"002.jpg 003.jpg\n"
    ),
    "non_tied_queries": (
        b"000-alpha.jpg 001-bravo.jpg\n"
        b"000-alpha.jpg 002-charlie.jpg\n"
        b"002-charlie.jpg 001-bravo.jpg\n"
    ),
}

FROZEN_ORACLE_SHA256 = {
    "mixed_keypoints": "7bded7db318146a967b8476cb1d0b2fddf3e0c43d8f4aad05a2e951b5201e2d3",
    "sampled_features": "2fc20a37059be4f4333d681f17fd8a2b5222317e168ef4539fe1d4ca8b474e1f",
    "tied_scales": "ee43396d07eff174611702f19c42c6fcc97ee9d25b80e6978b2e87add7f29fda",
    "non_tied_queries": "a34c6626aa355aaf185d13b5643256d2752ee8c7ff7fc5334a5be72f19b6ce9a",
}


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        while chunk := stream.read(1024 * 1024):
            digest.update(chunk)
    return digest.hexdigest()


def portable_tree_sha256(root: Path) -> str:
    digest = hashlib.sha256()
    paths = [
        root,
        *sorted(root.rglob("*"), key=lambda path: path.relative_to(root).as_posix()),
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
            raise AssertionError(f"unsupported fixture entry: {relative}")
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


def write_test_png(path: Path) -> None:
    def chunk(kind: bytes, payload: bytes) -> bytes:
        checksum = zlib.crc32(kind + payload) & 0xFFFFFFFF
        return (
            struct.pack(">I", len(payload))
            + kind
            + payload
            + struct.pack(">I", checksum)
        )

    pixels = b"\x00\xff\x00\x00\x00\xff\x00\x00\x00\xff\xff\xff\xff"
    path.write_bytes(
        b"\x89PNG\r\n\x1a\n"
        + chunk(b"IHDR", struct.pack(">IIBBBBB", 2, 2, 8, 2, 0, 0, 0))
        + chunk(b"IDAT", zlib.compress(pixels))
        + chunk(b"IEND", b"")
    )


def descriptor(center: int, row: int) -> bytes:
    return bytes((center + row * 3 + column % 7) % 256 for column in range(128))


def keypoints4(count: int, *, scale_offset: float = 0.0) -> list[tuple[float, ...]]:
    return [
        (float(row) + 0.5, float(row) + 1.5, scale_offset + row + 1.0, 0.0)
        for row in range(count)
    ]


def keypoints6(count: int, *, scale_offset: float = 0.0) -> list[tuple[float, ...]]:
    return [
        (
            float(row) + 0.5,
            float(row) + 1.5,
            scale_offset + row + 1.0,
            0.0,
            0.0,
            scale_offset + row + 1.0,
        )
        for row in range(count)
    ]


def create_feature_database(
    path: Path,
    images: list[tuple[str, list[tuple[float, ...]], list[bytes]]],
    *,
    descriptor_type_column: bool = True,
) -> None:
    database = sqlite3.connect(path)
    try:
        database.execute("CREATE TABLE images(image_id INTEGER, name TEXT)")
        database.execute(
            "CREATE TABLE keypoints(image_id INTEGER, rows INTEGER, cols INTEGER, data BLOB)"
        )
        descriptor_columns = (
            "image_id INTEGER, rows INTEGER, cols INTEGER, data BLOB, type INTEGER"
            if descriptor_type_column
            else "image_id INTEGER, rows INTEGER, cols INTEGER, data BLOB"
        )
        database.execute(f"CREATE TABLE descriptors({descriptor_columns})")
        for offset, (name, keypoints, descriptors) in enumerate(images):
            image_id = 10 + offset * 7
            database.execute(
                "INSERT INTO images(image_id, name) VALUES (?, ?)",
                (image_id, name),
            )
            keypoint_columns = len(keypoints[0]) if keypoints else 4
            keypoint_values = [value for row in keypoints for value in row]
            keypoint_blob = (
                struct.pack(f"<{len(keypoint_values)}f", *keypoint_values)
                if keypoint_values
                else b""
            )
            database.execute(
                "INSERT INTO keypoints(image_id, rows, cols, data) VALUES (?, ?, ?, ?)",
                (image_id, len(keypoints), keypoint_columns, keypoint_blob),
            )
            descriptor_blob = b"".join(descriptors)
            if descriptor_type_column:
                database.execute(
                    "INSERT INTO descriptors(image_id, rows, cols, data, type) "
                    "VALUES (?, ?, 128, ?, 0)",
                    (image_id, len(descriptors), descriptor_blob),
                )
            else:
                database.execute(
                    "INSERT INTO descriptors(image_id, rows, cols, data) "
                    "VALUES (?, ?, 128, ?)",
                    (image_id, len(descriptors), descriptor_blob),
                )
        database.commit()
    finally:
        database.close()


def ordinary_images(
    *, rows: int = 20
) -> list[tuple[str, list[tuple[float, ...]], list[bytes]]]:
    return [
        (
            f"{index:03d}-{name}.jpg",
            keypoints4(rows, scale_offset=float(index)),
            [descriptor(center, row) for row in range(rows)],
        )
        for index, (name, center) in enumerate(
            (("alpha", 3), ("bravo", 22), ("charlie", 97), ("delta", 211))
        )
    ]


class SourceContractTests(unittest.TestCase):
    def test_frozen_oracle_cases_do_not_require_the_removed_python_runtime(
        self,
    ) -> None:
        source = Path(__file__).read_text(encoding="utf-8")
        forbidden_skip = "self." + (
            'skipTest("set EASYSPLAT_PYCOLMAP_COLMAP_BIN for oracle parity")'
        )
        self.assertNotIn(forbidden_skip, source)
        self.assertEqual(
            {
                name: hashlib.sha256(output).hexdigest()
                for name, output in FROZEN_ORACLE_OUTPUTS.items()
            },
            FROZEN_ORACLE_SHA256,
        )

    def test_configured_fault_shim_compiler_failure_is_fatal(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            compiler = root / "clang"
            compiler.write_text("#!/bin/sh\nexit 23\n", encoding="utf-8")
            compiler.chmod(0o700)
            sdk = root / "sdk"
            sdk.mkdir()
            old_compiler = os.environ.get("EASYSPLAT_TEST_CLANG")
            old_sdk = os.environ.get("EASYSPLAT_TEST_SDK")
            os.environ["EASYSPLAT_TEST_CLANG"] = str(compiler)
            os.environ["EASYSPLAT_TEST_SDK"] = str(sdk)
            try:
                with self.assertRaisesRegex(
                    RuntimeError,
                    "could not build required fsync fault shim",
                ):
                    NativeRetrieverTests._build_fault_shims()
            finally:
                if NativeRetrieverTests.fault_shim_root is not None:
                    shutil.rmtree(
                        NativeRetrieverTests.fault_shim_root,
                        ignore_errors=True,
                    )
                    NativeRetrieverTests.fault_shim_root = None
                if old_compiler is None:
                    os.environ.pop("EASYSPLAT_TEST_CLANG", None)
                else:
                    os.environ["EASYSPLAT_TEST_CLANG"] = old_compiler
                if old_sdk is None:
                    os.environ.pop("EASYSPLAT_TEST_SDK", None)
                else:
                    os.environ["EASYSPLAT_TEST_SDK"] = old_sdk

    def test_reviewed_overlay_and_registration_patch_are_tracked(self) -> None:
        header = OVERLAY_ROOT / "local_vocab_retriever.h"
        source = OVERLAY_ROOT / "local_vocab_retriever.cc"
        self.assertTrue(header.is_file(), header)
        self.assertTrue(source.is_file(), source)
        self.assertTrue(PATCH_PATH.is_file(), PATCH_PATH)
        patch = PATCH_PATH.read_text(encoding="utf-8")
        self.assertIn('#include "colmap/exe/local_vocab_retriever.h"', patch)
        self.assertIn('"local_vocab_retriever"', patch)
        self.assertIn("local_vocab_retriever.cc", patch)
        self.assertIn("FAISS_ENABLE_METAL OFF", patch)
        self.assertLess(PATCH_PATH.stat().st_size, 76_800)

    def test_patch_has_the_exact_reviewed_source_surface(self) -> None:
        patch = PATCH_PATH.read_text(encoding="utf-8")
        paths = tuple(re.findall(r"^diff --git a/(\S+) b/\1$", patch, re.MULTILINE))
        self.assertEqual(paths, PATCHED_COLMAP_PATHS)

    def test_patch_removes_the_unreachable_learned_feature_surface(self) -> None:
        patch = PATCH_PATH.read_text(encoding="utf-8")
        surviving_lines = "\n".join(
            line[1:]
            for line in patch.splitlines()
            if (line.startswith("+") and not line.startswith("+++"))
            or line.startswith(" ")
        )
        for removed_surface in (
            "aliked.h aliked.cc",
            "onnx_matchers.h onnx_matchers.cc",
            "onnx_utils.h onnx_utils.cc",
            "AlikedExtraction.",
            "AlikedMatching.",
            "SiftMatching.lightglue_",
            "SIFT_LIGHTGLUE",
            "ALIKED_N16ROT",
            "ALIKED_N32",
            "ALIKED_BRUTEFORCE",
            "ALIKED_LIGHTGLUE",
            "CreateAlikedFeatureExtractor",
            "CreateAlikedFeatureMatcher",
            "CreateLightGlueONNXFeatureMatcher",
            "kDefaultAliked",
            "kDefaultSiftLightGlueFeatureMatcherUri",
        ):
            self.assertNotIn(removed_surface, surviving_lines)

    def test_patch_removes_cholmod_and_the_dead_global_sfm_surface(self) -> None:
        patch = PATCH_PATH.read_text(encoding="utf-8")
        surviving_lines = "\n".join(
            line[1:]
            for line in patch.splitlines()
            if (line.startswith("+") and not line.startswith("+++"))
            or line.startswith(" ")
        )
        for removed_surface in (
            "find_package(CHOLMOD",
            "CHOLMOD::CHOLMOD",
            "least_absolute_deviations.h least_absolute_deviations.cc",
            "sparse_cholesky.h sparse_cholesky.cc",
            "rotation_averaging.h rotation_averaging.cc",
            "rotation_averaging_impl.h rotation_averaging_impl.cc",
            "global_mapper.h global_mapper.cc",
            "global_pipeline.h global_pipeline.cc",
            '#include "colmap/controllers/global_pipeline.h"',
            '#include "colmap/controllers/rotation_averaging.h"',
            '#include "colmap/sfm/global_mapper.h"',
            "AddGlobalMapperOptions",
            "GlobalPipelineOptions",
            "RunGlobalMapper",
            "RunRotationAverager",
            "LeastAbsoluteDeviationSolver",
            "SparseCholeskyWithFallbackSolver",
        ):
            self.assertNotIn(removed_surface, surviving_lines)

    def test_patch_preserves_incremental_mapping_triangulation_and_ba(self) -> None:
        patch = PATCH_PATH.read_text(encoding="utf-8")
        surviving_lines = "\n".join(
            line[1:]
            for line in patch.splitlines()
            if (line.startswith("+") and not line.startswith("+++"))
            or line.startswith(" ")
        )
        removed_lines = "\n".join(
            line[1:]
            for line in patch.splitlines()
            if line.startswith("-") and not line.startswith("---")
        )
        for retained_build_or_command_surface in (
            "incremental_pipeline.h incremental_pipeline.cc",
            "incremental_mapper_impl.h incremental_mapper_impl.cc",
            "incremental_mapper.h incremental_mapper.cc",
            "incremental_triangulator.h incremental_triangulator.cc",
            "bundle_adjustment.h bundle_adjustment.cc",
            "int RunBundleAdjuster(int argc, char** argv)",
            "int RunMapper(int argc, char** argv)",
            "int RunPointTriangulator(int argc, char** argv)",
            'commands.emplace_back("mapper", &colmap::RunMapper)',
            'commands.emplace_back("point_triangulator", '
            "&colmap::RunPointTriangulator)",
            'commands.emplace_back("bundle_adjuster", &colmap::RunBundleAdjuster)',
        ):
            self.assertIn(retained_build_or_command_surface, surviving_lines)
        for retained_entry_point in (
            "bool RunIncrementalMapperImpl(",
            "void RunPointTriangulatorImpl(",
        ):
            self.assertNotIn(retained_entry_point, removed_lines)

    def test_patch_exposes_only_the_shipping_commands(self) -> None:
        patch = PATCH_PATH.read_text(encoding="utf-8")
        surviving_lines = "\n".join(
            line[1:]
            for line in patch.splitlines()
            if (line.startswith("+") and not line.startswith("+++"))
            or line.startswith(" ")
        )
        commands = tuple(
            re.findall(
                r'^\s*commands\.emplace_back\("([^"]+)"',
                surviving_lines,
                re.MULTILINE,
            )
        )
        self.assertEqual(commands, SHIPPING_COMMANDS)
        for removed_surface in (
            '#include "colmap/exe/database.h"',
            '#include "colmap/exe/gui.h"',
            '#include "colmap/exe/vocab_tree.h"',
            'commands.emplace_back("automatic_reconstructor"',
            'commands.emplace_back("exhaustive_matcher"',
            'commands.emplace_back("global_mapper"',
            'commands.emplace_back("hierarchical_mapper"',
            'commands.emplace_back("sequential_matcher"',
        ):
            self.assertNotIn(removed_surface, surviving_lines)

    def test_patch_removes_metis_and_hierarchical_reconstruction(self) -> None:
        patch = PATCH_PATH.read_text(encoding="utf-8")
        required_files = (
            "CMakeLists.txt",
            "cmake/FindDependencies.cmake",
            "src/colmap/math/CMakeLists.txt",
            "src/colmap/scene/CMakeLists.txt",
            "src/colmap/controllers/CMakeLists.txt",
            "src/colmap/controllers/undistorters.cc",
            "src/colmap/controllers/undistorters.h",
            "src/colmap/exe/CMakeLists.txt",
            "src/colmap/exe/colmap.cc",
            "src/colmap/exe/image.cc",
            "src/colmap/exe/sfm.cc",
            "src/colmap/exe/sfm.h",
            "src/thirdparty/CMakeLists.txt",
        )
        for path in required_files:
            self.assertIn(f"diff --git a/{path} b/{path}", patch)

        added_lines = "\n".join(
            line[1:]
            for line in patch.splitlines()
            if line.startswith("+") and not line.startswith("+++")
        )
        for removed_surface in (
            "find_package(Metis",
            "graph_cut.h graph_cut.cc",
            "scene_clustering.h scene_clustering.cc",
            "automatic_reconstruction.h automatic_reconstruction.cc",
            "hierarchical_pipeline.h hierarchical_pipeline.cc",
            '#include "colmap/controllers/automatic_reconstruction.h"',
            '#include "colmap/controllers/hierarchical_pipeline.h"',
            "RunAutomaticReconstructor",
            "RunHierarchicalMapper",
            "PRIVATE_LINK_LIBS\n        Boost::boost\n        metis",
        ):
            self.assertNotIn(removed_surface, added_lines)
        self.assertRegex(
            added_lines,
            r"if\(MVS_ENABLED\)\n\s+add_subdirectory\(PoissonRecon\)\nendif\(\)",
        )
        self.assertIn("+    COLMAP_ADD_SOURCE_DIR(src/thirdparty/PoissonRecon ", patch)
        self.assertIn(
            "+    list(APPEND COLMAP_EXPORT_LIBS colmap_mvs colmap_poisson_recon)",
            patch,
        )
        removed_lines = "\n".join(
            line[1:]
            for line in patch.splitlines()
            if line.startswith("-") and not line.startswith("---")
        )
        for stale_generated_command in (
            "patch_match_stereo",
            "stereo_fusion",
            "poisson_mesher",
            "delaunay_mesher",
        ):
            self.assertIn(
                f"$COLMAP_EXE_PATH/colmap {stale_generated_command}",
                removed_lines,
            )
        self.assertIn('"{COLMAP}"', added_lines)
        for removed_undistorter_surface in (
            'else if (output_type == "PMVS")',
            'else if (output_type == "CMP-MVS")',
            "PMVSUndistorter::Options",
            "CMPMVSUndistorter::Options",
        ):
            self.assertIn(removed_undistorter_surface, removed_lines)

    def test_patch_removes_dead_dense_undistorter_workspace(self) -> None:
        patch = PATCH_PATH.read_text(encoding="utf-8")
        removed_lines = "\n".join(
            line[1:]
            for line in patch.splitlines()
            if line.startswith("-") and not line.startswith("---")
        )
        added_lines = "\n".join(
            line[1:]
            for line in patch.splitlines()
            if line.startswith("+") and not line.startswith("+++")
        )
        for dead_surface in (
            'CreateDirIfNotExists(output_path_ / "stereo")',
            'reconstruction_.CreateImageDirs(output_path_ / "stereo"',
            "WritePatchMatchConfig(image_names)",
            "WriteFusionConfig(image_names)",
            "COLMAPUndistorter::WritePatchMatchConfig",
            "COLMAPUndistorter::WriteFusionConfig",
            "num_patch_match_src_images",
        ):
            self.assertIn(dead_surface, removed_lines)
            self.assertNotIn(dead_surface, added_lines)

    def test_builder_declares_the_exact_native_command_contract(self) -> None:
        script = BUILD_IMPLEMENTATION.read_text(encoding="utf-8")
        self.assertIn("-DCMAKE_EXE_LINKER_FLAGS=-Wl,-dead_strip", script)
        self.assertIn("-ffile-prefix-map=${ROOT}=/easysplat", script)
        self.assertIn("-fdebug-prefix-map=${ROOT}=/easysplat", script)
        self.assertIn(
            "RunBundleAdjuster\\nRunFeatureExtractor\\nRunImageUndistorter",
            script,
        )
        self.assertIn("RunPointTriangulator\\nRunPointTriangulatorImpl", script)
        self.assertNotIn("RunExhaustiveMatcher|RunSequentialMatcher", script)
        self.assertIn("PMVSUndistorter|CMPMVSUndistorter|PMVS_EXE_PATH", script)
        for receipt in (
            '"$COLMAP_SUPPORT_INSTALL/build_info.json"',
            '"$CERES_INSTALL/build_info.json"',
            '"$OPENIMAGEIO_INSTALL/build_info.json"',
        ):
            self.assertIn(receipt, script)
        for receipt_field in (
            '"build_inputs"',
            '"builder_sha256"',
            '"dependency_receipt_sha256"',
            '"dependency_library_sha256"',
            '"source_date_epoch"',
            '"build_options"',
            '"build_tools"',
            '"sdk"',
            '"settings_sha256"',
            '"xcode_version"',
        ):
            self.assertIn(receipt_field, script)
        for compiler_or_sdk_pin in (
            'DEVELOPER_DIR_PATH="$(/usr/bin/xcode-select -p)"',
            'export DEVELOPER_DIR="$DEVELOPER_DIR_PATH"',
            'MACOS_SDK_PATH="$(DEVELOPER_DIR="$DEVELOPER_DIR_PATH" '
            '/usr/bin/xcrun --sdk macosx --show-sdk-path)"',
            'MACOS_SDK_VERSION="$(DEVELOPER_DIR="$DEVELOPER_DIR_PATH" '
            '/usr/bin/xcrun --sdk macosx --show-sdk-version)"',
            'MACOS_SDK_BUILD_VERSION="$(DEVELOPER_DIR="$DEVELOPER_DIR_PATH" '
            '/usr/bin/xcrun --sdk macosx --show-sdk-build-version)"',
            'SELECTED_C_COMPILER="$(DEVELOPER_DIR="$DEVELOPER_DIR_PATH" '
            '/usr/bin/xcrun --find clang)"',
            'SELECTED_CXX_COMPILER="$(DEVELOPER_DIR="$DEVELOPER_DIR_PATH" '
            '/usr/bin/xcrun --find clang++)"',
            '-DCMAKE_C_COMPILER="$SELECTED_C_COMPILER"',
            '-DCMAKE_CXX_COMPILER="$SELECTED_CXX_COMPILER"',
            '-DCMAKE_LINKER="$SELECTED_LINKER"',
            '-DCMAKE_AR="$SELECTED_ARCHIVER"',
            '-DCMAKE_RANLIB="$SELECTED_RANLIB"',
            '-DCMAKE_OSX_SYSROOT="$MACOS_SDK_PATH"',
            'cache_is CMAKE_C_COMPILER "$SELECTED_C_COMPILER"',
            'cache_is CMAKE_CXX_COMPILER "$SELECTED_CXX_COMPILER"',
            'cache_is CMAKE_OSX_SYSROOT "$MACOS_SDK_PATH"',
            '"build_version": sdk_build_version',
            '"settings_sha256": sha256(sdk_settings_path)',
            '"version": sdk_version',
            '"xcode_version": xcode_version',
        ):
            self.assertIn(compiler_or_sdk_pin, script)
        self.assertNotIn("datetime.now", script)
        self.assertNotIn("brew --prefix", script)
        enabled_block = script.split('"enabled_capabilities": [', 1)[1].split("],", 1)[
            0
        ]
        enabled = tuple(re.findall(r'"([a-z_]+)"', enabled_block))
        self.assertEqual(enabled, SHIPPING_COMMANDS)

        validation = script.split("validate_commands() {", 1)[1].split("\n}", 1)[0]
        command_loop = validation.split("for command in \\\n", 1)[1].split("; do", 1)[0]
        validated = tuple(
            line.strip().removesuffix("\\").strip()
            for line in command_loop.splitlines()
            if line.strip()
        )
        self.assertEqual(validated, SHIPPING_COMMANDS)
        self.assertIn("--output_type PMVS", validation)
        self.assertIn("image undistorter did not reject PMVS", validation)
        for unused in ("sequential_matcher", "exhaustive_matcher"):
            self.assertNotIn(unused, validation)
        self.assertNotIn("metis_prefix", script)
        self.assertNotIn("-DMetis_ROOT", script)

    def test_builder_excludes_and_audits_suitesparse(self) -> None:
        script = BUILD_IMPLEMENTATION.read_text(encoding="utf-8")
        for removed_surface in (
            "SUITESPARSE_INSTALL",
            "SUITESPARSE_COMMIT",
            "SUITESPARSE_TREE_SHA256",
            "CHOLMOD_DIR",
            "CHOLMOD_INCLUDE_DIR_HINTS",
            "CHOLMOD_LIBRARY_DIR_HINTS",
            "suitesparse_receipt",
            "suitesparse_prefix",
            '"suitesparse"',
        ):
            self.assertNotIn(removed_surface, script)

        self.assertGreaterEqual(script.count("cholmod|SuiteSparse"), 2)
        self.assertIn(
            "native COLMAP build graph retains CHOLMOD or SuiteSparse", script
        )
        self.assertIn(
            "native COLMAP Mach-O closure retains CHOLMOD or SuiteSparse",
            script,
        )
        configure = script.split("configure() {", 1)[1].split("\n}", 1)[0]
        self.assertIn("cholmod|SuiteSparse", configure)
        for build_graph_artifact in (
            "$BUILD/CMakeCache.txt",
            "$BUILD/build.ninja",
            "$BUILD/compile_commands.json",
        ):
            self.assertIn(build_graph_artifact, configure)

        closure = script.split("assert_permissive_closure() {", 1)[1].split("\n}", 1)[0]
        self.assertIn("/usr/bin/otool -L", closure)
        self.assertIn("cholmod|SuiteSparse", closure)

    def test_builder_builds_and_stages_only_the_runtime_executable(self) -> None:
        script = BUILD_IMPLEMENTATION.read_text(encoding="utf-8")
        self.assertIn('"$CMAKE_BIN" --build "$BUILD" --target colmap_main', script)
        self.assertIn(
            'install -m 0755 "$BUILD/src/colmap/exe/colmap" "$INSTALL/bin/colmap"',
            script,
        )
        self.assertNotIn("--target install", script)
        self.assertNotIn("strip_install_to_runtime()", script)

    def test_builder_consumes_validated_static_dependency_prefixes(self) -> None:
        script = BUILD_IMPLEMENTATION.read_text(encoding="utf-8")

        for builder, install in (
            ("CERES_BUILDER", "CERES_INSTALL"),
            ("OPENIMAGEIO_BUILDER", "OPENIMAGEIO_INSTALL"),
        ):
            self.assertIn(f'"${{{builder}}}" --validate-only "${{{install}}}"', script)
        self.assertRegex(
            script,
            r"verify_dependency_provenance\s+\\?\s*"
            r'"\$CERES_INSTALL/build_info\.json"\s+'
            r'ceres-static\s+"\$CERES_COMMIT"',
        )
        self.assertRegex(
            script,
            r"verify_dependency_provenance\s+\\?\s*"
            r'"\$OPENIMAGEIO_INSTALL/build_info\.json"\s+\\?\s*'
            r'openimageio-static\s+"\$OPENIMAGEIO_COMMIT"\s+openimageio',
        )
        self.assertIn('-DEigen3_DIR="$CERES_INSTALL/share/eigen3/cmake"', script)
        self.assertIn('"$CERES_INSTALL/lib/libceres.a" "$BUILD/build.ninja"', script)
        self.assertIn(
            '"$OPENIMAGEIO_INSTALL/lib/libOpenImageIO.a" "$BUILD/build.ninja"',
            script,
        )
        self.assertNotIn("EIGEN_INSTALL", script)
        self.assertNotIn("EIGEN_TREE_SHA256", script)
        self.assertNotIn(
            "$COLMAP_SUPPORT_INSTALL/lib:$CERES_INSTALL/lib:$OPENIMAGEIO_INSTALL/lib",
            script,
        )

        closure = script.split("assert_permissive_closure() {", 1)[1].split("\n}", 1)[0]
        self.assertNotIn('find "$CERES_INSTALL/lib"', closure)
        self.assertNotIn('find "$OPENIMAGEIO_INSTALL/lib"', closure)
        self.assertIn(
            'local targets=("$INSTALL/bin/colmap" '
            '"$COLMAP_SUPPORT_INSTALL/lib/libomp.dylib")',
            closure,
        )

    def test_builder_proves_the_packaged_rpath_without_loader_overrides(self) -> None:
        script = BUILD_IMPLEMENTATION.read_text(encoding="utf-8")
        configure = script.split("configure() {", 1)[1].split("\n}", 1)[0]
        self.assertIn("-DCMAKE_BUILD_WITH_INSTALL_RPATH=ON", configure)
        self.assertIn("-DCMAKE_INSTALL_RPATH='@executable_path/../lib'", configure)
        self.assertIn("-DCMAKE_INSTALL_RPATH_USE_LINK_PATH=OFF", configure)
        self.assertIn("cache_is CMAKE_BUILD_WITH_INSTALL_RPATH ON", configure)
        self.assertIn(
            'cache_is CMAKE_INSTALL_RPATH "@executable_path/../lib"',
            configure,
        )
        self.assertIn("cache_is CMAKE_INSTALL_RPATH_USE_LINK_PATH OFF", configure)
        closure = script.split("assert_permissive_closure() {", 1)[1].split("\n}", 1)[0]
        self.assertIn('"/usr/bin/otool", "-l", binary', closure)
        self.assertIn('if rpaths != ["@executable_path/../lib"]:', closure)

        validation = script.split("validate_relocated_runtime() {", 1)[1].split(
            "\n}", 1
        )[0]
        self.assertIn(
            'install -m 0755 "$INSTALL/bin/colmap" "$relocated/bin/colmap"',
            validation,
        )
        self.assertRegex(
            validation,
            r"install -m 0755 "
            r'"\$COLMAP_SUPPORT_INSTALL/lib/libomp\.dylib"\s+\\?\s*'
            r'"\$relocated/lib/libomp\.dylib"',
        )
        self.assertRegex(
            validation,
            r"/usr/bin/env -u DYLD_LIBRARY_PATH "
            r"-u DYLD_FALLBACK_LIBRARY_PATH",
        )
        self.assertIn('"$relocated/bin/colmap" help', validation)

        final_pipeline = script.rsplit("\npreflight\n", 1)[1]
        self.assertLess(
            final_pipeline.index("\nvalidate_relocated_runtime\n"),
            final_pipeline.index("\nvalidate_native_retriever\n"),
        )

    def test_wrapper_discards_caller_bootstrap_and_exported_functions(self) -> None:
        wrapper_source = BUILD_SCRIPT.read_text(encoding="utf-8")
        self.assertIn("builtin type -P cmake", wrapper_source)
        self.assertIn("builtin exec /usr/bin/env -i", wrapper_source)

        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            wrapper = root / BUILD_SCRIPT.name
            implementation = root / BUILD_IMPLEMENTATION.name
            tools = root / "tools"
            capture = root / "captured-environment.txt"
            tools.mkdir()
            shutil.copy2(BUILD_SCRIPT, wrapper)
            wrapper.chmod(0o755)

            for name in ("cmake", "git", "ninja", "rg"):
                executable = tools / name
                executable.write_text("#!/bin/sh\nexit 0\n", encoding="utf-8")
                executable.chmod(0o755)

            implementation.write_text(
                "\n".join(
                    (
                        "#!/bin/bash",
                        "set -euo pipefail",
                        'functions="$(builtin declare -F || true)"',
                        "{",
                        "  builtin printf 'functions=%s\\n' \"$functions\"",
                        "  builtin printf 'caller_only=%s\\n' \"${CALLER_ONLY-unset}\"",
                        "  builtin printf 'cmake=%s\\n' \"$EASYSPLAT_BOOTSTRAP_CMAKE\"",
                        "  builtin printf 'git=%s\\n' \"$EASYSPLAT_BOOTSTRAP_GIT\"",
                        "  builtin printf 'ninja=%s\\n' \"$EASYSPLAT_BOOTSTRAP_NINJA\"",
                        "  builtin printf 'rg=%s\\n' \"$EASYSPLAT_BOOTSTRAP_RG\"",
                        '} > "$1"',
                    )
                )
                + "\n",
                encoding="utf-8",
            )
            implementation.chmod(0o755)

            launcher = "\n".join(
                (
                    "cmake() { builtin printf 'inherited function ran\\n'; return 97; }",
                    "hostile_function() { return 98; }",
                    "export -f cmake hostile_function",
                    'exec "$1" "$2"',
                )
            )
            environment = os.environ.copy()
            environment["PATH"] = f"{tools}:/usr/bin:/bin"
            environment["CALLER_ONLY"] = "must-not-survive"
            for name in ("CMAKE", "GIT", "NINJA", "RG"):
                environment[f"EASYSPLAT_BOOTSTRAP_{name}"] = (
                    f"/caller/fake/{name.lower()}"
                )

            result = subprocess.run(
                [
                    "/bin/bash",
                    "--noprofile",
                    "--norc",
                    "-c",
                    launcher,
                    "bash",
                    str(wrapper),
                    str(capture),
                ],
                check=False,
                capture_output=True,
                text=True,
                env=environment,
            )
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            captured = dict(
                line.split("=", 1)
                for line in capture.read_text(encoding="utf-8").splitlines()
            )
            self.assertEqual(captured["functions"], "")
            self.assertEqual(captured["caller_only"], "unset")
            for name in ("cmake", "git", "ninja", "rg"):
                selected = Path(captured[name])
                self.assertTrue(selected.is_absolute(), selected)
                self.assertEqual(selected, tools / name)
                self.assertTrue(os.access(selected, os.X_OK), selected)

    def test_implementation_binds_closure_and_promotes_only_after_validation(
        self,
    ) -> None:
        wrapper = BUILD_SCRIPT.read_text(encoding="utf-8")
        implementation = BUILD_IMPLEMENTATION.read_text(encoding="utf-8")

        for tool in ("CMAKE", "GIT", "NINJA", "RG"):
            self.assertIn(
                f'BOOTSTRAP_{tool}_BIN="$(builtin type -P {tool.lower()} || true)"',
                wrapper,
            )
            self.assertIn(
                f'{tool}_BIN="${{EASYSPLAT_BOOTSTRAP_{tool}:-}}"',
                implementation,
            )
        self.assertIn('[[ "$tool" = /* && -x "$tool" ]]', implementation)
        for configured_tool in (
            '-DCMAKE_MAKE_PROGRAM="$NINJA_BIN"',
            '-DGIT_EXECUTABLE="$GIT_BIN"',
        ):
            self.assertIn(configured_tool, implementation)
        self.assertNotIn('-DPython3_EXECUTABLE="$SELECTED_PYTHON"', implementation)

        for dependency_binding in (
            'CERES_BUILDER="$ROOT/scripts/toolchain/build_ceres.sh"',
            'OPENIMAGEIO_BUILDER="$ROOT/scripts/toolchain/build_openimageio.sh"',
            '"ceres": ceres_commit',
            '"openimageio": openimageio_commit',
            '"dependency_tree_sha256": dependency_tree_sha256',
        ):
            self.assertIn(dependency_binding, implementation)
        for bound_builder in (
            '"builder_sha256": sha256(builder_path)',
            '"builder_implementation_sha256": sha256(builder_implementation_path)',
            '"promoter_sha256": sha256(promoter_path)',
        ):
            self.assertEqual(implementation.count(bound_builder), 2)

        for closure_check in (
            '[ "$("$SELECTED_LIPO" -archs "$target")" = "arm64" ]',
            '[sys.argv[1], "-show-build", sys.argv[2]]',
            'r"^\\s*platform MACOS\\s*$"',
            "if len(matches) != 1:",
            "if version > (15, 0, 0):",
        ):
            self.assertIn(closure_check, implementation)

        promotion = implementation.split("promote_install() {", 1)[1].split("\n}", 1)[0]
        self.assertIn(
            '"$SELECTED_PYTHON" "$PROMOTER" "$INSTALL" "$LIVE_INSTALL"',
            promotion,
        )
        final_pipeline = implementation.rsplit("\npreflight\n", 1)[1]
        ordered_steps = (
            "stage_metadata",
            "validate_metadata",
            "assert_permissive_closure",
            "validate_commands",
            "validate_native_retriever",
            "promote_install",
        )
        positions = tuple(final_pipeline.index(f"\n{step}\n") for step in ordered_steps)
        self.assertEqual(positions, tuple(sorted(positions)))
        self.assertEqual(implementation.count("\npromote_install\n"), 1)

    def test_cmake_cache_comparison_treats_compiler_path_literally(self) -> None:
        script = BUILD_IMPLEMENTATION.read_text(encoding="utf-8")
        cache_body = script.split("cache_is() {", 1)[1].split(
            "\n}\n\nverify_dependency_provenance() {", 1
        )[0]
        cache_function = f"cache_is() {{{cache_body}\n}}"
        self.assertNotIn("grep -E", cache_function)

        compiler = (
            "/Applications/Xcode.app/Contents/Developer/Toolchains/"
            "XcodeDefault.xctoolchain/usr/bin/clang++"
        )
        harness = "\n".join(
            (
                "set -euo pipefail",
                'die() { echo "$*" >&2; exit 1; }',
                cache_function,
                'cache_is CMAKE_CXX_COMPILER "$1"',
            )
        )
        with tempfile.TemporaryDirectory() as directory:
            build = Path(directory)
            (build / "CMakeCache.txt").write_text(
                f"CMAKE_CXX_COMPILER:FILEPATH={compiler}\n",
                encoding="utf-8",
            )
            environment = os.environ.copy()
            environment["BUILD"] = str(build)

            exact = subprocess.run(
                ["bash", "-c", harness, "bash", compiler],
                check=False,
                capture_output=True,
                text=True,
                env=environment,
            )
            self.assertEqual(exact.returncode, 0, exact.stdout + exact.stderr)

            changed = subprocess.run(
                ["bash", "-c", harness, "bash", compiler.removesuffix("+")],
                check=False,
                capture_output=True,
                text=True,
                env=environment,
            )
            self.assertNotEqual(changed.returncode, 0)
            self.assertIn(
                "CMake did not preserve CMAKE_CXX_COMPILER",
                changed.stdout + changed.stderr,
            )

    def test_dependency_and_receipt_audits_recompute_build_inputs(self) -> None:
        script = BUILD_IMPLEMENTATION.read_text(encoding="utf-8")
        dependency_validation = script.split("verify_dependency_provenance() {", 1)[
            1
        ].split("\nPY\n}", 1)[0]
        for integrity_check in (
            'source_dependency="${4:-}"',
            'payload.get("dependencies", {}).get(source_dependency)',
            'source_url.endswith(f"/{expected_commit}.tar.gz")',
            'payload.get("libraries", [])',
            'payload.get("library_sha256", {})',
            "relative.is_absolute()",
            '".." in relative.parts',
            "library_path.is_symlink()",
            "hashlib.sha256(library_path.read_bytes()).hexdigest()",
            "dependency library hash mismatch",
            'payload.get("ownership_policy")',
            '"normalized_owner_uid" in payload',
            '"normalized_owner_gid" in payload',
            'payload.get("install_tree_sha256")',
            "noncanonical dependency ownership",
            "dependency install tree hash mismatch",
        ):
            self.assertIn(integrity_check, dependency_validation)

        metadata_validation = script.split("validate_metadata() {", 1)[1].split(
            "\nPY\n}", 1
        )[0]
        for independently_recomputed_input in (
            "def verified_library_hashes(",
            '"dependency_receipt_sha256"',
            "name: sha256(path)",
            '"dependency_library_sha256"',
            '"settings_sha256": sha256(sdk_settings_path)',
            '"ls-tree"',
            '"--full-tree"',
            "if payload != expected_payload:",
        ):
            self.assertIn(independently_recomputed_input, metadata_validation)
        self.assertEqual(script.count("def verified_library_hashes("), 2)
        self.assertNotIn('"dependency_receipt_canonical_sha256"', script)

    def test_dependency_provenance_executes_receipt_integrity_checks(self) -> None:
        script = BUILD_IMPLEMENTATION.read_text(encoding="utf-8")
        provenance_body = script.split("verify_dependency_provenance() {", 1)[1].split(
            "\nPY\n}", 1
        )[0]
        provenance_function = (
            f"verify_dependency_provenance() {{{provenance_body}\nPY\n}}"
        )
        harness = "\n".join(
            (
                "set -euo pipefail",
                provenance_function,
                'verify_dependency_provenance "$1" "$2" "$3"',
            )
        )
        selected_python = shutil.which("python3")
        self.assertIsNotNone(selected_python)
        environment = os.environ.copy()
        environment["SELECTED_PYTHON"] = str(selected_python)

        with tempfile.TemporaryDirectory() as directory:
            prefix = Path(directory) / "fixture"
            library_directory = prefix / "lib"
            library_directory.mkdir(parents=True)
            receipt = prefix / "build_info.json"
            library = library_directory / "libfixture.dylib"
            original_bytes = b"reviewed dependency bytes\n"
            library.write_bytes(original_bytes)
            os.utime(library, (946684800, 946684800))
            receipt.write_text("{}\n", encoding="utf-8")
            for path in (library, receipt, library_directory, prefix):
                os.utime(path, (946684800, 946684800), follow_symlinks=False)
            digest = sha256(library)

            def invoke(payload: dict[str, object]) -> subprocess.CompletedProcess[str]:
                receipt.write_text(
                    json.dumps(payload, sort_keys=True) + "\n",
                    encoding="utf-8",
                )
                return subprocess.run(
                    [
                        "bash",
                        "-c",
                        harness,
                        "bash",
                        str(receipt),
                        "fixture",
                        "abc123",
                    ],
                    check=False,
                    capture_output=True,
                    text=True,
                    env=environment,
                )

            common = {
                "architecture": "arm64",
                "deployment_target": "macOS 15.0",
                "toolchain_name": "fixture",
                "source_commit": "abc123",
                "ownership_policy": "invoking-build-user-and-primary-group",
                "install_tree_sha256": portable_tree_sha256(prefix),
            }
            for declared_libraries in (
                {
                    "libraries": [
                        {"file": library.name, "sha256": digest},
                    ]
                },
                {"library_sha256": {library.name: digest}},
            ):
                with self.subTest(receipt_format=next(iter(declared_libraries))):
                    accepted = invoke(common | declared_libraries)
                    self.assertEqual(
                        accepted.returncode,
                        0,
                        accepted.stdout + accepted.stderr,
                    )

            valid_payload = common | {"library_sha256": {library.name: digest}}
            library.write_bytes(b"tampered dependency bytes\n")
            tampered = invoke(valid_payload)
            self.assertNotEqual(tampered.returncode, 0)
            self.assertIn(
                "dependency library hash mismatch",
                tampered.stdout + tampered.stderr,
            )

            library.write_bytes(original_bytes)
            os.utime(library, (946684800, 946684800))
            wrong_commit = invoke(
                valid_payload | {"source_commit": "unexpected-commit"}
            )
            self.assertNotEqual(wrong_commit.returncode, 0)
            self.assertIn(
                "stale fixture install",
                wrong_commit.stdout + wrong_commit.stderr,
            )

            wrong_deployment_target = invoke(
                valid_payload | {"deployment_target": "macOS 26.0"}
            )
            self.assertNotEqual(wrong_deployment_target.returncode, 0)
            self.assertIn(
                "unsupported fixture deployment target",
                wrong_deployment_target.stdout + wrong_deployment_target.stderr,
            )

            wrong_architecture = invoke(valid_payload | {"architecture": "x86_64"})
            self.assertNotEqual(wrong_architecture.returncode, 0)
            self.assertIn(
                "unsupported fixture architecture",
                wrong_architecture.stdout + wrong_architecture.stderr,
            )

            library.unlink()
            symlink_target = Path(directory) / "actual-libfixture.dylib"
            symlink_target.write_bytes(original_bytes)
            library.symlink_to(symlink_target)
            symlinked = invoke(valid_payload)
            self.assertNotEqual(symlinked.returncode, 0)
            self.assertIn(
                "declared dependency library is missing",
                symlinked.stdout + symlinked.stderr,
            )
            library.unlink()
            library.write_bytes(original_bytes)
            os.utime(library, (946684800, 946684800))
            os.utime(library_directory, (946684800, 946684800))

            unsafe = invoke(common | {"library_sha256": {"../escape.dylib": digest}})
            self.assertNotEqual(unsafe.returncode, 0)
            self.assertIn(
                "unsafe dependency library path",
                unsafe.stdout + unsafe.stderr,
            )

            wrong_policy = invoke(
                valid_payload | {"ownership_policy": "numeric-owner-encoded"}
            )
            self.assertNotEqual(wrong_policy.returncode, 0)
            self.assertIn(
                "dependency ownership policy mismatch",
                wrong_policy.stdout + wrong_policy.stderr,
            )

            numeric_owner = invoke(valid_payload | {"normalized_owner_uid": 501})
            self.assertNotEqual(numeric_owner.returncode, 0)
            self.assertIn(
                "host-specific numeric ownership",
                numeric_owner.stdout + numeric_owner.stderr,
            )

            forged_tree = invoke(valid_payload | {"install_tree_sha256": "0" * 64})
            self.assertNotEqual(forged_tree.returncode, 0)
            self.assertIn(
                "dependency install tree hash mismatch",
                forged_tree.stdout + forged_tree.stderr,
            )

            alternate_groups = [
                group for group in os.getgroups() if group != os.getgid()
            ]
            if alternate_groups:
                os.chown(library, os.getuid(), alternate_groups[0])
                try:
                    inherited_group = invoke(valid_payload)
                finally:
                    os.chown(library, os.getuid(), os.getgid())
                self.assertNotEqual(inherited_group.returncode, 0)
                self.assertIn(
                    "noncanonical dependency ownership",
                    inherited_group.stdout + inherited_group.stderr,
                )

    def test_build_script_pins_reviewed_faiss_and_generic_apple_silicon(self) -> None:
        script = BUILD_IMPLEMENTATION.read_text(encoding="utf-8")
        self.assertIn('FAISS_VERSION="1.14.3"', script)
        self.assertIn(
            'FAISS_COMMIT="0ca9df4792b173d573044ee14ca0704780176e82"',
            script,
        )
        self.assertIn(
            'FAISS_SHA256="fdb01044e707caa7e16d009a8ed11816aebe17fefbccb428c495486e28e6046d"',
            script,
        )
        for option in (
            "FAISS_ENABLE_GPU=OFF",
            "FAISS_ENABLE_METAL=OFF",
            "FAISS_ENABLE_PYTHON=OFF",
            "FAISS_ENABLE_MKL=OFF",
            "FAISS_OPT_LEVEL=generic",
        ):
            self.assertIn(f"-D{option}", script)
        self.assertIn("local_vocab_retriever.cc", script)
        self.assertIn("easysplat_overlay_sha256", script)
        self.assertIn('"local_vocab_retriever"', script)
        self.assertIn('("-mcpu", "native")', script)
        self.assertIn('("-march", "native")', script)
        self.assertNotIn("-mcpu=native", script)
        self.assertNotIn("-march=native", script)

    def test_compile_command_audit_executes_and_rejects_host_tuning(self) -> None:
        script = BUILD_IMPLEMENTATION.read_text(encoding="utf-8")
        marker = (
            '  "$SELECTED_PYTHON" - \\\n'
            '    "$BUILD/compile_commands.json" \\\n'
            '    "$ROOT" \\\n'
            '    "$SELECTED_C_COMPILER" \\\n'
            "    \"$SELECTED_CXX_COMPILER\" <<'PY'\n"
        )
        self.assertEqual(script.count(marker), 1)
        audit = script.split(marker, 1)[1].split("\nPY\n", 1)[0]

        with tempfile.TemporaryDirectory() as directory:
            commands = Path(directory) / "compile_commands.json"

            def run(
                command: str,
                *,
                source: str = "/tmp/source.cc",
            ) -> subprocess.CompletedProcess[str]:
                commands.write_text(
                    json.dumps([{"command": command, "file": source}]),
                    encoding="utf-8",
                )
                return subprocess.run(
                    [
                        "python3",
                        "-",
                        str(commands),
                        "/fixture/root",
                        "/usr/bin/clang",
                        "/usr/bin/clang++",
                    ],
                    input=audit,
                    check=False,
                    capture_output=True,
                    text=True,
                )

            prefix_maps = (
                "-ffile-prefix-map=/fixture/root=/easysplat "
                "-fdebug-prefix-map=/fixture/root=/easysplat"
            )
            allowed = run(
                f"/usr/bin/clang++ {prefix_maps} -mcpu apple-m1 -c /tmp/source.cc"
            )
            self.assertEqual(allowed.returncode, 0, allowed.stdout + allowed.stderr)
            allowed_c = run(
                f"/usr/bin/clang {prefix_maps} -c /tmp/source.c",
                source="/tmp/source.c",
            )
            self.assertEqual(
                allowed_c.returncode,
                0,
                allowed_c.stdout + allowed_c.stderr,
            )
            for command in (
                f"/usr/bin/clang++ {prefix_maps} -mcpu native -c /tmp/source.cc",
                f"/usr/bin/clang++ {prefix_maps} -march=native -c /tmp/source.cc",
            ):
                with self.subTest(command=command):
                    rejected = run(command)
                    self.assertNotEqual(rejected.returncode, 0)
                    self.assertIn(
                        "host-specific compiler tuning entered the build",
                        rejected.stdout + rejected.stderr,
                    )
            missing_maps = run("/usr/bin/clang++ -c /tmp/source.cc")
            self.assertNotEqual(missing_maps.returncode, 0)
            self.assertIn(
                "compiler prefix maps are absent",
                missing_maps.stdout + missing_maps.stderr,
            )
            unselected_compiler = run(
                f"/usr/local/bin/clang++ {prefix_maps} -c /tmp/source.cc"
            )
            self.assertNotEqual(unselected_compiler.returncode, 0)
            self.assertIn(
                "unselected compiler entered the build",
                unselected_compiler.stdout + unselected_compiler.stderr,
            )

    def test_retriever_preflights_faiss_boundaries_and_aggregate_memory(self) -> None:
        source = (OVERLAY_ROOT / "local_vocab_retriever.cc").read_text(encoding="utf-8")
        self.assertIn("memory_budget_bytes", source)
        self.assertIn("kDefaultMemoryBudgetBytes", source)
        self.assertIn("kMaximumMemoryBudgetBytes", source)
        self.assertIn("ReadFeatureMetadata", source)
        self.assertIn("EstimateRetrievalMemory", source)
        self.assertIn(
            "retrieval requires at least three selected training descriptors",
            source,
        )
        self.assertRegex(
            source,
            r"training\.data\.rows\(\)\s*-\s*1",
        )
        self.assertIn("static_assert(kSealedThreeThousandFrameEstimate", source)
        self.assertIn("ReadImageTableMetadata", source)
        self.assertIn("kMaximumImageNameBytes", source)
        self.assertIn("ValidateOptionalInputSizes", source)
        self.assertIn("StreamLines", source)
        self.assertNotIn("std::vector<std::string> ReadLines", source)

    def test_positive_sqlite_blobs_are_checked_before_copying(self) -> None:
        source = (OVERLAY_ROOT / "local_vocab_retriever.cc").read_text(encoding="utf-8")
        read_matrix = source.split("RawMatrix ReadMatrix", 1)[1].split(
            "struct ImageFeatures", 1
        )[0]
        pointer_position = read_matrix.index("sqlite3_column_blob")
        null_check_position = read_matrix.index("blob_data == nullptr")
        copy_position = read_matrix.index("std::memcpy")
        self.assertLess(pointer_position, null_check_position)
        self.assertLess(null_check_position, copy_position)
        self.assertIn("sqlite3_errcode(database)", read_matrix)

    def test_atomic_write_requires_parent_directory_durability(self) -> None:
        source = (OVERLAY_ROOT / "local_vocab_retriever.cc").read_text(encoding="utf-8")
        atomic_write = source.split("void AtomicWrite(", 1)[1].split(
            "std::vector<std::string> RetrievePairs", 1
        )[0]
        open_position = atomic_write.index("::open(parent.c_str()")
        rename_position = atomic_write.index("::rename(")
        sync_position = atomic_write.index("::fsync(directory)")
        close_position = atomic_write.index("::close(directory)")
        self.assertLess(open_position, rename_position)
        self.assertLess(rename_position, sync_position)
        self.assertLess(sync_position, close_position)
        self.assertNotIn("static_cast<void>(::fsync(directory))", atomic_write)
        self.assertIn(
            "const int directory_close_result = ::close(directory)",
            atomic_write,
        )

    def test_ci_and_clean_builder_run_the_honest_test_boundaries(self) -> None:
        release_test = RELEASE_SCRIPT_TEST.read_text(encoding="utf-8")
        source_only_command = (
            'python3 "$ROOT/scripts/toolchain/tests/'
            'test_native_colmap_retriever.py" SourceContractTests'
        )
        self.assertIn(source_only_command, release_test)
        self.assertNotIn(
            'python3 "$ROOT/scripts/toolchain/tests/test_native_colmap_retriever.py"\n',
            release_test,
        )

        implementation = BUILD_IMPLEMENTATION.read_text(encoding="utf-8")
        self.assertIn("validate_native_retriever()", implementation)
        self.assertIn(
            'EASYSPLAT_NATIVE_COLMAP_BIN="$INSTALL/bin/colmap"',
            implementation,
        )
        self.assertIn(
            'EASYSPLAT_NATIVE_COLMAP_DYLD_LIBRARY_PATH="$runtime_path"',
            implementation,
        )
        self.assertIn('EASYSPLAT_TEST_CLANG="$SELECTED_C_COMPILER"', implementation)
        self.assertIn('EASYSPLAT_TEST_SDK="$MACOS_SDK_PATH"', implementation)
        self.assertIn(
            'test_native_colmap_retriever.py" NativeRetrieverTests',
            implementation,
        )
        self.assertNotIn('EASYSPLAT_PYCOLMAP_COLMAP_BIN=""', implementation)
        self.assertRegex(
            implementation,
            r"validate_commands\s*\n"
            r"validate_relocated_runtime\s*\n"
            r"validate_native_retriever\s*\n",
        )


class NativeRetrieverTests(unittest.TestCase):
    native_binary: Path
    oracle_binary: Path | None
    runtime_library_path: str | None
    fault_shims: dict[str, Path]
    fault_shim_root: Path | None = None

    @classmethod
    def setUpClass(cls) -> None:
        native = os.environ.get("EASYSPLAT_NATIVE_COLMAP_BIN")
        if not native:
            raise unittest.SkipTest("set EASYSPLAT_NATIVE_COLMAP_BIN for native tests")
        cls.native_binary = Path(native).resolve()
        if not cls.native_binary.is_file():
            raise AssertionError(f"native COLMAP is missing: {cls.native_binary}")
        oracle = os.environ.get("EASYSPLAT_PYCOLMAP_COLMAP_BIN")
        cls.oracle_binary = Path(oracle).resolve() if oracle else None
        cls.runtime_library_path = os.environ.get(
            "EASYSPLAT_NATIVE_COLMAP_DYLD_LIBRARY_PATH"
        )
        help_result = cls._invoke_binary(
            cls.native_binary,
            ["local_vocab_retriever", "-h"],
        )
        if help_result.returncode != 0:
            raise AssertionError(
                "native COLMAP does not expose local_vocab_retriever:\n"
                + help_result.stdout
                + help_result.stderr
            )
        cls.fault_shims = cls._build_fault_shims()

    @classmethod
    def _base_environment(cls) -> dict[str, str]:
        environment = os.environ.copy()
        if cls.runtime_library_path:
            environment["DYLD_LIBRARY_PATH"] = cls.runtime_library_path
        return environment

    @classmethod
    def _invoke_binary(
        cls,
        binary: Path,
        arguments: list[str],
        *,
        extra_environment: dict[str, str] | None = None,
    ) -> subprocess.CompletedProcess[str]:
        environment = cls._base_environment()
        if extra_environment:
            environment.update(extra_environment)
        return subprocess.run(
            [str(binary), *arguments],
            check=False,
            capture_output=True,
            text=True,
            env=environment,
            timeout=60,
        )

    @classmethod
    def _build_fault_shims(cls) -> dict[str, Path]:
        configured_clang = os.environ.get("EASYSPLAT_TEST_CLANG")
        configured_sdk = os.environ.get("EASYSPLAT_TEST_SDK")
        require_all_shims = configured_clang is not None
        if (configured_clang is None) != (configured_sdk is None):
            raise RuntimeError(
                "EASYSPLAT_TEST_CLANG and EASYSPLAT_TEST_SDK must be set together"
            )
        sdk: Path | None = None
        if configured_clang is not None and configured_sdk is not None:
            clang_path = Path(configured_clang)
            sdk = Path(configured_sdk)
            if (
                not clang_path.is_absolute()
                or clang_path.is_symlink()
                or not clang_path.is_file()
                or not os.access(clang_path, os.X_OK)
            ):
                raise RuntimeError(
                    "EASYSPLAT_TEST_CLANG must be an absolute, non-symlink executable"
                )
            if not sdk.is_absolute() or not sdk.is_dir():
                raise RuntimeError(
                    "EASYSPLAT_TEST_SDK must be an absolute, existing directory"
                )
            clang = str(clang_path)
        else:
            clang = shutil.which("clang")
            if clang is None:
                return {}
        root = Path(tempfile.mkdtemp(prefix="easysplat-vocab-fault-shims."))
        cls.fault_shim_root = root
        shims: dict[str, Path] = {}
        interpose = (
            "#define DYLD_INTERPOSE(replacement, replacee) "
            "__attribute__((used)) static struct { const void *replacement; "
            "const void *replacee; } _interpose_##replacee "
            '__attribute__((section("__DATA,__interpose"))) = '
            "{ (const void *)(unsigned long)&replacement, "
            "(const void *)(unsigned long)&replacee };\n"
        )
        definitions = {
            "fsync": (
                "#include <errno.h>\n#include <unistd.h>\n"
                + interpose
                + "static int fail_fsync(int fd) "
                "{(void)fd; errno=EIO; return -1;}\n"
                "DYLD_INTERPOSE(fail_fsync, fsync)\n"
            ),
            "rename": (
                "#include <errno.h>\n#include <stdio.h>\n"
                + interpose
                + "static int fail_rename(const char *from, const char *to) "
                "{(void)from; (void)to; errno=EIO; return -1;}\n"
                "DYLD_INTERPOSE(fail_rename, rename)\n"
            ),
            "directory_fsync": (
                "#include <errno.h>\n#include <sys/stat.h>\n"
                "#include <sys/syscall.h>\n#include <unistd.h>\n"
                + interpose
                + "static int fail_directory_fsync(int fd) {\n"
                "  struct stat status;\n"
                "  if (fstat(fd, &status) == 0 && S_ISDIR(status.st_mode)) {\n"
                "    errno = EIO; return -1;\n"
                "  }\n"
                "  return (int)syscall(SYS_fsync, fd);\n"
                "}\n"
                "DYLD_INTERPOSE(fail_directory_fsync, fsync)\n"
            ),
            "sqlite_blob": (
                "typedef struct sqlite3_stmt sqlite3_stmt;\n"
                "extern const void *sqlite3_column_blob(sqlite3_stmt *, int);\n"
                + interpose
                + "static const void *fail_sqlite3_column_blob("
                "sqlite3_stmt *statement, int column) "
                "{(void)statement; (void)column; return (const void *)0;}\n"
                "DYLD_INTERPOSE(fail_sqlite3_column_blob, sqlite3_column_blob)\n"
            ),
        }
        for name, source in definitions.items():
            source_path = root / f"fail_{name}.c"
            library_path = root / f"fail_{name}.dylib"
            source_path.write_text(source, encoding="utf-8")
            compiler_arguments = [clang, "-dynamiclib"]
            if sdk is not None:
                compiler_arguments.extend(("-isysroot", str(sdk)))
            compiler_arguments.extend(
                (
                    str(source_path),
                    "-lsqlite3",
                    "-o",
                    str(library_path),
                )
            )
            result = subprocess.run(
                compiler_arguments,
                check=False,
                capture_output=True,
                text=True,
            )
            if result.returncode == 0:
                shims[name] = library_path
            elif require_all_shims:
                shutil.rmtree(root, ignore_errors=True)
                cls.fault_shim_root = None
                detail = result.stderr.strip() or result.stdout.strip()
                raise RuntimeError(
                    f"could not build required {name} fault shim"
                    + (f": {detail}" if detail else "")
                )
        return shims

    @classmethod
    def tearDownClass(cls) -> None:
        if cls.fault_shim_root is not None:
            shutil.rmtree(cls.fault_shim_root, ignore_errors=True)

    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        self.database = self.root / "features.db"
        self.output = self.root / "pairs.txt"
        create_feature_database(self.database, ordinary_images())

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def _arguments(
        self,
        *,
        database: Path | str | None = None,
        output: Path | str | None = None,
        extra: list[str] | None = None,
    ) -> list[str]:
        arguments = [
            "local_vocab_retriever",
            "--database_path",
            str(database or self.database),
            "--output_pair_list_path",
            str(output or self.output),
            "--num_images",
            "3",
            "--returned_neighbor_count",
            "2",
            "--minimum_frame_separation",
            "0",
            "--num_visual_words",
            "4",
            "--max_features_per_image",
            "16",
            "--max_training_descriptors",
            "512",
            "--memory_budget_bytes",
            "2147483648",
            "--num_iterations",
            "2",
            "--num_rounds",
            "1",
            "--num_checks",
            "4",
            "--num_threads",
            "1",
            "--log_target",
            "stderr",
        ]
        if extra:
            if len(extra) % 2 != 0:
                raise AssertionError(f"options must be name/value pairs: {extra}")
            for option, value in zip(extra[::2], extra[1::2]):
                if option in arguments:
                    index = arguments.index(option)
                    arguments[index + 1] = value
                else:
                    arguments.extend((option, value))
        return arguments

    def _run(
        self,
        *,
        database: Path | str | None = None,
        output: Path | str | None = None,
        extra: list[str] | None = None,
        environment: dict[str, str] | None = None,
        binary: Path | None = None,
    ) -> subprocess.CompletedProcess[str]:
        selected_binary = binary or self.native_binary
        arguments = self._arguments(database=database, output=output, extra=extra)
        if self.oracle_binary is not None and selected_binary == self.oracle_binary:
            for option in ("--memory_budget_bytes", "--log_target"):
                option_index = arguments.index(option)
                del arguments[option_index : option_index + 2]
        return self._invoke_binary(
            selected_binary,
            arguments,
            extra_environment=environment,
        )

    def assertFailurePreservesOutput(
        self,
        result: subprocess.CompletedProcess[str],
    ) -> None:
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(self.output.read_bytes(), b"preserve me\n")
        self.assertEqual(
            [
                path
                for path in self.root.iterdir()
                if path.name.startswith(".pairs.txt.")
            ],
            [],
        )

    def assertNoTemporaryOutput(self) -> None:
        self.assertEqual(
            [
                path
                for path in self.root.iterdir()
                if path.name.startswith(".pairs.txt.")
            ],
            [],
        )

    def test_help_exposes_only_the_local_scene_vocabulary_contract(self) -> None:
        result = self._invoke_binary(
            self.native_binary,
            ["local_vocab_retriever", "-h"],
        )
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        help_text = result.stdout + result.stderr
        for option in REQUIRED_OPTIONS:
            self.assertIn(f"--{option}", help_text)
        self.assertNotIn("--vocab_tree_path", help_text)

    def test_image_undistorter_omits_dead_dense_workspace(self) -> None:
        help_result = self._invoke_binary(
            self.native_binary,
            ["image_undistorter", "-h"],
        )
        self.assertEqual(help_result.returncode, 0, help_result.stderr)
        self.assertNotIn(
            "num_patch_match_src_images",
            help_result.stdout + help_result.stderr,
        )

        images = self.root / "images"
        model = self.root / "model"
        output = self.root / "undistorted"
        images.mkdir()
        model.mkdir()
        write_test_png(images / "pixel.png")
        (model / "cameras.txt").write_text(
            "1 PINHOLE 2 2 2 2 1 1\n",
            encoding="utf-8",
        )
        (model / "images.txt").write_text(
            "1 1 0 0 0 0 0 0 1 pixel.png\n\n",
            encoding="utf-8",
        )
        (model / "points3D.txt").write_text("", encoding="utf-8")

        result = self._invoke_binary(
            self.native_binary,
            [
                "image_undistorter",
                "--image_path",
                str(images),
                "--input_path",
                str(model),
                "--output_path",
                str(output),
                "--output_type",
                "COLMAP",
                "--max_image_size",
                "-1",
            ],
        )
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(
            {path.name for path in output.iterdir()},
            {"images", "sparse"},
        )
        self.assertTrue((output / "images" / "pixel.png").is_file())

    def test_binary_excludes_unreachable_learned_feature_code_and_options(self) -> None:
        for command in ("feature_extractor", "matches_importer"):
            with self.subTest(command=command):
                result = self._invoke_binary(self.native_binary, [command, "-h"])
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                help_text = result.stdout + result.stderr
                for forbidden_option in (
                    "AlikedExtraction",
                    "AlikedMatching",
                    "SiftMatching.lightglue",
                    "ALIKED",
                    "LIGHTGLUE",
                ):
                    if forbidden_option in help_text:
                        self.fail(
                            f"{command} still exposes learned option {forbidden_option}"
                        )

        nm = subprocess.run(
            ["/usr/bin/nm", "-j", str(self.native_binary)],
            check=False,
            capture_output=True,
            text=True,
            timeout=60,
        )
        self.assertEqual(nm.returncode, 0, nm.stdout + nm.stderr)
        strings = subprocess.run(
            ["/usr/bin/strings", "-a", str(self.native_binary)],
            check=False,
            capture_output=True,
            text=True,
            timeout=60,
        )
        self.assertEqual(strings.returncode, 0, strings.stdout + strings.stderr)
        compiled_surface = nm.stdout + strings.stdout
        for forbidden_symbol_or_resource in (
            "CreateAlikedFeatureExtractor",
            "CreateAlikedFeatureMatcher",
            "CreateLightGlueONNXFeatureMatcher",
            "kDefaultAliked",
            "kDefaultSiftLightGlueFeatureMatcherUri",
            "aliked-n16rot.onnx",
            "aliked-n32.onnx",
            "aliked-lightglue.onnx",
            "sift-lightglue.onnx",
        ):
            if forbidden_symbol_or_resource in compiled_surface:
                self.fail(
                    "native binary still contains learned feature surface: "
                    f"{forbidden_symbol_or_resource}"
                )

    def test_numeric_bounds_fail_before_retrieval(self) -> None:
        invalid_values = (
            ("num_images", "0"),
            ("num_images", "257"),
            ("returned_neighbor_count", "0"),
            ("returned_neighbor_count", "65"),
            ("minimum_frame_separation", "-1"),
            ("minimum_frame_separation", "1000001"),
            ("num_visual_words", "1"),
            ("num_visual_words", "8193"),
            ("max_features_per_image", "1"),
            ("max_features_per_image", "8193"),
            ("max_training_descriptors", "511"),
            ("max_training_descriptors", "262145"),
            ("memory_budget_bytes", "67108863"),
            ("memory_budget_bytes", "274877906945"),
            ("memory_budget_bytes", "-1"),
            ("memory_budget_bytes", "1.5"),
            ("memory_budget_bytes", "18446744073709551616"),
            ("num_iterations", "0"),
            ("num_iterations", "101"),
            ("num_rounds", "0"),
            ("num_rounds", "4"),
            ("num_checks", "0"),
            ("num_checks", "1025"),
            ("num_threads", "0"),
            ("num_threads", "-2"),
            ("num_threads", "65"),
        )
        for option, value in invalid_values:
            with self.subTest(option=option, value=value):
                result = self._run(extra=[f"--{option}", value])
                self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        result = self._run(
            extra=["--num_images", "2", "--returned_neighbor_count", "3"]
        )
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_paths_must_be_absolute_regular_files_without_symlink_escape(self) -> None:
        result = self._run(database="relative.db")
        self.assertNotEqual(result.returncode, 0)
        result = self._run(output="relative.txt")
        self.assertNotEqual(result.returncode, 0)

        database_link = self.root / "database-link.db"
        database_link.symlink_to(self.database)
        result = self._run(database=database_link)
        self.assertNotEqual(result.returncode, 0)

        self.output.write_text("preserve me\n", encoding="utf-8")
        output_link = self.root / "output-link.txt"
        output_link.symlink_to(self.output)
        result = self._run(output=output_link)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.output.read_text(encoding="utf-8"), "preserve me\n")

        query_file = self.root / "queries.txt"
        query_file.write_text("000-alpha.jpg\n", encoding="utf-8")
        query_link = self.root / "query-link.txt"
        query_link.symlink_to(query_file)
        result = self._run(extra=["--query_image_list_path", str(query_link)])
        self.assertNotEqual(result.returncode, 0)

        excluded_file = self.root / "excluded.txt"
        excluded_file.write_text("000-alpha.jpg 001-bravo.jpg\n", encoding="utf-8")
        excluded_link = self.root / "excluded-link.txt"
        excluded_link.symlink_to(excluded_file)
        result = self._run(extra=["--excluded_pair_list_path", str(excluded_link)])
        self.assertNotEqual(result.returncode, 0)

    def test_output_must_not_alias_optional_inputs(self) -> None:
        query_file = self.root / "queries.txt"
        query_contents = b"000-alpha.jpg\n"
        query_file.write_bytes(query_contents)
        query_result = self._run(
            output=query_file,
            extra=["--query_image_list_path", str(query_file)],
        )
        self.assertNotEqual(
            query_result.returncode,
            0,
            query_result.stdout + query_result.stderr,
        )
        self.assertEqual(query_file.read_bytes(), query_contents)

        excluded_file = self.root / "excluded.txt"
        excluded_contents = b"000-alpha.jpg 001-bravo.jpg\n"
        excluded_file.write_bytes(excluded_contents)
        excluded_output = self.root / "excluded-output.txt"
        os.link(excluded_file, excluded_output)
        excluded_result = self._run(
            output=excluded_output,
            extra=["--excluded_pair_list_path", str(excluded_file)],
        )
        self.assertNotEqual(
            excluded_result.returncode,
            0,
            excluded_result.stdout + excluded_result.stderr,
        )
        self.assertEqual(excluded_file.read_bytes(), excluded_contents)
        self.assertEqual(excluded_output.read_bytes(), excluded_contents)

    def test_optional_inputs_are_admitted_before_streaming(self) -> None:
        constrained_budget = "68157440"  # 65 MiB: enough for the base fixture.
        baseline_output = self.root / "baseline.txt"
        baseline = self._run(
            output=baseline_output,
            extra=["--memory_budget_bytes", constrained_budget],
        )
        self.assertEqual(baseline.returncode, 0, baseline.stdout + baseline.stderr)

        cases = (
            ("query", "000-alpha.jpg\n", "--query_image_list_path"),
            (
                "excluded",
                "000-alpha.jpg 001-bravo.jpg\n",
                "--excluded_pair_list_path",
            ),
        )
        for label, line, option in cases:
            with self.subTest(label=label):
                optional_input = self.root / f"oversized-{label}.txt"
                with optional_input.open("w", encoding="utf-8") as stream:
                    for _ in range(100_000):
                        stream.write(line)
                self.output.write_text("preserve me\n", encoding="utf-8")
                result = self._run(
                    extra=[
                        "--memory_budget_bytes",
                        constrained_budget,
                        option,
                        str(optional_input),
                    ],
                )
                self.assertFailurePreservesOutput(result)
                self.assertIn("memory budget", result.stdout + result.stderr)

    def test_image_name_metadata_rejects_oversized_names_before_materializing(
        self,
    ) -> None:
        oversized_database = self.root / "oversized-name.db"
        shutil.copyfile(self.database, oversized_database)
        connection = sqlite3.connect(oversized_database)
        try:
            connection.execute(
                "UPDATE images SET name = ? WHERE image_id = 10",
                ("n" * 1025,),
            )
            connection.commit()
        finally:
            connection.close()
        self.output.write_text("preserve me\n", encoding="utf-8")
        result = self._run(database=oversized_database)
        self.assertFailurePreservesOutput(result)
        self.assertIn("image name exceeds", result.stdout + result.stderr)

    def test_optional_descriptor_type_column_and_default_threads_are_supported(
        self,
    ) -> None:
        database_without_type = self.root / "descriptors-without-type.db"
        create_feature_database(
            database_without_type,
            ordinary_images(),
            descriptor_type_column=False,
        )
        result = self._run(
            database=database_without_type,
            extra=["--num_threads", "-1"],
        )
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_duplicate_image_identity_and_whitespace_names_fail_closed(self) -> None:
        cases = (
            (
                "duplicate-id",
                "UPDATE images SET image_id = 10 WHERE name = '001-bravo.jpg'",
                "duplicate image identifiers",
            ),
            (
                "duplicate-name",
                "UPDATE images SET name = '000-alpha.jpg' WHERE name = '001-bravo.jpg'",
                "duplicate image names",
            ),
            (
                "whitespace-name",
                "UPDATE images SET name = 'bad name.jpg' WHERE name = '001-bravo.jpg'",
                "invalid image name",
            ),
        )
        for name, statement, expected_error in cases:
            with self.subTest(name=name):
                case_database = self.root / f"{name}.db"
                shutil.copyfile(self.database, case_database)
                connection = sqlite3.connect(case_database)
                try:
                    connection.execute(statement)
                    connection.commit()
                finally:
                    connection.close()
                result = self._run(database=case_database)
                self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertIn(expected_error, result.stdout + result.stderr)

    def test_two_images_must_have_usable_features(self) -> None:
        sparse_database = self.root / "one-usable-image.db"
        images = ordinary_images()
        images[1] = (images[1][0], [], [])
        images[2] = (images[2][0], [], [])
        images[3] = (images[3][0], [], [])
        create_feature_database(sparse_database, images)
        result = self._run(database=sparse_database)
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_faiss_training_requires_three_selected_descriptors(self) -> None:
        boundary_database = self.root / "two-training-descriptors.db"
        images = [
            ("000-alpha.jpg", keypoints4(1), [descriptor(3, 0)]),
            ("001-bravo.jpg", keypoints4(1), [descriptor(97, 0)]),
        ]
        create_feature_database(boundary_database, images)
        self.output.write_text("preserve me\n", encoding="utf-8")
        result = self._run(
            database=boundary_database,
            extra=["--num_visual_words", "2"],
        )
        self.assertFailurePreservesOutput(result)
        self.assertIn(
            "retrieval requires at least three selected training descriptors",
            result.stdout + result.stderr,
        )

    def test_requested_visual_words_equal_to_training_rows_is_reduced(self) -> None:
        boundary_database = self.root / "four-training-descriptors.db"
        images = [
            (
                "000-alpha.jpg",
                keypoints4(2),
                [descriptor(3, row) for row in range(2)],
            ),
            (
                "001-bravo.jpg",
                keypoints4(2),
                [descriptor(97, row) for row in range(2)],
            ),
        ]
        create_feature_database(boundary_database, images)
        result = self._run(
            database=boundary_database,
            extra=["--num_visual_words", "4"],
        )
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertTrue(self.output.is_file())

    def test_feature_metadata_rejects_unknown_and_duplicate_rows(self) -> None:
        cases = (
            (
                "unknown-image",
                "INSERT INTO descriptors(image_id, rows, cols, data, type) "
                "VALUES (999, 0, 128, X'', 0)",
                "unknown image ID",
            ),
            (
                "duplicate-row",
                "INSERT INTO descriptors(image_id, rows, cols, data, type) "
                "SELECT image_id, rows, cols, data, type FROM descriptors "
                "WHERE image_id = 10",
                "duplicate descriptors rows",
            ),
        )
        for name, statement, expected_error in cases:
            with self.subTest(name=name):
                case_database = self.root / f"{name}.db"
                shutil.copyfile(self.database, case_database)
                connection = sqlite3.connect(case_database)
                try:
                    connection.execute(statement)
                    connection.commit()
                finally:
                    connection.close()
                self.output.write_text("preserve me\n", encoding="utf-8")
                result = self._run(database=case_database)
                self.assertFailurePreservesOutput(result)
                self.assertIn(expected_error, result.stdout + result.stderr)

    def test_aggregate_memory_budget_rejects_before_retrieval(self) -> None:
        constrained_budget = "83886080"
        aggregate_database = self.root / "aggregate-budget.db"
        images = [
            (
                f"{image_index:03d}.jpg",
                keypoints4(512, scale_offset=float(image_index)),
                [descriptor(image_index * 7, row) for row in range(512)],
            )
            for image_index in range(64)
        ]
        create_feature_database(aggregate_database, images)
        self.output.write_text("preserve me\n", encoding="utf-8")
        rejected = self._run(
            database=aggregate_database,
            extra=[
                "--memory_budget_bytes",
                constrained_budget,
                "--max_features_per_image",
                "512",
                "--max_training_descriptors",
                "65536",
            ],
        )
        self.assertFailurePreservesOutput(rejected)
        self.assertIn("memory budget", rejected.stdout + rejected.stderr)

        normal_output = self.root / "normal-budget.txt"
        accepted = self._run(
            output=normal_output,
            extra=["--memory_budget_bytes", constrained_budget],
        )
        self.assertEqual(accepted.returncode, 0, accepted.stdout + accepted.stderr)
        self.assertTrue(normal_output.is_file())

    def test_schema_dimensions_types_and_blobs_fail_closed(self) -> None:
        cases: list[tuple[str, str, tuple[object, ...]]] = [
            (
                "bad-keypoint-width",
                "UPDATE keypoints SET cols = 5",
                (),
            ),
            (
                "truncated-keypoint-blob",
                "UPDATE keypoints SET data = X'0000' WHERE image_id = 10",
                (),
            ),
            (
                "truncated-descriptor-blob",
                "UPDATE descriptors SET data = X'00' WHERE image_id = 10",
                (),
            ),
            (
                "wrong-descriptor-width",
                "UPDATE descriptors SET cols = 127 WHERE image_id = 10",
                (),
            ),
            (
                "unsupported-descriptor-type",
                "UPDATE descriptors SET type = 1 WHERE image_id = 10",
                (),
            ),
            (
                "negative-dimensions",
                "UPDATE descriptors SET rows = -1 WHERE image_id = 10",
                (),
            ),
            (
                "overflowing-dimensions",
                "UPDATE descriptors SET rows = 9223372036854775807 WHERE image_id = 10",
                (),
            ),
            (
                "mismatched-feature-count",
                "UPDATE keypoints SET rows = rows - 1 WHERE image_id = 10",
                (),
            ),
        ]
        for name, statement, arguments in cases:
            with self.subTest(name=name):
                case_database = self.root / f"{name}.db"
                shutil.copyfile(self.database, case_database)
                connection = sqlite3.connect(case_database)
                try:
                    connection.execute(statement, arguments)
                    connection.commit()
                finally:
                    connection.close()
                result = self._run(database=case_database)
                self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)

        missing_table = self.root / "missing-table.db"
        connection = sqlite3.connect(missing_table)
        try:
            connection.execute("CREATE TABLE images(image_id INTEGER, name TEXT)")
            connection.commit()
        finally:
            connection.close()
        result = self._run(database=missing_table)
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_null_sqlite_blob_pointer_is_a_typed_failure(self) -> None:
        shim = self.fault_shims.get("sqlite_blob")
        if shim is None:
            self.skipTest("could not build SQLite blob fault shim")
        self.output.write_text("preserve me\n", encoding="utf-8")
        result = self._run(
            environment={"DYLD_INSERT_LIBRARIES": str(shim)},
        )
        self.assertFailurePreservesOutput(result)
        self.assertIn(
            "could not read retrieval database keypoints blob",
            result.stdout + result.stderr,
        )

    def test_four_and_six_column_keypoints_match_frozen_oracle(self) -> None:
        images = ordinary_images()
        images[1] = (images[1][0], keypoints6(20, scale_offset=1.0), images[1][2])
        mixed_database = self.root / "mixed-keypoints.db"
        create_feature_database(mixed_database, images)
        native_output = self.root / "native.txt"
        native = self._run(database=mixed_database, output=native_output)
        self.assertEqual(native.returncode, 0, native.stdout + native.stderr)
        expected = FROZEN_ORACLE_OUTPUTS["mixed_keypoints"]
        self.assertEqual(native_output.read_bytes(), expected)
        if self.oracle_binary is not None:
            oracle_output = self.root / "oracle.txt"
            oracle = self._run(
                database=mixed_database,
                output=oracle_output,
                binary=self.oracle_binary,
            )
            self.assertEqual(oracle.returncode, 0, oracle.stdout + oracle.stderr)
            self.assertEqual(oracle_output.read_bytes(), expected)

    def test_top_scale_selection_and_even_training_sampling_match_oracle(self) -> None:
        images = []
        for image_index, center in enumerate((7, 41, 133, 219)):
            row_count = 180
            scales = [
                float((row * 37 + image_index * 11) % 251 + 1)
                for row in range(row_count)
            ]
            keypoints = [
                (float(row), float(row + 1), scales[row], 0.0)
                for row in range(row_count)
            ]
            descriptors = [descriptor(center, row) for row in range(row_count)]
            images.append((f"{image_index:03d}.jpg", keypoints, descriptors))
        sampled_database = self.root / "sampled.db"
        create_feature_database(sampled_database, images)
        native_output = self.root / "native-sampled.txt"
        options = [
            "--max_features_per_image",
            "180",
            "--max_training_descriptors",
            "512",
            "--num_visual_words",
            "16",
            "--num_checks",
            "16",
        ]
        native = self._run(
            database=sampled_database,
            output=native_output,
            extra=options,
        )
        self.assertEqual(native.returncode, 0, native.stdout + native.stderr)
        expected = FROZEN_ORACLE_OUTPUTS["sampled_features"]
        self.assertEqual(native_output.read_bytes(), expected)
        if self.oracle_binary is not None:
            oracle_output = self.root / "oracle-sampled.txt"
            oracle = self._run(
                database=sampled_database,
                output=oracle_output,
                extra=options,
                binary=self.oracle_binary,
            )
            self.assertEqual(oracle.returncode, 0, oracle.stdout + oracle.stderr)
            self.assertEqual(oracle_output.read_bytes(), expected)

    def test_top_scale_ties_retain_original_row_order(self) -> None:
        images = []
        for image_index, center in enumerate((5, 53, 137, 223)):
            keypoints = [(float(row), float(row + 1), 10.0, 0.0) for row in range(12)]
            descriptors = [descriptor(center, row) for row in range(12)]
            images.append((f"{image_index:03d}.jpg", keypoints, descriptors))
        tied_database = self.root / "top-scale-ties.db"
        create_feature_database(tied_database, images)
        native_output = self.root / "native-ties.txt"
        options = [
            "--max_features_per_image",
            "4",
            "--num_visual_words",
            "4",
        ]
        native = self._run(
            database=tied_database,
            output=native_output,
            extra=options,
        )
        self.assertEqual(native.returncode, 0, native.stdout + native.stderr)
        expected = FROZEN_ORACLE_OUTPUTS["tied_scales"]
        self.assertEqual(native_output.read_bytes(), expected)
        if self.oracle_binary is not None:
            oracle_output = self.root / "oracle-ties.txt"
            oracle = self._run(
                database=tied_database,
                output=oracle_output,
                extra=options,
                binary=self.oracle_binary,
            )
            self.assertEqual(oracle.returncode, 0, oracle.stdout + oracle.stderr)
            self.assertEqual(oracle_output.read_bytes(), expected)

    def test_queries_exclusions_separation_deduplication_and_order(self) -> None:
        query_list = self.root / "queries.txt"
        query_list.write_text(
            "# deliberate order\n002-charlie.jpg\n000-alpha.jpg\n002-charlie.jpg\n",
            encoding="utf-8",
        )
        exclusions = self.root / "excluded.txt"
        exclusions.write_text("000-alpha.jpg 002-charlie.jpg\n", encoding="utf-8")
        result = self._run(
            extra=[
                "--query_image_list_path",
                str(query_list),
                "--excluded_pair_list_path",
                str(exclusions),
                "--minimum_frame_separation",
                "2",
                "--num_images",
                "3",
                "--returned_neighbor_count",
                "2",
            ]
        )
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        lines = self.output.read_text(encoding="utf-8").splitlines()
        self.assertEqual(lines, sorted(lines))
        self.assertEqual(len(lines), len(set(lines)))
        lexical_order = {
            name: index
            for index, name in enumerate(
                sorted(image[0] for image in ordinary_images())
            )
        }
        undirected = set()
        for line in lines:
            first, second = line.split()
            self.assertNotEqual(first, second)
            self.assertGreaterEqual(
                abs(lexical_order[first] - lexical_order[second]), 2
            )
            edge = tuple(sorted((first, second)))
            self.assertNotIn(edge, undirected)
            undirected.add(edge)
            self.assertNotEqual(edge, ("000-alpha.jpg", "002-charlie.jpg"))

    def test_equal_scores_use_lexical_tie_breaking(self) -> None:
        rows = 24
        shared = [descriptor(31, row) for row in range(rows)]
        images = [
            (
                "000-query.jpg",
                keypoints4(rows),
                [descriptor(30, row) for row in range(rows)],
            ),
            ("001-bravo.jpg", keypoints4(rows), shared),
            ("002-charlie.jpg", keypoints4(rows), shared),
            ("003-delta.jpg", keypoints4(rows), shared),
        ]
        tied_database = self.root / "ties.db"
        create_feature_database(tied_database, images)
        query_list = self.root / "tie-query.txt"
        query_list.write_text("000-query.jpg\n", encoding="utf-8")
        result = self._run(
            database=tied_database,
            extra=[
                "--query_image_list_path",
                str(query_list),
                "--num_images",
                "2",
                "--returned_neighbor_count",
                "2",
            ],
        )
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(
            self.output.read_text(encoding="utf-8").splitlines(),
            ["000-query.jpg 001-bravo.jpg", "000-query.jpg 002-charlie.jpg"],
        )

    def test_database_is_immutable_sidecar_free_and_output_is_repeatable(self) -> None:
        before_hash = sha256(self.database)
        before_stat = self.database.stat()
        output_hashes: dict[str, list[str]] = {}
        for thread_count in ("1", "-1"):
            output_hashes[thread_count] = []
            for _ in range(5):
                result = self._run(extra=["--num_threads", thread_count])
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                output_hashes[thread_count].append(sha256(self.output))
                self.assertEqual(sha256(self.database), before_hash)
                after_stat = self.database.stat()
                self.assertEqual(after_stat.st_size, before_stat.st_size)
                self.assertEqual(after_stat.st_mtime_ns, before_stat.st_mtime_ns)
                self.assertFalse(Path(f"{self.database}-wal").exists())
                self.assertFalse(Path(f"{self.database}-journal").exists())
            self.assertEqual(len(set(output_hashes[thread_count])), 1)
        self.assertEqual(
            output_hashes["1"][0],
            output_hashes["-1"][0],
        )

    def test_pending_sqlite_sidecars_fail_without_replacing_old_output(self) -> None:
        for suffix in ("-wal", "-journal"):
            with self.subTest(suffix=suffix):
                sidecar = Path(f"{self.database}{suffix}")
                sidecar.write_bytes(b"pending")
                self.output.write_text("preserve me\n", encoding="utf-8")
                result = self._run()
                self.assertFailurePreservesOutput(result)
                sidecar.unlink()

    def test_pre_rename_fsync_and_rename_failures_preserve_old_output(self) -> None:
        for symbol in ("fsync", "rename"):
            with self.subTest(symbol=symbol):
                shim = self.fault_shims.get(symbol)
                if shim is None:
                    self.skipTest(f"could not build {symbol} fault shim")
                self.output.write_text("preserve me\n", encoding="utf-8")
                result = self._run(
                    environment={"DYLD_INSERT_LIBRARIES": str(shim)},
                )
                self.assertFailurePreservesOutput(result)

    def test_directory_fsync_failure_reports_post_rename_state(self) -> None:
        shim = self.fault_shims.get("directory_fsync")
        if shim is None:
            self.skipTest("could not build directory fsync fault shim")

        expected_output = self.root / "expected-pairs.txt"
        successful = self._run(output=expected_output)
        self.assertEqual(
            successful.returncode, 0, successful.stdout + successful.stderr
        )
        expected_bytes = expected_output.read_bytes()

        self.output.write_text("preserve me\n", encoding="utf-8")
        result = self._run(
            environment={"DYLD_INSERT_LIBRARIES": str(shim)},
        )
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn(
            "could not sync output pair list directory", result.stdout + result.stderr
        )
        self.assertEqual(self.output.read_bytes(), expected_bytes)
        self.assertNoTemporaryOutput()

    def test_non_tied_fixture_exactly_matches_frozen_oracle(self) -> None:
        query_list = self.root / "oracle-queries.txt"
        query_list.write_text("000-alpha.jpg\n002-charlie.jpg\n", encoding="utf-8")
        native_output = self.root / "native-oracle.txt"
        options = ["--query_image_list_path", str(query_list)]
        native = self._run(output=native_output, extra=options)
        self.assertEqual(native.returncode, 0, native.stdout + native.stderr)
        expected = FROZEN_ORACLE_OUTPUTS["non_tied_queries"]
        self.assertEqual(native_output.read_bytes(), expected)
        if self.oracle_binary is not None:
            oracle_output = self.root / "python-oracle.txt"
            oracle = self._run(
                output=oracle_output,
                extra=options,
                binary=self.oracle_binary,
            )
            self.assertEqual(oracle.returncode, 0, oracle.stdout + oracle.stderr)
            self.assertEqual(oracle_output.read_bytes(), expected)


if __name__ == "__main__":
    unittest.main(verbosity=2)
