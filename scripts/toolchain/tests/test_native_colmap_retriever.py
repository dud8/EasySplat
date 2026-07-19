#!/usr/bin/env python3
from __future__ import annotations

import hashlib
import importlib.util
import json
import os
import re
import shutil
import sqlite3
import stat
import struct
import subprocess
import sys
import tempfile
import threading
import unittest
import zlib
from contextlib import contextmanager
from pathlib import Path


ROOT = Path(__file__).resolve().parents[3]
BUILD_SCRIPT = ROOT / "scripts/toolchain/build_colmap.sh"
BUILD_IMPLEMENTATION = ROOT / "scripts/toolchain/build_colmap_impl.sh"
BUILD_SUPERVISOR = ROOT / "scripts/toolchain/secure_colmap_build.py"
RELEASE_SCRIPT_TEST = ROOT / "scripts/ci/test_release_scripts.sh"
OVERLAY_ROOT = ROOT / "Tools/NativeColmap"
PATCH_PATH = ROOT / "scripts/toolchain/patches/colmap-4.1.1-easysplat.patch"
COLMAP_SOURCE_COMMIT = "a0d785fba74b2664f31edc4a29026a8b27c00f67"
COLMAP_SOURCE_VERSION = "4.1.1"

REQUIRED_OPTIONS = (
    "database_path",
    "output_pair_list_path",
    "request_digest",
    "query_stride",
    "query_image_list_path",
    "excluded_pair_list_path",
    "image_group_list_path",
    "image_group_list_digest",
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

RETRIEVAL_OUTCOMES_MAGIC = "EASYSPLAT_RETRIEVAL_OUTCOMES_V2"
RETRIEVAL_OUTCOMES_V3_MAGIC = "EASYSPLAT_RETRIEVAL_OUTCOMES_V3"
RETRIEVAL_ENGINE = "localSiftVocabularyV2"
RETRIEVAL_GROUP_POLICY = "crossGroupV1"
REQUEST_DIGEST = hashlib.sha256(b"EasySplat native retrieval test request").hexdigest()

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
    "src/colmap/controllers/feature_matching.cc",
    "src/colmap/controllers/feature_matching.h",
    "src/colmap/controllers/option_manager.cc",
    "src/colmap/controllers/option_manager.h",
    "src/colmap/controllers/option_manager_test.cc",
    "src/colmap/controllers/pairing.cc",
    "src/colmap/controllers/pairing.h",
    "src/colmap/controllers/undistorters.cc",
    "src/colmap/controllers/undistorters.h",
    "src/colmap/estimators/CMakeLists.txt",
    "src/colmap/exe/CMakeLists.txt",
    "src/colmap/exe/colmap.cc",
    "src/colmap/exe/feature.cc",
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
    "src/colmap/retrieval/visual_index.cc",
    "src/colmap/retrieval/visual_index.h",
    "src/colmap/scene/CMakeLists.txt",
    "src/colmap/scene/database.cc",
    "src/colmap/scene/database.h",
    "src/colmap/scene/database_sqlite.cc",
    "src/colmap/scene/database_sqlite.h",
    "src/colmap/sfm/CMakeLists.txt",
    "src/colmap/sfm/incremental_mapper_impl.cc",
    "src/colmap/sfm/incremental_mapper_test.cc",
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


def length_prefixed_sha256(fields: list[str]) -> str:
    digest = hashlib.sha256()
    for field in fields:
        encoded = field.encode("utf-8")
        digest.update(str(len(encoded)).encode("ascii"))
        digest.update(b":")
        digest.update(encoded)
    return digest.hexdigest()


def canonical_image_group_payload(
    images_in_bytewise_name_order: list[
        tuple[str, list[tuple[float, ...]], list[bytes]]
    ],
    groups: list[int],
) -> tuple[bytes, str]:
    if len(images_in_bytewise_name_order) != len(groups):
        raise AssertionError("one group is required for every database image")
    names = [image[0] for image in images_in_bytewise_name_order]
    if names != sorted(names, key=lambda name: name.encode("utf-8")):
        raise AssertionError("image groups must be serialized in bytewise name order")
    lines = [
        f"{image[0]}\t{group}"
        for image, group in zip(images_in_bytewise_name_order, groups)
    ]
    payload = "".join(f"{line}\n" for line in lines).encode("utf-8")
    digest = length_prefixed_sha256([RETRIEVAL_GROUP_POLICY, *lines])
    return payload, digest


def cross_group_request_digest(
    *,
    group_digest: str,
    query_names: list[str],
    query_stride: int = 10,
    num_images: int = 3,
    returned_neighbor_count: int = 2,
    minimum_frame_separation: int = 0,
) -> str:
    return length_prefixed_sha256(
        [
            RETRIEVAL_ENGINE,
            str(query_stride),
            str(num_images),
            str(returned_neighbor_count),
            str(minimum_frame_separation),
            RETRIEVAL_GROUP_POLICY,
            group_digest,
            *query_names,
        ]
    )


@contextmanager
def open_sqlite(path: Path, **options: object):
    connection = sqlite3.connect(path, **options)
    try:
        with connection:
            yield connection
    finally:
        connection.close()


def parse_native_retrieval_receipt(
    path: Path,
) -> tuple[list[str], list[list[str]], list[str]]:
    contents = path.read_bytes()
    text = contents.decode("utf-8", errors="strict")
    if not text.endswith("\n"):
        raise AssertionError("native retrieval receipt must end with a newline")
    lines = text.splitlines()
    if not lines:
        raise AssertionError("native retrieval receipt is empty")
    header = lines[0].split()
    if len(header) not in {8, 10}:
        raise AssertionError(f"invalid native retrieval header: {lines[0]!r}")
    if (
        header[0]
        not in {
            RETRIEVAL_OUTCOMES_MAGIC,
            RETRIEVAL_OUTCOMES_V3_MAGIC,
        }
        or header[1] != RETRIEVAL_ENGINE
    ):
        raise AssertionError(f"unexpected native retrieval header: {lines[0]!r}")
    if header[0] == RETRIEVAL_OUTCOMES_MAGIC:
        if len(header) != 8:
            raise AssertionError(f"invalid V2 native retrieval header: {lines[0]!r}")
        query_count = int(header[6])
    else:
        if len(header) != 10 or header[6] != RETRIEVAL_GROUP_POLICY:
            raise AssertionError(f"invalid V3 native retrieval header: {lines[0]!r}")
        query_count = int(header[8])
    query_lines = [line.split() for line in lines[1 : 1 + query_count]]
    if len(query_lines) != query_count:
        raise AssertionError("native retrieval receipt omitted query outcomes")
    for fields in query_lines:
        if len(fields) < 4 or fields[0] != "Q":
            raise AssertionError(f"invalid native query outcome: {fields!r}")
        count = int(fields[3])
        if fields[1] == "ranked":
            if count < 1 or len(fields[4:]) != count:
                raise AssertionError(f"inconsistent ranked outcome: {fields!r}")
        elif fields[1] == "noRankedNeighbors":
            if count != 0 or len(fields) != 4:
                raise AssertionError(f"inconsistent empty outcome: {fields!r}")
        else:
            raise AssertionError(f"unknown native query status: {fields!r}")
    pair_lines = lines[1 + query_count :]
    if any(not line.startswith("P ") for line in pair_lines):
        raise AssertionError("native retrieval receipt has a non-pair trailer")
    pairs = [line.removeprefix("P ") for line in pair_lines]
    if pairs != sorted(pairs) or len(pairs) != len(set(pairs)):
        raise AssertionError("native retrieval pairs are not canonical")
    return header, query_lines, pairs


def native_pair_bytes(path: Path) -> bytes:
    _, _, pair_lines = parse_native_retrieval_receipt(path)
    return b"".join(f"{line}\n".encode("utf-8") for line in pair_lines)


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


def write_test_grayscale_png(
    path: Path,
    width: int,
    height: int,
    phase: int,
    *,
    simple: bool = False,
) -> None:
    def chunk(kind: bytes, payload: bytes) -> bytes:
        checksum = zlib.crc32(kind + payload) & 0xFFFFFFFF
        return (
            struct.pack(">I", len(payload))
            + kind
            + payload
            + struct.pack(">I", checksum)
        )

    rows = []
    for line in range(height):
        rows.append(b"\0")
        if simple:
            rows.append(
                bytes((column // 16 + phase * 17) % 256 for column in range(width))
            )
        else:
            rows.append(
                bytes(
                    (
                        column * 17
                        + (column // 7) * 29
                        + line * 11
                        + (line // 5) * 37
                        + phase * 43
                    )
                    % 256
                    for column in range(width)
                )
            )
    path.write_bytes(
        b"\x89PNG\r\n\x1a\n"
        + chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 0, 0, 0, 0))
        + chunk(b"IDAT", zlib.compress(b"".join(rows)))
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
        header_text = header.read_text(encoding="utf-8")
        self.assertIn("char **argv", header_text)
        self.assertIn("} // namespace colmap", header_text)
        self.assertNotIn("char** argv", header_text)
        self.assertNotIn("}  // namespace colmap", header_text)
        patch = PATCH_PATH.read_text(encoding="utf-8")
        self.assertIn('#include "colmap/exe/local_vocab_retriever.h"', patch)
        self.assertIn('"local_vocab_retriever"', patch)
        self.assertIn("local_vocab_retriever.cc", patch)
        self.assertIn("FAISS_ENABLE_METAL OFF", patch)
        self.assertLess(PATCH_PATH.stat().st_size, 147_456)

        self.assertIn("std::unordered_set<int> excluded_image_ids;", patch)
        self.assertLess(
            patch.index("image_scores->erase("),
            patch.index("auto SortFunc", patch.index("image_scores->erase(")),
        )
        keypoint_validation = patch.index(
            "THROW_CHECK_EQ(descriptors.data.rows(), keypoints.size());"
        )
        self.assertLess(
            keypoint_validation,
            patch.index("image_scores->empty()", keypoint_validation),
        )

    def test_matches_importer_requires_native_empty_result_authority(self) -> None:
        patch = PATCH_PATH.read_text(encoding="utf-8")
        required_contract = (
            'AddDefaultOption("EasySplat.require_empty_matching_results"',
            "class DatabaseFileIdentity",
            "O_NOFOLLOW",
            "status.st_nlink != 1",
            "class ImporterDatabaseTransaction",
            "BeginImmediateTransaction()",
            '"BEGIN IMMEDIATE TRANSACTION"',
            "RollbackTransaction()",
            "NumMatchedImagePairs()",
            "NumVerifiedImagePairs()",
            "matching_completed->load()",
            "SignalInvalidSetup();",
            "SignalValidSetup();",
            "return EXIT_FAILURE;",
        )
        for contract in required_contract:
            with self.subTest(contract=contract):
                self.assertIn(contract, patch)
        self.assertNotIn(
            'AddRequiredOption("EasySplat.require_empty_matching_results"',
            patch,
        )
        self.assertNotIn("MatchingResultsAreNonEmpty", patch)
        path_checks = [
            match.start()
            for match in re.finditer(
                r"database_identity->MatchesPath\(\)",
                patch,
            )
        ]
        self.assertGreaterEqual(len(path_checks), 3)
        commit = patch.index("importer_transaction->Commit()")
        self.assertTrue(all(path_check < commit for path_check in path_checks))

        self.assertIn("fail_on_invalid_pair = true", patch)
        self.assertIn("bool IsValid() const override", patch)
        self.assertIn("pair_generator->IsValid()", patch)

        runner = (
            ROOT / "EasySplatCore/Sources/EasySplatCore/SfM/ColmapRunner.swift"
        ).read_text(encoding="utf-8")
        self.assertIn(
            '"--EasySplat.require_empty_matching_results", "1"',
            runner,
        )
        benchmark = (ROOT / "scripts/benchmark_da3.sh").read_text(encoding="utf-8")
        invocation = benchmark.split('"$COLMAP_BIN" matches_importer \\', 1)[1]
        invocation = invocation.split(">>", 1)[0]
        self.assertIn(
            "--EasySplat.require_empty_matching_results 1",
            invocation,
        )

    def test_native_retrieval_ties_are_broken_before_truncation(self) -> None:
        patch = PATCH_PATH.read_text(encoding="utf-8")
        tie_break = "return score1.image_id < score2.image_id;"
        self.assertGreaterEqual(patch.count(tie_break), 2)
        for sort_position in [
            match.start() for match in re.finditer(r"auto SortFunc", patch)
        ]:
            comparator = patch[sort_position : sort_position + 420]
            self.assertIn("score1.score != score2.score", comparator)
            self.assertIn(tie_break, comparator)

    def test_native_retriever_binds_the_open_database_inode(self) -> None:
        source = (OVERLAY_ROOT / "local_vocab_retriever.cc").read_text(encoding="utf-8")
        for contract in (
            "class DatabaseInputBinding",
            "O_NOFOLLOW",
            "status.st_nlink != 1",
            '"/dev/fd/"',
            "mode=ro&immutable=1",
            "ValidatePath()",
            "database_binding.ValidatePath()",
        ):
            with self.subTest(contract=contract):
                self.assertIn(contract, source)
        self.assertGreaterEqual(source.count("database_binding.ValidatePath()"), 3)

    def test_native_retriever_holds_one_snapshot_and_revalidates_sidecars(
        self,
    ) -> None:
        source = (OVERLAY_ROOT / "local_vocab_retriever.cc").read_text(encoding="utf-8")
        for contract in (
            "class DatabaseSidecarBindings",
            '{"-wal", "-journal", "-shm"}',
            'Execute("BEGIN")',
            "database_sidecars.ValidateUnchanged()",
        ):
            with self.subTest(contract=contract):
                self.assertIn(contract, source)
        self.assertGreaterEqual(
            source.count("database_sidecars.ValidateUnchanged()"), 3
        )
        begin = source.index('Execute("BEGIN")')
        first_read = source.index("RetrievePairs(options, database, inputs)")
        publication = source.index("AtomicWrite(output_binding")
        self.assertLess(begin, first_read)
        self.assertLess(first_read, publication)

    def test_tracked_product_callers_cannot_bypass_matches_importer_authority(
        self,
    ) -> None:
        tracked = subprocess.run(
            ["/usr/bin/git", "-C", str(ROOT), "ls-files", "-z"],
            check=True,
            capture_output=True,
        ).stdout.split(b"\0")
        shell_invocations: list[tuple[str, str]] = []
        for encoded_path in tracked:
            if not encoded_path:
                continue
            relative = encoded_path.decode("utf-8")
            if (
                "/Tests/" in relative
                or relative.startswith("scripts/toolchain/tests/")
                or relative.startswith("scripts/ci/")
                or relative.startswith("scripts/toolchain/patches/")
            ):
                continue
            path = ROOT / relative
            if path.suffix not in {".sh", ".zsh"}:
                continue
            source = path.read_text(encoding="utf-8")
            lines = source.splitlines()
            for index, line in enumerate(lines):
                if (
                    re.match(
                        r'^\s*"?\$\{?[A-Z_]*COLMAP[A-Z_]*\}?"? '
                        r"matches_importer \\?$",
                        line,
                    )
                    is None
                ):
                    continue
                command = [line]
                cursor = index
                while command[-1].rstrip().endswith("\\"):
                    cursor += 1
                    self.assertLess(cursor, len(lines), relative)
                    command.append(lines[cursor])
                shell_invocations.append((relative, "\n".join(command)))

        self.assertEqual(
            [path for path, _ in shell_invocations],
            ["scripts/benchmark_da3.sh"],
        )
        for path, body in shell_invocations:
            with self.subTest(path=path):
                self.assertIn(
                    "--EasySplat.require_empty_matching_results 1",
                    body,
                )

    def test_native_retriever_declares_authenticated_query_outcomes(self) -> None:
        source = (OVERLAY_ROOT / "local_vocab_retriever.cc").read_text(encoding="utf-8")
        for required_contract in (
            'AddRequiredOption("request_digest"',
            'AddRequiredOption("query_stride"',
            RETRIEVAL_OUTCOMES_MAGIC,
            RETRIEVAL_ENGINE,
            "Q ranked ",
            "Q noRankedNeighbors ",
            "P ",
        ):
            self.assertIn(required_contract, source)

        packager = (ROOT / "scripts/toolchain/package_toolchain.sh").read_text(
            encoding="utf-8"
        )
        self.assertRegex(
            packager,
            r"require_colmap_options local_vocab_retriever[\s\\]+"
            r"[\s\S]*request_digest[\s\\]+query_stride",
        )

    def test_native_retriever_declares_stable_cross_group_inputs(self) -> None:
        source = (OVERLAY_ROOT / "local_vocab_retriever.cc").read_text(encoding="utf-8")
        for required_contract in (
            'AddDefaultOption("image_group_list_path"',
            'AddDefaultOption("image_group_list_digest"',
            RETRIEVAL_OUTCOMES_V3_MAGIC,
            RETRIEVAL_GROUP_POLICY,
            "CC_SHA256",
            "O_NOFOLLOW",
            "st_nlink != 1",
            "ValidateUnchanged",
        ):
            with self.subTest(contract=required_contract):
                self.assertIn(required_contract, source)
        self.assertNotIn("std::ifstream", source)

        builder = BUILD_IMPLEMENTATION.read_text(encoding="utf-8")
        self.assertIn(
            "for command in image_group_list_path image_group_list_digest",
            builder,
        )
        self.assertIn(
            'die "installed COLMAP local_vocab_retriever lacks $command"',
            builder,
        )

    def test_native_retriever_vote_and_verifies_the_bounded_candidate_pool(
        self,
    ) -> None:
        source = (OVERLAY_ROOT / "local_vocab_retriever.cc").read_text(encoding="utf-8")
        query_configuration = source.split(
            "retrieval::VisualIndex::QueryOptions query_options;", 1
        )[1].split("std::set<ImagePair> emitted;", 1)[0]
        self.assertIn(
            "query_options.max_num_images = static_cast<int>(retrieval_limit);",
            query_configuration,
        )
        self.assertRegex(
            query_configuration,
            r"query_options\.num_images_after_verification\s*=\s*"
            r"static_cast<int>\(retrieval_limit\);",
        )
        self.assertNotIn("query_options.max_num_images = -1", query_configuration)
        self.assertNotIn(
            "query_options.num_images_after_verification = 0",
            query_configuration,
        )
        self.assertIn("query_options.excluded_image_ids.clear();", source)
        self.assertIn("vocabulary retrieval returned an excluded image score", source)
        self.assertNotIn(
            "static_cast<size_t>(options.num_images) + 1",
            source,
        )
        memory_estimate = source.split("uint64_t EstimateRetrievalMemory", 1)[1].split(
            "ImageFeatures ReadSelectedFeatures", 1
        )[0]
        self.assertIn("maximum_verification_candidate_count", memory_estimate)
        self.assertIn("maximum_verification_match_count", memory_estimate)
        self.assertIn("kPairStateBytes", memory_estimate)
        self.assertIn("kExcludedImageStateBytes", memory_estimate)
        self.assertIn('"Q ranked "', source)
        self.assertIn('"Q noRankedNeighbors "', source)
        self.assertNotIn('"Q verified "', source)
        self.assertNotIn('"Q noVerifiedNeighbors "', source)

    def test_native_retriever_builds_only_sparse_per_query_exclusions(self) -> None:
        patch = PATCH_PATH.read_text(encoding="utf-8")
        source = (OVERLAY_ROOT / "local_vocab_retriever.cc").read_text(encoding="utf-8")
        for contract in (
            "const std::vector<int>* image_group_by_id = nullptr;",
            "int excluded_image_group = -1;",
            "int excluded_image_id_begin = 0;",
            "int excluded_image_id_end = 0;",
            "bool IsImageExcluded(int image_id) const",
            "options.IsImageExcluded(image_score.image_id)",
        ):
            with self.subTest(contract=contract):
                self.assertIn(contract, patch)
        erase = patch.index("image_scores->erase(")
        self.assertLess(erase, patch.index("auto SortFunc", erase))

        query_loop = source.split("for (const int query_id : query_ids) {", 1)[1].split(
            "std::vector<retrieval::ImageScore> scores;", 1
        )[0]
        self.assertNotIn("for (const ImageFeatures &candidate : images)", query_loop)
        self.assertNotIn("order_by_id", source)
        self.assertIn("neighbors_by_retrieval_id", query_loop)
        self.assertIn("query_options.image_group_by_id", query_loop)
        self.assertIn("query_options.excluded_image_id_begin", query_loop)
        self.assertIn("query_options.excluded_image_id_end", query_loop)

    def test_strict_matches_importer_binds_the_sqlite_main_file(self) -> None:
        patch = PATCH_PATH.read_text(encoding="utf-8")
        for contract in (
            "MainFileMatchesPath",
            "SQLITE_FCNTL_HAS_MOVED",
            "sqlite3_db_filename",
            "startup_database->MainFileMatchesPath",
        ):
            with self.subTest(contract=contract):
                self.assertIn(contract, patch)
        open_database = patch.index(
            "startup_database = OpenSqliteDatabaseBoundToDescriptor"
        )
        bound_check = patch.index(
            "startup_database->MainFileMatchesPath", open_database
        )
        begin_transaction = patch.index(
            "std::make_unique<ImporterDatabaseTransaction>", open_database
        )
        self.assertLess(bound_check, begin_transaction)

    def test_strict_feature_pair_parser_requires_complete_exact_input(self) -> None:
        patch = PATCH_PATH.read_text(encoding="utf-8")
        for contract in (
            "image_name1 == image_name2",
            "match_list_stream.bad()",
            "match_line_stream >> extra",
            "image_pair_stream >> extra",
        ):
            with self.subTest(contract=contract):
                self.assertIn(contract, patch)
        bad_check = patch.index("match_list_stream.bad()")
        completion = patch.index("completion_success_->store(true)", bad_check)
        self.assertLess(bad_check, completion)

    def test_build_freezes_native_patch_and_overlay_before_compilation(self) -> None:
        script = BUILD_IMPLEMENTATION.read_text(encoding="utf-8")
        for contract in (
            "freeze_native_inputs()",
            "FROZEN_COLMAP_PATCH_FD",
            "FROZEN_RETRIEVER_HEADER_FD",
            "FROZEN_RETRIEVER_SOURCE_FD",
            "FROZEN_OVERLAY_SHA256",
            "os.pread",
            'subprocess.run(\n        [git, "-C", source, "apply"',
            '"src/colmap/exe/local_vocab_retriever.cc"',
        ):
            with self.subTest(contract=contract):
                self.assertIn(contract, script)
        final_pipeline = script.rsplit("\npreflight\n", 1)[1]
        self.assertLess(
            final_pipeline.index("freeze_native_inputs"),
            final_pipeline.index("prepare_source"),
        )
        self.assertNotIn('exec 9>"$BUILD_LOCK"', script)
        self.assertIn('SRC="./src"', script)
        self.assertIn('BUILD="./build"', script)
        self.assertIn('GUARDED_STAGE_FD="$3"', script)
        self.assertIn("await_promotion_approval", final_pipeline)

    def test_frozen_native_inputs_survive_mid_build_live_mutation(self) -> None:
        spec = importlib.util.spec_from_file_location(
            "secure_colmap_build_for_source_contract", BUILD_SUPERVISOR
        )
        self.assertIsNotNone(spec)
        assert spec is not None and spec.loader is not None
        supervisor = importlib.util.module_from_spec(spec)
        sys.modules[spec.name] = supervisor
        spec.loader.exec_module(supervisor)
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            overlay = root / "overlay"
            overlay.mkdir()
            patch_path = root / "reviewed.patch"
            header_path = overlay / "local_vocab_retriever.h"
            source_path = overlay / "local_vocab_retriever.cc"
            original_payloads = {
                patch_path: b"reviewed patch bytes\n",
                header_path: b"reviewed header bytes\n",
                source_path: b"reviewed source bytes\n",
            }
            for path, payload in original_payloads.items():
                path.write_bytes(payload)
            snapshot = root / "frozen"
            snapshot.mkdir(mode=0o700)
            frozen = supervisor.freeze_inputs(
                (patch_path, header_path, source_path), snapshot
            )
            try:
                for path in original_payloads:
                    path.write_bytes(b"mutated after snapshot\n")
                expected = tuple(original_payloads.values())
                self.assertEqual(
                    tuple(supervisor.read_frozen(item) for item in frozen),
                    expected,
                )
                for item in frozen:
                    supervisor.verify_frozen(item, item.sha256)
                    self.assertEqual(os.fstat(item.fd).st_nlink, 0)
                    self.assertEqual(stat.S_IMODE(os.fstat(item.fd).st_mode), 0o400)
            finally:
                supervisor.close_frozen_inputs(frozen)

    def test_parallel_feature_writer_uses_sorted_reader_ordinals_on_fresh_databases(
        self,
    ) -> None:
        patch = PATCH_PATH.read_text(encoding="utf-8")
        for contract in (
            "requested_database_id = kInvalidImageId",
            "database_path_was_pristine_",
            "IsPristineDatabasePath(database_path)",
            "database_->WriteImage(image_data.image, /*use_image_id=*/true)",
            "database_->WritePosePrior(image_data.pose_prior,",
            "database_->WriteFrame(",
            "const size_t reader_index = image_reader_.NextIndex()",
        ):
            self.assertIn(contract, patch)

    def test_incremental_mapper_uses_rank_ordered_parallel_initialization(self) -> None:
        patch = PATCH_PATH.read_text(encoding="utf-8")
        mapper_diff = patch.split(
            "diff --git a/src/colmap/sfm/incremental_mapper_impl.cc ", 1
        )[1].split("\ndiff --git ", 1)[0]
        surviving_lines = "\n".join(
            line[1:]
            for line in mapper_diff.splitlines()
            if (line.startswith("+") and not line.startswith("+++"))
            or line.startswith(" ")
        )

        for contract in (
            "return a.image_id < b.image_id;",
            "return image1.first < image2.first;",
            "std::atomic<size_t> best_success_task",
            "task_index_by_image_id",
            "existing_init_image_pairs",
            "attempted_pair_ids",
            "CompareExchangeBestSuccessTask",
        ):
            self.assertIn(contract, surviving_lines)
        self.assertNotIn("std::atomic_bool stop", surviving_lines)
        self.assertNotIn("if (stop.load())", surviving_lines)

        self.assertIn(
            "FindInitialImagePairDeterministicAcrossThreadCounts",
            patch,
        )

    def test_patch_has_the_exact_reviewed_source_surface(self) -> None:
        patch = PATCH_PATH.read_text(encoding="utf-8")
        paths = tuple(re.findall(r"^diff --git a/(\S+) b/\1$", patch, re.MULTILINE))
        self.assertEqual(paths, PATCHED_COLMAP_PATHS)

        build_implementation = BUILD_IMPLEMENTATION.read_text(encoding="utf-8")
        allowlist_line = next(
            (
                line
                for line in build_implementation.splitlines()
                if line.startswith('  [ "$modified_paths" = $\'')
            ),
            None,
        )
        self.assertIsNotNone(allowlist_line)
        assert allowlist_line is not None
        prefix = '  [ "$modified_paths" = $\''
        suffix = "' ] || \\"
        self.assertTrue(allowlist_line.endswith(suffix))
        allowlisted_paths = tuple(
            allowlist_line[len(prefix) : -len(suffix)].split(r"\n")
        )
        self.assertEqual(allowlisted_paths, PATCHED_COLMAP_PATHS)

    def test_patch_defers_ransac_synchronization_to_pinned_upstream(self) -> None:
        patch = PATCH_PATH.read_text(encoding="utf-8")
        for path in (
            "src/colmap/optim/loransac.h",
            "src/colmap/optim/ransac.h",
        ):
            with self.subTest(path=path):
                marker = f"diff --git a/{path} b/{path}"
                self.assertNotIn(marker, patch)

        script = BUILD_IMPLEMENTATION.read_text(encoding="utf-8")
        self.assertIn(f'COLMAP_COMMIT="{COLMAP_SOURCE_COMMIT}"', script)
        self.assertIn(f'COLMAP_VERSION="{COLMAP_SOURCE_VERSION}"', script)
        self.assertNotIn("best_support_mutex", patch)

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
        command_patch = patch.split(
            "diff --git a/src/colmap/exe/colmap.cc b/src/colmap/exe/colmap.cc",
            1,
        )[1].split("\ndiff --git ", 1)[0]
        surviving_lines = "\n".join(
            line[1:]
            for line in command_patch.splitlines()
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
            '"build_supervisor_sha256": sha256(build_supervisor_path)',
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

    def test_build_script_pins_reviewed_colmap_faiss_and_generic_apple_silicon(
        self,
    ) -> None:
        script = BUILD_IMPLEMENTATION.read_text(encoding="utf-8")
        self.assertIn(f'COLMAP_COMMIT="{COLMAP_SOURCE_COMMIT}"', script)
        self.assertIn(f'COLMAP_VERSION="{COLMAP_SOURCE_VERSION}"', script)
        self.assertIn("colmap-4.1.1-easysplat.patch", script)
        self.assertNotIn("colmap-4.1.0-easysplat.patch", script)
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
            "struct QueryOutcome", 1
        )[0]
        self.assertIn("class OutputPathBinding", source)
        output_binding = source.split("class OutputPathBinding", 1)[1].split(
            "void AtomicWrite(", 1
        )[0]
        for required_boundary in (
            "::openat(",
            "O_DIRECTORY",
            "O_NOFOLLOW",
            "AT_SYMLINK_NOFOLLOW",
            "::fstatat(",
            "::linkat(",
            "::unlinkat(",
        ):
            self.assertIn(required_boundary, output_binding)
        self.assertIn("::renameat(", atomic_write)
        self.assertIn("::renameatx_np(", atomic_write)
        self.assertIn("RENAME_EXCL", atomic_write)
        self.assertIn("output.ValidateBoundDirectory()", atomic_write)
        self.assertIn("output.RestoreAfterFailedPublication(", atomic_write)
        self.assertIn("::fsync(output.directory_descriptor())", atomic_write)
        self.assertNotIn("::mkstemp(", atomic_write)
        self.assertNotIn("::rename(", atomic_write)
        self.assertNotIn("output.c_str()", atomic_write)

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
        self.assertNotIn('EASYSPLAT_PYCOLMAP_COLMAP_BIN=""', implementation)
        self.assertIn(
            "NativeRetrieverTests NativeMatchesImporterTests",
            implementation,
        )
        self.assertRegex(
            implementation,
            r"validate_commands\s*\n"
            r"validate_relocated_runtime\s*\n"
            r"validate_native_retriever\s*\n",
        )

        packager = (ROOT / "scripts/toolchain/package_toolchain.sh").read_text(
            encoding="utf-8"
        )
        self.assertIn("validate_native_colmap_semantics()", packager)
        self.assertIn(
            "NativeRetrieverTests NativeMatchesImporterTests",
            packager,
        )
        self.assertRegex(
            packager,
            r"validate_native_colmap_cli\s*\n"
            r"validate_native_colmap_semantics\s*\n",
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
                "static int fail_renameat(int from_fd, const char *from, "
                "int to_fd, const char *to) {"
                "(void)from_fd; (void)from; (void)to_fd; (void)to; "
                "errno=EIO; return -1;}\n"
                "DYLD_INTERPOSE(fail_rename, rename)\n"
                "DYLD_INTERPOSE(fail_renameat, renameat)\n"
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
            "parent_swap": (
                "#include <errno.h>\n#include <fcntl.h>\n"
                "#include <limits.h>\n#include <sqlite3.h>\n"
                "#include <stdio.h>\n#include <stdlib.h>\n"
                "#include <string.h>\n#include <sys/stat.h>\n"
                "#include <sys/syscall.h>\n#include <unistd.h>\n"
                + interpose
                + "static volatile int did_swap = 0;\n"
                "static void maybe_swap_parent(const char *phase) {\n"
                '  const char *selected = getenv("EASYSPLAT_TEST_SWAP_PHASE");\n'
                "  if (selected == 0 || strcmp(selected, phase) != 0 ||\n"
                "      !__sync_bool_compare_and_swap(&did_swap, 0, 1)) return;\n"
                '  const char *parent = getenv("EASYSPLAT_TEST_SWAP_PARENT");\n'
                '  const char *moved = getenv("EASYSPLAT_TEST_SWAP_MOVED");\n'
                '  const char *target = getenv("EASYSPLAT_TEST_SWAP_TARGET");\n'
                "  if (parent == 0 || moved == 0 || target == 0 ||\n"
                "      renamex_np(parent, moved, 0) != 0 ||\n"
                "      symlink(target, parent) != 0) _exit(211);\n"
                "}\n"
                "static int swap_sqlite3_prepare_v2(sqlite3 *database, "
                "const char *sql, int bytes, sqlite3_stmt **statement, "
                "const char **tail) {\n"
                '  maybe_swap_parent("after_validation");\n'
                "  return sqlite3_prepare_v3(database, sql, bytes, 0, "
                "statement, tail);\n"
                "}\n"
                "static int swap_fsync(int descriptor) {\n"
                '  maybe_swap_parent("after_temp");\n'
                "  int result = (int)syscall(SYS_fsync, descriptor);\n"
                '  if (result == 0) maybe_swap_parent("after_write");\n'
                "  return result;\n"
                "}\n"
                "static int swap_renameat(int from_directory, const char *from, "
                "int to_directory, const char *to) {\n"
                '  maybe_swap_parent("after_write");\n'
                "  int result = renameatx_np(from_directory, from, "
                "to_directory, to, 0);\n"
                '  if (result == 0) maybe_swap_parent("after_rename");\n'
                "  return result;\n"
                "}\n"
                "DYLD_INTERPOSE(swap_sqlite3_prepare_v2, sqlite3_prepare_v2)\n"
                "DYLD_INTERPOSE(swap_fsync, fsync)\n"
                "DYLD_INTERPOSE(swap_renameat, renameat)\n"
            ),
            "database_swap": (
                "#include <sqlite3.h>\n#include <stdio.h>\n"
                "#include <stdlib.h>\n#include <unistd.h>\n"
                + interpose
                + "static volatile int did_swap_database = 0;\n"
                "static int swap_database_sqlite3_prepare_v2("
                "sqlite3 *database, const char *sql, int bytes, "
                "sqlite3_stmt **statement, const char **tail) {\n"
                "  if (__sync_bool_compare_and_swap(&did_swap_database, 0, 1)) {\n"
                '    const char *path = getenv("EASYSPLAT_TEST_DATABASE_PATH");\n'
                '    const char *moved = getenv("EASYSPLAT_TEST_DATABASE_MOVED");\n'
                "    const char *replacement = "
                'getenv("EASYSPLAT_TEST_DATABASE_REPLACEMENT");\n'
                "    if (path == 0 || moved == 0 || replacement == 0 ||\n"
                "        rename(path, moved) != 0 || "
                "symlink(replacement, path) != 0) _exit(213);\n"
                "  }\n"
                "  return sqlite3_prepare_v3(database, sql, bytes, 0, "
                "statement, tail);\n"
                "}\n"
                "DYLD_INTERPOSE(swap_database_sqlite3_prepare_v2, "
                "sqlite3_prepare_v2)\n"
            ),
            "wal_commit": (
                "#include <sqlite3.h>\n#include <stdlib.h>\n"
                "#include <sys/syscall.h>\n#include <unistd.h>\n"
                + interpose
                + "static volatile int did_commit_wal = 0;\n"
                "static sqlite3 *held_reader = 0;\n"
                "static sqlite3 *held_writer = 0;\n"
                "static void commit_wal_change(void) {\n"
                "  if (!__sync_bool_compare_and_swap(&did_commit_wal, 0, 1)) "
                "return;\n"
                '  const char *path = getenv("EASYSPLAT_TEST_DATABASE_PATH");\n'
                "  char *error = 0;\n"
                "  if (path == 0 || sqlite3_open(path, &held_reader) != SQLITE_OK ||\n"
                '      sqlite3_exec(held_reader, "BEGIN; SELECT COUNT(*) FROM images", '
                "0, 0, &error) != SQLITE_OK) _exit(231);\n"
                "  if (sqlite3_open(path, &held_writer) != SQLITE_OK ||\n"
                "      sqlite3_exec(held_writer, "
                '"PRAGMA wal_autocheckpoint=0; PRAGMA user_version=7", '
                "0, 0, &error) != SQLITE_OK) _exit(232);\n"
                "}\n"
                "static int commit_wal_on_fsync(int descriptor) {\n"
                "  int result = (int)syscall(SYS_fsync, descriptor);\n"
                "  if (result == 0) commit_wal_change();\n"
                "  return result;\n"
                "}\n"
                "DYLD_INTERPOSE(commit_wal_on_fsync, fsync)\n"
            ),
            "optional_input_change": (
                "#include <fcntl.h>\n#include <stdio.h>\n#include <stdlib.h>\n"
                "#include <string.h>\n"
                "#include <sqlite3.h>\n"
                "#include <sys/stat.h>\n#include <sys/syscall.h>\n#include <unistd.h>\n"
                + interpose
                + "static volatile int did_change_optional_input = 0;\n"
                "static void change_optional_input(const char *phase) {\n"
                "  const char *selected = "
                'getenv("EASYSPLAT_TEST_INPUT_CHANGE_PHASE");\n'
                "  if (selected == 0 || strcmp(selected, phase) != 0) return;\n"
                "  if (!__sync_bool_compare_and_swap("
                "&did_change_optional_input, 0, 1)) return;\n"
                '  const char *mode = getenv("EASYSPLAT_TEST_INPUT_CHANGE_MODE");\n'
                '  const char *path = getenv("EASYSPLAT_TEST_INPUT_PATH");\n'
                "  if (mode == 0 || path == 0) _exit(221);\n"
                '  if (strcmp(mode, "swap") == 0) {\n'
                '    const char *moved = getenv("EASYSPLAT_TEST_INPUT_MOVED");\n'
                "    const char *replacement = "
                'getenv("EASYSPLAT_TEST_INPUT_REPLACEMENT");\n'
                "    if (moved == 0 || replacement == 0 || "
                "rename(path, moved) != 0 ||\n"
                "        symlink(replacement, path) != 0) _exit(222);\n"
                '  } else if (strcmp(mode, "mutate") == 0) {\n'
                "    int input = open(path, O_RDWR | O_NOFOLLOW);\n"
                "    unsigned char byte = 0;\n"
                "    if (input < 0 || pread(input, &byte, 1, 0) != 1) _exit(223);\n"
                "    byte ^= 0x01;\n"
                "    if (pwrite(input, &byte, 1, 0) != 1 || "
                "syscall(SYS_fsync, input) != 0) _exit(224);\n"
                "    close(input);\n"
                "  } else {\n"
                "    _exit(225);\n"
                "  }\n"
                "}\n"
                "static int change_optional_input_fsync(int descriptor) {\n"
                "  int result = (int)syscall(SYS_fsync, descriptor);\n"
                "  struct stat status;\n"
                "  if (result == 0 && fstat(descriptor, &status) == 0 && "
                'S_ISREG(status.st_mode)) change_optional_input("publish");\n'
                "  return result;\n"
                "}\n"
                "static int change_optional_input_sqlite3_prepare_v2("
                "sqlite3 *database, const char *sql, int bytes, "
                "sqlite3_stmt **statement, const char **tail) {\n"
                '  change_optional_input("prepare");\n'
                "  return sqlite3_prepare_v3(database, sql, bytes, 0, "
                "statement, tail);\n"
                "}\n"
                "DYLD_INTERPOSE(change_optional_input_fsync, fsync)\n"
                "DYLD_INTERPOSE(change_optional_input_sqlite3_prepare_v2, "
                "sqlite3_prepare_v2)\n"
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
        self.root = Path(self.temporary.name).resolve()
        self.database = self.root / "features.db"
        self.output = self.root / "pairs.txt"
        create_feature_database(self.database, ordinary_images())

    def _write_group_map(
        self,
        groups: list[int],
        *,
        images: list[tuple[str, list[tuple[float, ...]], list[bytes]]] | None = None,
        name: str = "image-groups.txt",
    ) -> tuple[Path, str]:
        selected_images = images or ordinary_images()
        payload, digest = canonical_image_group_payload(selected_images, groups)
        path = self.root / name
        path.write_bytes(payload)
        return path, digest

    def _cross_group_extra(
        self,
        *,
        group_path: Path,
        group_digest: str,
        query_names: list[str],
        query_stride: int = 10,
        num_images: int = 3,
        returned_neighbor_count: int = 2,
        minimum_frame_separation: int = 0,
    ) -> list[str]:
        request_digest = cross_group_request_digest(
            group_digest=group_digest,
            query_names=query_names,
            query_stride=query_stride,
            num_images=num_images,
            returned_neighbor_count=returned_neighbor_count,
            minimum_frame_separation=minimum_frame_separation,
        )
        return [
            "--image_group_list_path",
            str(group_path),
            "--image_group_list_digest",
            group_digest,
            "--request_digest",
            request_digest,
            "--query_stride",
            str(query_stride),
            "--num_images",
            str(num_images),
            "--returned_neighbor_count",
            str(returned_neighbor_count),
            "--minimum_frame_separation",
            str(minimum_frame_separation),
        ]

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
            "--request_digest",
            REQUEST_DIGEST,
            "--query_stride",
            "10",
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
            for option in (
                "--request_digest",
                "--query_stride",
                "--memory_budget_bytes",
                "--log_target",
            ):
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

    def test_cross_group_filtering_precedes_top_k_and_is_deterministic(self) -> None:
        query_name = "000-alpha.jpg"
        query_list = self.root / "cross-group-query.txt"
        query_list.write_text(f"{query_name}\n", encoding="utf-8")
        group_path, group_digest = self._write_group_map([0, 0, 1, 1])
        common = [
            "--query_image_list_path",
            str(query_list),
            *self._cross_group_extra(
                group_path=group_path,
                group_digest=group_digest,
                query_names=[query_name],
                num_images=1,
                returned_neighbor_count=1,
            ),
        ]

        outputs: list[bytes] = []
        for threads in ("1", "-1"):
            for attempt in range(3):
                output = self.root / f"cross-group-{threads}-{attempt}.txt"
                result = self._run(
                    output=output,
                    extra=[*common, "--num_threads", threads],
                )
                self.assertEqual(
                    result.returncode,
                    0,
                    result.stdout + result.stderr,
                )
                header, outcomes, pairs = parse_native_retrieval_receipt(output)
                self.assertEqual(
                    header,
                    [
                        RETRIEVAL_OUTCOMES_V3_MAGIC,
                        RETRIEVAL_ENGINE,
                        "10",
                        "1",
                        "1",
                        "0",
                        RETRIEVAL_GROUP_POLICY,
                        group_digest,
                        "1",
                        cross_group_request_digest(
                            group_digest=group_digest,
                            query_names=[query_name],
                            num_images=1,
                            returned_neighbor_count=1,
                        ),
                    ],
                )
                self.assertEqual(len(outcomes), 1)
                self.assertEqual(outcomes[0][:4], ["Q", "ranked", query_name, "1"])
                self.assertIn(
                    outcomes[0][4],
                    {"002-charlie.jpg", "003-delta.jpg"},
                )
                self.assertEqual(len(pairs), 1)
                outputs.append(output.read_bytes())
        self.assertEqual(outputs[1:], outputs[:-1])

    def test_cross_group_mode_reports_all_excluded_without_fallback(self) -> None:
        query_name = "000-alpha.jpg"
        query_list = self.root / "all-excluded-query.txt"
        query_list.write_text(f"{query_name}\n", encoding="utf-8")
        exclusions = self.root / "all-cross-group-pairs.txt"
        exclusions.write_text(
            "000-alpha.jpg 002-charlie.jpg\n000-alpha.jpg 003-delta.jpg\n",
            encoding="utf-8",
        )
        group_path, group_digest = self._write_group_map([0, 0, 1, 1])
        result = self._run(
            extra=[
                "--query_image_list_path",
                str(query_list),
                "--excluded_pair_list_path",
                str(exclusions),
                *self._cross_group_extra(
                    group_path=group_path,
                    group_digest=group_digest,
                    query_names=[query_name],
                ),
            ]
        )
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        header, outcomes, pairs = parse_native_retrieval_receipt(self.output)
        self.assertEqual(header[0], RETRIEVAL_OUTCOMES_V3_MAGIC)
        self.assertEqual(
            outcomes,
            [["Q", "noRankedNeighbors", query_name, "0"]],
        )
        self.assertEqual(pairs, [])

    def test_large_all_query_cross_group_graph_uses_exact_exclusion_policy(
        self,
    ) -> None:
        image_count = 128
        images = [
            (
                f"{index:04d}.jpg",
                keypoints4(8, scale_offset=float(index % 17)),
                [descriptor((index * 29) % 251, row) for row in range(8)],
            )
            for index in range(image_count)
        ]
        large_database = self.root / "large-features.db"
        create_feature_database(large_database, images)
        groups = [index % 2 for index in range(image_count)]
        group_path, group_digest = self._write_group_map(
            groups,
            images=images,
            name="large-image-groups.txt",
        )
        excluded_path = self.root / "large-excluded-pairs.txt"
        excluded_edges: set[tuple[int, int]] = set()
        for index in range(image_count):
            candidate = index + 5
            if candidate < image_count and groups[index] != groups[candidate]:
                excluded_edges.add((index, candidate))
        excluded_path.write_text(
            "".join(
                f"{images[first][0]} {images[second][0]}\n"
                for first, second in sorted(excluded_edges)
            ),
            encoding="utf-8",
        )
        query_names = [image[0] for image in images]
        result = self._run(
            database=large_database,
            extra=[
                "--excluded_pair_list_path",
                str(excluded_path),
                "--num_visual_words",
                "32",
                "--max_features_per_image",
                "8",
                "--max_training_descriptors",
                "1024",
                *self._cross_group_extra(
                    group_path=group_path,
                    group_digest=group_digest,
                    query_names=query_names,
                    query_stride=1,
                    num_images=8,
                    returned_neighbor_count=4,
                    minimum_frame_separation=5,
                ),
            ],
        )
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        header, outcomes, pairs = parse_native_retrieval_receipt(self.output)
        self.assertEqual(header[0], RETRIEVAL_OUTCOMES_V3_MAGIC)
        self.assertEqual(len(outcomes), image_count)
        index_by_name = {image[0]: index for index, image in enumerate(images)}
        for outcome in outcomes:
            query_index = index_by_name[outcome[2]]
            for candidate_name in outcome[4:]:
                candidate_index = index_by_name[candidate_name]
                self.assertNotEqual(groups[query_index], groups[candidate_index])
                self.assertGreaterEqual(abs(query_index - candidate_index), 5)
                self.assertNotIn(
                    tuple(sorted((query_index, candidate_index))), excluded_edges
                )
        for pair in pairs:
            first_name, second_name = pair.split()
            first = index_by_name[first_name]
            second = index_by_name[second_name]
            self.assertNotEqual(groups[first], groups[second])
            self.assertGreaterEqual(abs(first - second), 5)
            self.assertNotIn(tuple(sorted((first, second))), excluded_edges)

    def test_cross_group_inputs_are_both_required_and_digest_bound(self) -> None:
        group_path, group_digest = self._write_group_map([0, 0, 1, 1])
        for extra in (
            ["--image_group_list_path", str(group_path)],
            ["--image_group_list_digest", group_digest],
        ):
            with self.subTest(extra=extra):
                result = self._run(extra=extra)
                self.assertNotEqual(
                    result.returncode,
                    0,
                    result.stdout + result.stderr,
                )

        query_names = [image[0] for image in ordinary_images()]
        wrong_digest = "0" * 64
        result = self._run(
            extra=self._cross_group_extra(
                group_path=group_path,
                group_digest=wrong_digest,
                query_names=query_names,
            )
        )
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("group list digest", result.stdout + result.stderr)

        result = self._run(
            extra=[
                *self._cross_group_extra(
                    group_path=group_path,
                    group_digest=group_digest,
                    query_names=query_names,
                ),
                "--request_digest",
                "f" * 64,
            ]
        )
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("request digest", result.stdout + result.stderr)

    def test_group_map_requires_exact_canonical_name_order(self) -> None:
        canonical_payload, _ = canonical_image_group_payload(
            ordinary_images(), [0, 0, 1, 1]
        )
        canonical_lines = canonical_payload.decode("utf-8").splitlines()
        cases = {
            "missing": canonical_lines[:-1],
            "duplicate": [
                canonical_lines[0],
                canonical_lines[0],
                canonical_lines[2],
                canonical_lines[3],
            ],
            "reordered": [
                canonical_lines[1],
                canonical_lines[0],
                canonical_lines[2],
                canonical_lines[3],
            ],
            "noncontiguous": [
                "000-alpha.jpg\t0",
                "001-bravo.jpg\t0",
                "002-charlie.jpg\t2",
                "003-delta.jpg\t2",
            ],
            "one-group": [
                "000-alpha.jpg\t0",
                "001-bravo.jpg\t0",
                "002-charlie.jpg\t0",
                "003-delta.jpg\t0",
            ],
            "leading-zero": [
                "000-alpha.jpg\t00",
                "001-bravo.jpg\t0",
                "002-charlie.jpg\t1",
                "003-delta.jpg\t1",
            ],
            "extra": [*canonical_lines, "003-delta.jpg\t1"],
        }
        query_names = [image[0] for image in ordinary_images()]
        for label, lines in cases.items():
            with self.subTest(label=label):
                group_path = self.root / f"invalid-{label}.txt"
                group_path.write_text(
                    "".join(f"{line}\n" for line in lines),
                    encoding="utf-8",
                )
                group_digest = length_prefixed_sha256([RETRIEVAL_GROUP_POLICY, *lines])
                result = self._run(
                    extra=self._cross_group_extra(
                        group_path=group_path,
                        group_digest=group_digest,
                        query_names=query_names,
                    )
                )
                self.assertNotEqual(
                    result.returncode,
                    0,
                    result.stdout + result.stderr,
                )

        unterminated_path = self.root / "unterminated-groups.txt"
        unterminated_path.write_text(
            "\n".join(canonical_lines),
            encoding="utf-8",
        )
        group_digest = length_prefixed_sha256(
            [RETRIEVAL_GROUP_POLICY, *canonical_lines]
        )
        result = self._run(
            extra=self._cross_group_extra(
                group_path=unterminated_path,
                group_digest=group_digest,
                query_names=query_names,
            )
        )
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("end with a newline", result.stdout + result.stderr)

        invalid_utf8_path = self.root / "invalid-utf8-groups.txt"
        invalid_utf8_path.write_bytes(
            b"000-alpha.jpg\t0\n"
            b"001-bravo.jpg\t0\n"
            b"002-charlie.jpg\t1\n"
            b"\xff03-delta.jpg\t1\n"
        )
        result = self._run(
            extra=self._cross_group_extra(
                group_path=invalid_utf8_path,
                group_digest="0" * 64,
                query_names=query_names,
            )
        )
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_group_map_uses_name_order_independent_of_database_ids(self) -> None:
        images = list(reversed(ordinary_images()))
        database = self.root / "reversed-database-order.db"
        create_feature_database(database, images)
        query_name = "000-alpha.jpg"
        query_list = self.root / "reversed-database-query.txt"
        query_list.write_text(f"{query_name}\n", encoding="utf-8")
        group_path, group_digest = self._write_group_map(
            [0, 0, 1, 1],
            images=ordinary_images(),
            name="name-ordered-groups.txt",
        )
        result = self._run(
            database=database,
            extra=[
                "--query_image_list_path",
                str(query_list),
                *self._cross_group_extra(
                    group_path=group_path,
                    group_digest=group_digest,
                    query_names=[query_name],
                ),
            ],
        )
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        header, outcomes, pairs = parse_native_retrieval_receipt(self.output)
        self.assertEqual(header[0], RETRIEVAL_OUTCOMES_V3_MAGIC)
        self.assertEqual(outcomes[0][2], query_name)
        self.assertTrue(outcomes[0][4:])
        self.assertTrue(
            set(outcomes[0][4:]).issubset({"002-charlie.jpg", "003-delta.jpg"})
        )
        self.assertTrue(pairs)

        database_order_lines = [
            f"{image[0]}\t{group}" for image, group in zip(images, [0, 0, 1, 1])
        ]
        database_order_path = self.root / "incorrect-database-id-groups.txt"
        database_order_path.write_text(
            "".join(f"{line}\n" for line in database_order_lines),
            encoding="utf-8",
        )
        database_order_digest = length_prefixed_sha256(
            [RETRIEVAL_GROUP_POLICY, *database_order_lines]
        )
        result = self._run(
            database=database,
            output=self.root / "incorrect-database-id-output.txt",
            extra=[
                "--query_image_list_path",
                str(query_list),
                *self._cross_group_extra(
                    group_path=database_order_path,
                    group_digest=database_order_digest,
                    query_names=[query_name],
                ),
            ],
        )
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("image-name order", result.stdout + result.stderr)

    def test_receipt_binds_request_and_emits_one_canonical_outcome_per_query(
        self,
    ) -> None:
        query_list = self.root / "queries.txt"
        query_list.write_text(
            "002-charlie.jpg\n000-alpha.jpg\n",
            encoding="utf-8",
        )
        result = self._run(
            extra=[
                "--query_image_list_path",
                str(query_list),
                "--query_stride",
                "7",
            ]
        )
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        header, outcomes, pair_lines = parse_native_retrieval_receipt(self.output)
        self.assertEqual(
            header,
            [
                RETRIEVAL_OUTCOMES_MAGIC,
                RETRIEVAL_ENGINE,
                "7",
                "3",
                "2",
                "0",
                "2",
                REQUEST_DIGEST,
            ],
        )
        self.assertEqual(
            [outcome[2] for outcome in outcomes],
            ["002-charlie.jpg", "000-alpha.jpg"],
        )
        for outcome in outcomes:
            self.assertEqual(outcome[0], "Q")
            self.assertEqual(outcome[1], "ranked")
            neighbor_count = int(outcome[3])
            self.assertEqual(neighbor_count, len(outcome[4:]))
            self.assertEqual(outcome[4:], sorted(outcome[4:]))
            self.assertEqual(len(outcome[4:]), len(set(outcome[4:])))
        self.assertEqual(pair_lines, sorted(pair_lines))

    def test_omitting_group_inputs_keeps_exact_v2_receipt(self) -> None:
        query_list = self.root / "v2-query.txt"
        query_list.write_text("000-alpha.jpg\n", encoding="utf-8")
        result = self._run(
            extra=[
                "--query_image_list_path",
                str(query_list),
                "--num_images",
                "1",
                "--returned_neighbor_count",
                "1",
            ]
        )
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(
            self.output.read_bytes(),
            (
                f"{RETRIEVAL_OUTCOMES_MAGIC} {RETRIEVAL_ENGINE} "
                f"10 1 1 0 1 {REQUEST_DIGEST}\n"
                "Q ranked 000-alpha.jpg 1 001-bravo.jpg\n"
                "P 000-alpha.jpg 001-bravo.jpg\n"
            ).encode("utf-8"),
        )

    def test_receipt_explicitly_reports_zero_neighbor_query(self) -> None:
        query_list = self.root / "one-query.txt"
        query_list.write_text("000-alpha.jpg\n", encoding="utf-8")
        result = self._run(
            extra=[
                "--query_image_list_path",
                str(query_list),
                "--minimum_frame_separation",
                "10",
            ]
        )
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        _, outcomes, pair_lines = parse_native_retrieval_receipt(self.output)
        self.assertEqual(
            outcomes,
            [["Q", "noRankedNeighbors", "000-alpha.jpg", "0"]],
        )
        self.assertEqual(pair_lines, [])

    def test_exclusions_are_applied_before_candidate_truncation_repeatably(
        self,
    ) -> None:
        query_list = self.root / "one-query.txt"
        query_list.write_text("000-alpha.jpg\n", encoding="utf-8")
        common = [
            "--query_image_list_path",
            str(query_list),
            "--num_images",
            "1",
            "--returned_neighbor_count",
            "1",
        ]
        baseline = self._run(extra=common)
        self.assertEqual(baseline.returncode, 0, baseline.stdout + baseline.stderr)
        _, baseline_outcomes, _ = parse_native_retrieval_receipt(self.output)
        self.assertEqual(len(baseline_outcomes), 1)
        self.assertEqual(baseline_outcomes[0][0:2], ["Q", "ranked"])
        self.assertEqual(len(baseline_outcomes[0][4:]), 1)
        first_neighbor = baseline_outcomes[0][4]

        excluded = self.root / "excluded-top-result.txt"
        excluded.write_text(
            f"000-alpha.jpg {first_neighbor}\n",
            encoding="utf-8",
        )
        filtered = [*common, "--excluded_pair_list_path", str(excluded)]
        outputs: list[bytes] = []
        for index in range(3):
            output = self.root / f"filtered-{index}.txt"
            result = self._run(output=output, extra=filtered)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            _, outcomes, pair_lines = parse_native_retrieval_receipt(output)
            self.assertEqual(len(outcomes), 1)
            self.assertEqual(outcomes[0][0:2], ["Q", "ranked"])
            self.assertEqual(len(outcomes[0][4:]), 1)
            self.assertNotEqual(outcomes[0][4], first_neighbor)
            self.assertEqual(len(pair_lines), 1)
            outputs.append(output.read_bytes())
        self.assertEqual(outputs[1:], outputs[:-1])

    def test_frame_separation_surfaces_a_later_eligible_candidate(self) -> None:
        query_list = self.root / "one-query.txt"
        query_list.write_text("000-alpha.jpg\n", encoding="utf-8")
        result = self._run(
            extra=[
                "--query_image_list_path",
                str(query_list),
                "--minimum_frame_separation",
                "2",
                "--num_images",
                "1",
                "--returned_neighbor_count",
                "1",
            ]
        )
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        _, outcomes, pair_lines = parse_native_retrieval_receipt(self.output)
        self.assertEqual(len(outcomes), 1)
        self.assertEqual(outcomes[0][0:2], ["Q", "ranked"])
        self.assertEqual(len(outcomes[0][4:]), 1)
        self.assertIn(outcomes[0][4], {"002-charlie.jpg", "003-delta.jpg"})
        self.assertEqual(len(pair_lines), 1)

    def test_receipt_explicitly_reports_excluded_near_neighbor(self) -> None:
        query_list = self.root / "one-query.txt"
        query_list.write_text("000-alpha.jpg\n", encoding="utf-8")
        excluded = self.root / "excluded.txt"
        excluded.write_text(
            "000-alpha.jpg 001-bravo.jpg\n",
            encoding="utf-8",
        )
        result = self._run(
            extra=[
                "--query_image_list_path",
                str(query_list),
                "--excluded_pair_list_path",
                str(excluded),
                "--minimum_frame_separation",
                "10",
            ]
        )
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        _, outcomes, pair_lines = parse_native_retrieval_receipt(self.output)
        self.assertEqual(
            outcomes,
            [["Q", "noRankedNeighbors", "000-alpha.jpg", "0"]],
        )
        self.assertEqual(pair_lines, [])

    def test_candidate_pool_reranking_promotes_geometrically_valid_raw_rank_9_to_20(
        self,
    ) -> None:
        rows = 32
        query_descriptors = [descriptor(61, row) for row in range(rows)]
        query_keypoints = [
            (
                float((row % 8) * 100 + 50),
                float((row // 8) * 100 + 50),
                1.0 + row / 100.0,
                0.0,
            )
            for row in range(rows)
        ]
        images = [("000-query.jpg", query_keypoints, query_descriptors)]
        for index in range(1, 9):
            incoherent_keypoints = [
                (
                    float((row * 137 + index * 179) % 3900),
                    float((row * 311 + index * 227) % 3900),
                    1.0 + ((row * 7 + index) % rows) / 100.0,
                    float(((row * 5 + index) % 16) / 8.0),
                )
                for row in range(rows)
            ]
            images.append(
                (
                    f"{index:03d}-raw-distractor.jpg",
                    incoherent_keypoints,
                    query_descriptors,
                )
            )
        promoted_name = "009-geometric.jpg"
        images.append(
            (
                promoted_name,
                [
                    (x + 23.0, y - 17.0, scale, angle)
                    for x, y, scale, angle in query_keypoints
                ],
                query_descriptors[:24]
                + [descriptor(203, row) for row in range(24, rows)],
            )
        )
        for index in range(10, 22):
            images.append(
                (
                    f"{index:03d}-weak.jpg",
                    keypoints4(rows, scale_offset=float(index)),
                    [descriptor(137 + index, row) for row in range(rows)],
                )
            )

        database = self.root / "reranking.db"
        create_feature_database(database, images)
        query_list = self.root / "reranking-query.txt"
        query_list.write_text("000-query.jpg\n", encoding="utf-8")

        def ranked_neighbors(candidate_count: int, output: Path) -> list[str]:
            result = self._run(
                database=database,
                output=output,
                extra=[
                    "--query_image_list_path",
                    str(query_list),
                    "--num_images",
                    str(candidate_count),
                    "--returned_neighbor_count",
                    "8",
                    "--num_visual_words",
                    "16",
                    "--num_checks",
                    "16",
                ],
            )
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            _, outcomes, _ = parse_native_retrieval_receipt(output)
            self.assertEqual(len(outcomes), 1)
            self.assertEqual(outcomes[0][1], "ranked")
            return outcomes[0][4:]

        small_pool = ranked_neighbors(8, self.root / "candidate-8.txt")
        large_pool = ranked_neighbors(20, self.root / "candidate-20.txt")
        self.assertEqual(len(small_pool), 8)
        self.assertEqual(len(large_pool), 8)
        self.assertNotIn(promoted_name, small_pool)
        self.assertIn(promoted_name, large_pool)
        self.assertNotEqual(set(small_pool), set(large_pool))

    def test_receipt_explicitly_reports_prior_emitted_duplicate_neighbor(
        self,
    ) -> None:
        reciprocal_queries = self.root / "reciprocal-queries.txt"
        reciprocal_queries.write_text(
            "000-alpha.jpg\n001-bravo.jpg\n",
            encoding="utf-8",
        )
        result = self._run(
            extra=[
                "--query_image_list_path",
                str(reciprocal_queries),
                "--num_images",
                "2",
                "--returned_neighbor_count",
                "1",
            ]
        )
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        _, outcomes, pair_lines = parse_native_retrieval_receipt(self.output)
        self.assertEqual(
            outcomes,
            [
                ["Q", "ranked", "000-alpha.jpg", "1", "001-bravo.jpg"],
                ["Q", "ranked", "001-bravo.jpg", "1", "000-alpha.jpg"],
            ],
        )
        self.assertEqual(pair_lines, ["000-alpha.jpg 001-bravo.jpg"])

    def test_invalid_receipt_identity_fails_before_replacing_output(self) -> None:
        invalid_values = (
            ("request_digest", "a" * 63),
            ("request_digest", "A" * 64),
            ("request_digest", "g" * 64),
            ("query_stride", "0"),
            ("query_stride", "1000001"),
        )
        for option, value in invalid_values:
            with self.subTest(option=option, value=value):
                self.output.write_text("preserve me\n", encoding="utf-8")
                result = self._run(extra=[f"--{option}", value])
                self.assertFailurePreservesOutput(result)

    def test_duplicate_query_identity_is_rejected_without_replacing_output(
        self,
    ) -> None:
        query_list = self.root / "duplicate-queries.txt"
        query_list.write_text(
            "000-alpha.jpg\n000-alpha.jpg\n",
            encoding="utf-8",
        )
        self.output.write_text("preserve me\n", encoding="utf-8")
        result = self._run(extra=["--query_image_list_path", str(query_list)])
        self.assertFailurePreservesOutput(result)

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

    def test_matches_importer_exposes_two_view_geometry_seed(self) -> None:
        result = self._invoke_binary(self.native_binary, ["matches_importer", "-h"])
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("--TwoViewGeometry.random_seed", result.stdout + result.stderr)

    def test_numeric_bounds_fail_before_retrieval(self) -> None:
        invalid_values = (
            ("num_images", "0"),
            ("num_images", "257"),
            ("returned_neighbor_count", "0"),
            ("returned_neighbor_count", "65"),
            ("minimum_frame_separation", "-1"),
            ("minimum_frame_separation", "1000001"),
            ("query_stride", "0"),
            ("query_stride", "1000001"),
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

        group_file, group_digest = self._write_group_map([0, 0, 1, 1])
        group_link = self.root / "group-link.txt"
        group_link.symlink_to(group_file)
        result = self._run(
            extra=self._cross_group_extra(
                group_path=group_link,
                group_digest=group_digest,
                query_names=[image[0] for image in ordinary_images()],
            )
        )
        self.assertNotEqual(result.returncode, 0)

    def test_optional_input_hard_links_are_rejected(self) -> None:
        query_file = self.root / "hard-linked-queries.txt"
        query_file.write_text("000-alpha.jpg\n", encoding="utf-8")
        query_alias = self.root / "queries-alias.txt"
        os.link(query_file, query_alias)

        excluded_file = self.root / "hard-linked-exclusions.txt"
        excluded_file.write_text(
            "000-alpha.jpg 001-bravo.jpg\n",
            encoding="utf-8",
        )
        excluded_alias = self.root / "exclusions-alias.txt"
        os.link(excluded_file, excluded_alias)

        group_file, group_digest = self._write_group_map(
            [0, 0, 1, 1],
            name="hard-linked-groups.txt",
        )
        group_alias = self.root / "groups-alias.txt"
        os.link(group_file, group_alias)

        cases = (
            ["--query_image_list_path", str(query_file)],
            ["--excluded_pair_list_path", str(excluded_file)],
            self._cross_group_extra(
                group_path=group_file,
                group_digest=group_digest,
                query_names=[image[0] for image in ordinary_images()],
            ),
        )
        for extra in cases:
            with self.subTest(extra=extra):
                result = self._run(extra=extra)
                self.assertNotEqual(
                    result.returncode,
                    0,
                    result.stdout + result.stderr,
                )
                self.assertIn("exactly one hard link", result.stdout + result.stderr)

    def test_optional_inputs_cannot_change_before_publication(self) -> None:
        shim = self.fault_shims.get("optional_input_change")
        if shim is None:
            self.skipTest("could not build optional-input-change fault shim")

        all_query_names = [image[0] for image in ordinary_images()]
        for phase in ("prepare", "publish"):
            for mode in ("swap", "mutate"):
                for label in ("query", "excluded", "groups"):
                    with self.subTest(phase=phase, mode=mode, label=label):
                        stem = f"{phase}-{mode}"
                        if label == "query":
                            input_path = self.root / f"{stem}-queries.txt"
                            input_path.write_text("000-alpha.jpg\n", encoding="utf-8")
                            replacement = self.root / f"{stem}-queries-replacement.txt"
                            replacement.write_text(
                                "002-charlie.jpg\n", encoding="utf-8"
                            )
                            extra = ["--query_image_list_path", str(input_path)]
                        elif label == "excluded":
                            input_path = self.root / f"{stem}-exclusions.txt"
                            input_path.write_text(
                                "000-alpha.jpg 001-bravo.jpg\n",
                                encoding="utf-8",
                            )
                            replacement = (
                                self.root / f"{stem}-exclusions-replacement.txt"
                            )
                            replacement.write_text(
                                "000-alpha.jpg 002-charlie.jpg\n",
                                encoding="utf-8",
                            )
                            extra = ["--excluded_pair_list_path", str(input_path)]
                        else:
                            input_path, group_digest = self._write_group_map(
                                [0, 0, 1, 1],
                                name=f"{stem}-groups.txt",
                            )
                            replacement_payload, _ = canonical_image_group_payload(
                                ordinary_images(), [0, 1, 0, 1]
                            )
                            replacement = self.root / f"{stem}-groups-replacement.txt"
                            replacement.write_bytes(replacement_payload)
                            extra = self._cross_group_extra(
                                group_path=input_path,
                                group_digest=group_digest,
                                query_names=all_query_names,
                            )

                        moved = self.root / f"{stem}-{label}-moved.txt"
                        initial_size = input_path.stat().st_size
                        initial_digest = sha256(input_path)
                        self.output.write_bytes(b"preserve me\n")
                        environment = {
                            "DYLD_INSERT_LIBRARIES": str(shim),
                            "EASYSPLAT_TEST_INPUT_CHANGE_PHASE": phase,
                            "EASYSPLAT_TEST_INPUT_CHANGE_MODE": mode,
                            "EASYSPLAT_TEST_INPUT_PATH": str(input_path),
                            "EASYSPLAT_TEST_INPUT_MOVED": str(moved),
                            "EASYSPLAT_TEST_INPUT_REPLACEMENT": str(replacement),
                        }
                        result = self._run(extra=extra, environment=environment)

                        self.assertFailurePreservesOutput(result)
                        self.assertIn("changed", result.stdout + result.stderr)
                        if mode == "swap":
                            self.assertTrue(input_path.is_symlink())
                            self.assertEqual(sha256(moved), initial_digest)
                        else:
                            self.assertEqual(input_path.stat().st_size, initial_size)
                            self.assertNotEqual(sha256(input_path), initial_digest)

    def test_database_with_multiple_hard_links_is_rejected(self) -> None:
        linked_database = self.root / "hard-linked-features.db"
        os.link(self.database, linked_database)
        self.output.write_bytes(b"preserve me\n")

        result = self._run(database=linked_database)

        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("exactly one hard link", result.stdout + result.stderr)
        self.assertEqual(self.output.read_bytes(), b"preserve me\n")

    def test_database_path_replacement_after_sqlite_open_is_rejected(self) -> None:
        shim = self.fault_shims.get("database_swap")
        if shim is None:
            self.skipTest("could not build database-swap fault shim")
        moved_database = self.root / "opened-features.db"
        replacement_database = self.root / "replacement-features.db"
        create_feature_database(replacement_database, ordinary_images())
        database_before = sha256(self.database)
        replacement_before = sha256(replacement_database)
        self.output.write_bytes(b"preserve me\n")

        result = self._run(
            environment={
                "DYLD_INSERT_LIBRARIES": str(shim),
                "EASYSPLAT_TEST_DATABASE_PATH": str(self.database),
                "EASYSPLAT_TEST_DATABASE_MOVED": str(moved_database),
                "EASYSPLAT_TEST_DATABASE_REPLACEMENT": str(replacement_database),
            },
        )

        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("database path changed", result.stdout + result.stderr)
        self.assertTrue(self.database.is_symlink())
        self.assertEqual(sha256(moved_database), database_before)
        self.assertEqual(sha256(replacement_database), replacement_before)
        self.assertEqual(self.output.read_bytes(), b"preserve me\n")

    def test_output_ancestor_symlink_is_rejected_without_replacing_target(self) -> None:
        actual = self.root / "actual-output-root"
        parent = actual / "nested"
        parent.mkdir(parents=True)
        target = parent / "pairs.txt"
        target.write_bytes(b"preserve me\n")
        alias = self.root / "output-root-link"
        alias.symlink_to(actual, target_is_directory=True)

        result = self._run(output=alias / "nested" / "pairs.txt")

        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(target.read_bytes(), b"preserve me\n")
        self.assertEqual(list(parent.glob(".easysplat-vocab-*.tmp")), [])

    def test_output_parent_swaps_fail_closed_and_clean_bound_temporaries(self) -> None:
        shim = self.fault_shims.get("parent_swap")
        if shim is None:
            self.skipTest("could not build parent-swap fault shim")

        for phase in (
            "after_validation",
            "after_temp",
            "after_write",
            "after_rename",
        ):
            with self.subTest(phase=phase):
                parent = self.root / f"bound-{phase}"
                moved = self.root / f"moved-{phase}"
                replacement = self.root / f"replacement-{phase}"
                parent.mkdir()
                replacement.mkdir()
                output = parent / "pairs.txt"
                replacement_output = replacement / "pairs.txt"
                output.write_bytes(b"preserve bound output\n")
                replacement_output.write_bytes(b"preserve replacement output\n")

                result = self._run(
                    output=output,
                    environment={
                        "DYLD_INSERT_LIBRARIES": str(shim),
                        "EASYSPLAT_TEST_SWAP_PHASE": phase,
                        "EASYSPLAT_TEST_SWAP_PARENT": str(parent),
                        "EASYSPLAT_TEST_SWAP_MOVED": str(moved),
                        "EASYSPLAT_TEST_SWAP_TARGET": str(replacement),
                    },
                )

                self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertTrue(parent.is_symlink())
                self.assertEqual(
                    (moved / "pairs.txt").read_bytes(), b"preserve bound output\n"
                )
                self.assertEqual(
                    replacement_output.read_bytes(), b"preserve replacement output\n"
                )
                self.assertEqual(list(moved.glob(".easysplat-vocab-*.tmp")), [])
                self.assertEqual(list(moved.glob(".pairs.txt.*")), [])
                self.assertEqual(list(replacement.glob(".easysplat-vocab-*.tmp")), [])
                self.assertEqual(list(replacement.glob(".pairs.txt.*")), [])

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

        group_file, group_digest = self._write_group_map(
            [0, 0, 1, 1],
            name="aliased-groups.txt",
        )
        group_contents = group_file.read_bytes()
        group_result = self._run(
            output=group_file,
            extra=self._cross_group_extra(
                group_path=group_file,
                group_digest=group_digest,
                query_names=[image[0] for image in ordinary_images()],
            ),
        )
        self.assertNotEqual(
            group_result.returncode,
            0,
            group_result.stdout + group_result.stderr,
        )
        self.assertEqual(group_file.read_bytes(), group_contents)

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

        oversized_groups = self.root / "oversized-groups.txt"
        oversized_groups.write_bytes(b"000-alpha.jpg\t0\n" * 100_000)
        self.output.write_text("preserve me\n", encoding="utf-8")
        result = self._run(
            extra=[
                "--image_group_list_path",
                str(oversized_groups),
                "--image_group_list_digest",
                "0" * 64,
            ]
        )
        self.assertFailurePreservesOutput(result)
        self.assertIn("supported size bound", result.stdout + result.stderr)

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
        self.assertEqual(native_pair_bytes(native_output), expected)
        if self.oracle_binary is not None:
            oracle_output = self.root / "oracle.txt"
            oracle = self._run(
                database=mixed_database,
                output=oracle_output,
                binary=self.oracle_binary,
            )
            self.assertEqual(oracle.returncode, 0, oracle.stdout + oracle.stderr)
            self.assertEqual(oracle_output.read_bytes(), expected)

    def test_top_scale_selection_and_even_training_sampling_remain_deterministic(
        self,
    ) -> None:
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
        expected = FROZEN_ORACLE_OUTPUTS["sampled_features"]
        for thread_count in ("1", "-1"):
            for attempt in range(5):
                native_output = self.root / (
                    f"native-sampled-{thread_count}-{attempt}.txt"
                )
                native = self._run(
                    database=sampled_database,
                    output=native_output,
                    extra=[*options, "--num_threads", thread_count],
                )
                self.assertEqual(native.returncode, 0, native.stdout + native.stderr)
                self.assertEqual(native_pair_bytes(native_output), expected)
        if self.oracle_binary is not None:
            oracle_output = self.root / "oracle-sampled.txt"
            oracle = self._run(
                database=sampled_database,
                output=oracle_output,
                extra=options,
                binary=self.oracle_binary,
            )
            self.assertEqual(oracle.returncode, 0, oracle.stdout + oracle.stderr)
            self.assertEqual(
                oracle_output.read_bytes(),
                FROZEN_ORACLE_OUTPUTS["sampled_features"],
            )

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
        self.assertEqual(native_pair_bytes(native_output), expected)
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
            "# deliberate order\n002-charlie.jpg\n000-alpha.jpg\n",
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
        _, outcomes, lines = parse_native_retrieval_receipt(self.output)
        self.assertEqual(
            [outcome[2] for outcome in outcomes],
            ["002-charlie.jpg", "000-alpha.jpg"],
        )
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
        query_list = self.root / "tie-query.txt"
        query_list.write_text("000-query.jpg\n", encoding="utf-8")
        for database_name, insertion_order in (
            ("ascending-ties.db", images),
            ("reversed-ties.db", list(reversed(images))),
        ):
            tied_database = self.root / database_name
            create_feature_database(tied_database, insertion_order)
            for threads in ("1", "-1"):
                for attempt in range(3):
                    output = self.root / f"{database_name}-{threads}-{attempt}.txt"
                    result = self._run(
                        database=tied_database,
                        output=output,
                        extra=[
                            "--query_image_list_path",
                            str(query_list),
                            "--num_images",
                            "1",
                            "--returned_neighbor_count",
                            "1",
                            "--num_threads",
                            threads,
                        ],
                    )
                    self.assertEqual(
                        result.returncode, 0, result.stdout + result.stderr
                    )
                    _, outcomes, pair_lines = parse_native_retrieval_receipt(output)
                    self.assertEqual(
                        pair_lines,
                        ["000-query.jpg 001-bravo.jpg"],
                    )
                    self.assertEqual(
                        outcomes,
                        [["Q", "ranked", "000-query.jpg", "1", "001-bravo.jpg"]],
                    )

    def test_database_image_id_assignment_does_not_change_ranked_names(self) -> None:
        rows = 64
        shared = [descriptor(31, row) for row in range(rows)]
        images = [
            (
                "000-query.jpg",
                keypoints4(rows),
                [descriptor(30, row) for row in range(rows)],
            ),
            *[
                (f"{index:03d}-candidate.jpg", keypoints4(rows), shared)
                for index in range(1, 11)
            ],
        ]
        query_list = self.root / "stable-id-query.txt"
        query_list.write_text("000-query.jpg\n", encoding="utf-8")
        databases = (self.root / "ascending-ids.db", self.root / "reversed-ids.db")
        outputs = (self.root / "ascending-ids.txt", self.root / "reversed-ids.txt")
        create_feature_database(databases[0], images)
        create_feature_database(databases[1], list(reversed(images)))

        for database, output in zip(databases, outputs):
            result = self._run(
                database=database,
                output=output,
                extra=[
                    "--query_image_list_path",
                    str(query_list),
                    "--num_images",
                    "2",
                    "--returned_neighbor_count",
                    "2",
                    "--num_visual_words",
                    "8",
                    "--max_features_per_image",
                    "64",
                    "--num_iterations",
                    "10",
                    "--num_checks",
                    "8",
                    "--num_threads",
                    "8",
                ],
            )
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

        self.assertEqual(outputs[0].read_bytes(), outputs[1].read_bytes())

    def test_parallel_feature_extraction_assigns_lexical_image_ids(self) -> None:
        images = self.root / "parallel-images"
        images.mkdir()
        write_test_grayscale_png(images / "000-slow.png", 2048, 2048, 0)
        for index in range(1, 9):
            write_test_grayscale_png(
                images / f"{index:03d}-fast.png",
                2048,
                2048,
                index,
                simple=True,
            )

        database = self.root / "parallel-features.db"
        result = self._invoke_binary(
            self.native_binary,
            [
                "feature_extractor",
                "--database_path",
                str(database),
                "--image_path",
                str(images),
                "--ImageReader.camera_model",
                "SIMPLE_PINHOLE",
                "--ImageReader.single_camera",
                "1",
                "--FeatureExtraction.num_threads",
                "8",
                "--FeatureExtraction.use_gpu",
                "0",
                "--FeatureExtraction.max_image_size",
                "2048",
                "--SiftExtraction.max_num_features",
                "512",
                "--log_target",
                "stderr",
            ],
        )
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        with open_sqlite(database) as connection:
            assigned = connection.execute(
                "SELECT image_id, name FROM images ORDER BY image_id"
            ).fetchall()
            frames = connection.execute(
                "SELECT frame_id, data_id FROM frame_data ORDER BY frame_id"
            ).fetchall()
        expected_names = sorted(path.name for path in images.iterdir())
        self.assertEqual(
            assigned,
            [(index, name) for index, name in enumerate(expected_names, start=1)],
        )
        self.assertEqual(frames, [(index, index) for index in range(1, 10)])

    def test_cleared_nonempty_database_keeps_autoincrement_identity(self) -> None:
        images = self.root / "reused-database-images"
        images.mkdir()
        old_image = images / "000-old.png"
        write_test_grayscale_png(old_image, 256, 256, 1, simple=True)
        database = self.root / "reused-features.db"
        arguments = [
            "feature_extractor",
            "--database_path",
            str(database),
            "--image_path",
            str(images),
            "--ImageReader.camera_model",
            "SIMPLE_PINHOLE",
            "--ImageReader.single_camera",
            "1",
            "--FeatureExtraction.num_threads",
            "2",
            "--FeatureExtraction.use_gpu",
            "0",
            "--FeatureExtraction.max_image_size",
            "256",
            "--SiftExtraction.max_num_features",
            "128",
            "--log_target",
            "stderr",
        ]
        first = self._invoke_binary(self.native_binary, arguments)
        self.assertEqual(first.returncode, 0, first.stdout + first.stderr)
        with open_sqlite(database) as connection:
            self.assertEqual(
                connection.execute("SELECT image_id FROM images").fetchall(),
                [(1,)],
            )
            connection.executescript(
                """
                DELETE FROM frame_data;
                DELETE FROM frames;
                DELETE FROM pose_priors;
                DELETE FROM keypoints;
                DELETE FROM descriptors;
                DELETE FROM images;
                """
            )
        old_image.unlink()
        write_test_grayscale_png(images / "000-new.png", 256, 256, 2, simple=True)

        second = self._invoke_binary(self.native_binary, arguments)
        self.assertEqual(second.returncode, 0, second.stdout + second.stderr)
        with open_sqlite(database) as connection:
            self.assertEqual(
                connection.execute("SELECT image_id, name FROM images").fetchall(),
                [(2, "000-new.png")],
            )
            self.assertEqual(
                connection.execute(
                    "SELECT frame_id, data_id FROM frame_data"
                ).fetchall(),
                [(2, 2)],
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

    def test_wal_commit_during_publication_fails_without_replacing_output(
        self,
    ) -> None:
        shim = self.fault_shims.get("wal_commit")
        if shim is None:
            self.skipTest("could not build WAL commit fault shim")
        with open_sqlite(self.database) as connection:
            self.assertEqual(
                connection.execute("PRAGMA journal_mode=WAL").fetchone()[0], "wal"
            )
            connection.execute("PRAGMA wal_checkpoint(TRUNCATE)")
        self.output.write_bytes(b"preserve me\n")
        result = self._run(
            environment={
                "DYLD_INSERT_LIBRARIES": str(shim),
                "EASYSPLAT_TEST_DATABASE_PATH": str(self.database),
            }
        )
        self.assertFailurePreservesOutput(result)
        self.assertRegex(
            result.stdout + result.stderr,
            r"(?:SQLite sidecar changed|database path changed)",
        )

    def test_checkpointed_wal_database_opens_through_bound_descriptor(self) -> None:
        connection = sqlite3.connect(self.database)
        try:
            self.assertEqual(
                connection.execute("PRAGMA journal_mode=WAL").fetchone()[0],
                "wal",
            )
        finally:
            connection.close()
        self.assertFalse(Path(f"{self.database}-wal").exists())
        self.assertFalse(Path(f"{self.database}-shm").exists())

        result = self._run()

        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        _, outcomes, _ = parse_native_retrieval_receipt(self.output)
        self.assertEqual(len(outcomes), len(ordinary_images()))

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
        self.assertEqual(native_pair_bytes(native_output), expected)
        if self.oracle_binary is not None:
            oracle_output = self.root / "python-oracle.txt"
            oracle = self._run(
                output=oracle_output,
                extra=options,
                binary=self.oracle_binary,
            )
            self.assertEqual(oracle.returncode, 0, oracle.stdout + oracle.stderr)
            self.assertEqual(oracle_output.read_bytes(), expected)


class NativeMatchesImporterTests(unittest.TestCase):
    native_binary: Path
    runtime_library_path: str | None
    fixture_root: Path
    fixture_database: Path
    boundary_shim_root: Path | None = None
    boundary_shim: Path | None = None
    read_error_shim_root: Path | None = None
    read_error_shim: Path | None = None

    @classmethod
    def setUpClass(cls) -> None:
        native = os.environ.get("EASYSPLAT_NATIVE_COLMAP_BIN")
        if not native:
            raise unittest.SkipTest("set EASYSPLAT_NATIVE_COLMAP_BIN for native tests")
        cls.native_binary = Path(native).resolve()
        if not cls.native_binary.is_file():
            raise AssertionError(f"native COLMAP is missing: {cls.native_binary}")
        cls.runtime_library_path = os.environ.get(
            "EASYSPLAT_NATIVE_COLMAP_DYLD_LIBRARY_PATH"
        )
        cls.fixture_root = Path(
            tempfile.mkdtemp(prefix="easysplat-matches-importer-fixture.")
        ).resolve()
        images = cls.fixture_root / "images"
        images.mkdir()
        write_test_grayscale_png(images / "000.png", 160, 120, 0)
        write_test_grayscale_png(images / "001.png", 160, 120, 0)
        cls.fixture_database = cls.fixture_root / "features.db"
        result = cls._invoke(
            [
                "feature_extractor",
                "--database_path",
                str(cls.fixture_database),
                "--image_path",
                str(images),
                "--ImageReader.single_camera",
                "1",
                "--ImageReader.camera_model",
                "SIMPLE_PINHOLE",
                "--FeatureExtraction.use_gpu",
                "0",
                "--FeatureExtraction.num_threads",
                "1",
                "--SiftExtraction.max_num_features",
                "512",
                "--log_target",
                "stderr",
            ]
        )
        if result.returncode != 0:
            shutil.rmtree(cls.fixture_root, ignore_errors=True)
            raise AssertionError(
                "could not create native matches_importer fixture:\n"
                + result.stdout
                + result.stderr
            )
        cls.boundary_shim = cls._build_boundary_shim()
        cls.read_error_shim = cls._build_read_error_shim()

    @classmethod
    def _build_boundary_shim(cls) -> Path | None:
        compiler = os.environ.get("EASYSPLAT_TEST_CLANG") or shutil.which("clang")
        if compiler is None:
            return None
        sdk = os.environ.get("EASYSPLAT_TEST_SDK")
        root = Path(tempfile.mkdtemp(prefix="easysplat-importer-boundaries."))
        cls.boundary_shim_root = root
        source = root / "boundary_swap.c"
        library = root / "boundary_swap.dylib"
        source.write_text(
            "#include <errno.h>\n"
            "#include <fcntl.h>\n"
            "#include <limits.h>\n"
            "#include <sqlite3.h>\n"
            "#include <stdio.h>\n"
            "#include <stdlib.h>\n"
            "#include <string.h>\n"
            "#include <sys/stat.h>\n"
            "#include <unistd.h>\n"
            "#define DYLD_INTERPOSE(replacement, replacee) "
            "__attribute__((used)) static struct { const void *replacement; "
            "const void *replacee; } _interpose_##replacee "
            '__attribute__((section("__DATA,__interpose"))) = '
            "{ (const void *)(unsigned long)&replacement, "
            "(const void *)(unsigned long)&replacee };\n"
            "static volatile int did_swap = 0;\n"
            "static volatile int database_opened = 0;\n"
            "static volatile int post_open_path_checks = 0;\n"
            "static const char *phase(void) {\n"
            '  return getenv("EASYSPLAT_TEST_IMPORTER_SWAP_PHASE");\n'
            "}\n"
            "static void move_sidecar(const char *path, const char *moved, "
            "const char *suffix) {\n"
            "  char source[PATH_MAX]; char destination[PATH_MAX];\n"
            '  if (snprintf(source, sizeof(source), "%s%s", path, suffix) < 0 ||\n'
            '      snprintf(destination, sizeof(destination), "%s%s", '
            "moved, suffix) < 0) _exit(215);\n"
            "  if (rename(source, destination) != 0 && errno != ENOENT) "
            "_exit(216);\n"
            "}\n"
            "static void swap_database_path(void) {\n"
            "  if (!__sync_bool_compare_and_swap(&did_swap, 0, 1)) return;\n"
            '  const char *path = getenv("EASYSPLAT_TEST_IMPORTER_PATH");\n'
            '  const char *moved = getenv("EASYSPLAT_TEST_IMPORTER_MOVED");\n'
            "  const char *replacement = "
            'getenv("EASYSPLAT_TEST_IMPORTER_REPLACEMENT");\n'
            "  if (path == 0 || moved == 0 || replacement == 0 ||\n"
            "      rename(path, moved) != 0) _exit(214);\n"
            '  move_sidecar(path, moved, "-wal");\n'
            '  move_sidecar(path, moved, "-shm");\n'
            "  if (symlink(replacement, path) != 0) _exit(217);\n"
            "}\n"
            "static int open_replacement_then_restore(const char *path, "
            "sqlite3 **database) {\n"
            '  const char *target = getenv("EASYSPLAT_TEST_IMPORTER_PATH");\n'
            '  const char *moved = getenv("EASYSPLAT_TEST_IMPORTER_MOVED");\n'
            "  const char *replacement = "
            'getenv("EASYSPLAT_TEST_IMPORTER_REPLACEMENT");\n'
            "  if (target == 0 || moved == 0 || replacement == 0 ||\n"
            "      strcmp(path, target) != 0 || rename(target, moved) != 0 ||\n"
            "      rename(replacement, target) != 0) _exit(218);\n"
            "  int result = sqlite3_open(path, database);\n"
            "  if (rename(target, replacement) != 0 || "
            "rename(moved, target) != 0) _exit(219);\n"
            "  return result;\n"
            "}\n"
            "static int boundary_sqlite3_open_v2(const char *path, "
            "sqlite3 **database, int flags, const char *vfs) {\n"
            "  (void)flags; (void)vfs;\n"
            "  const char *selected = phase();\n"
            "  if (selected != 0 && "
            'strcmp(selected, "during_open_restore") == 0)\n'
            "    return open_replacement_then_restore(path, database);\n"
            '  if (selected != 0 && strcmp(selected, "before_open") == 0) '
            "swap_database_path();\n"
            "  return sqlite3_open(path, database);\n"
            "}\n"
            "static int boundary_sqlite3_exec(sqlite3 *database, "
            "const char *sql, int (*callback)(void *, int, char **, char **), "
            "void *context, char **error) {\n"
            "  if (callback != 0 || sql == 0) return SQLITE_MISUSE;\n"
            "  if (error != 0) *error = 0;\n"
            "  const char *cursor = sql;\n"
            "  int result = SQLITE_OK;\n"
            "  while (*cursor != '\\0') {\n"
            "    sqlite3_stmt *statement = 0;\n"
            "    const char *tail = 0;\n"
            "    result = sqlite3_prepare_v2(database, cursor, -1, "
            "&statement, &tail);\n"
            "    if (result != SQLITE_OK) return result;\n"
            "    cursor = tail;\n"
            "    if (statement == 0) continue;\n"
            "    while ((result = sqlite3_step(statement)) == SQLITE_ROW) {}\n"
            "    int finalize_result = sqlite3_finalize(statement);\n"
            "    if (result != SQLITE_DONE) return result;\n"
            "    if (finalize_result != SQLITE_OK) return finalize_result;\n"
            "  }\n"
            "  result = SQLITE_OK;\n"
            "  if (result != SQLITE_OK || sql == 0) return result;\n"
            "  const char *selected = phase();\n"
            '  if (strcmp(sql, "PRAGMA auto_vacuum=1") == 0) {\n'
            "    database_opened = 1;\n"
            '    if (selected != 0 && strcmp(selected, "after_open") == 0) '
            "swap_database_path();\n"
            '  } else if (strcmp(sql, "END TRANSACTION") == 0 &&\n'
            "             selected != 0 && "
            'strcmp(selected, "after_commit") == 0) {\n'
            "    swap_database_path();\n"
            "  }\n"
            "  return result;\n"
            "}\n"
            "static int boundary_lstat(const char *path, struct stat *status) {\n"
            '  const char *target = getenv("EASYSPLAT_TEST_IMPORTER_PATH");\n'
            "  const char *selected = phase();\n"
            "  if (database_opened && target != 0 && path != 0 &&\n"
            "      strcmp(path, target) == 0 && selected != 0 &&\n"
            '      strcmp(selected, "before_precommit") == 0 &&\n'
            "      __sync_add_and_fetch(&post_open_path_checks, 1) == 2) {\n"
            "    swap_database_path();\n"
            "  }\n"
            "  return fstatat(AT_FDCWD, path, status, AT_SYMLINK_NOFOLLOW);\n"
            "}\n"
            "DYLD_INTERPOSE(boundary_sqlite3_open_v2, sqlite3_open_v2)\n"
            "DYLD_INTERPOSE(boundary_sqlite3_exec, sqlite3_exec)\n"
            "DYLD_INTERPOSE(boundary_lstat, lstat)\n",
            encoding="utf-8",
        )
        arguments = [compiler, "-dynamiclib"]
        if sdk:
            arguments.extend(("-isysroot", sdk))
        arguments.extend((str(source), "-lsqlite3", "-o", str(library)))
        result = subprocess.run(
            arguments,
            check=False,
            capture_output=True,
            text=True,
        )
        if result.returncode == 0:
            return library
        shutil.rmtree(root, ignore_errors=True)
        cls.boundary_shim_root = None
        if os.environ.get("EASYSPLAT_TEST_CLANG"):
            raise RuntimeError(
                "could not build required importer boundary shim: "
                + (result.stderr.strip() or result.stdout.strip())
            )
        return None

    @classmethod
    def _build_read_error_shim(cls) -> Path | None:
        compiler = os.environ.get("EASYSPLAT_TEST_CLANG") or shutil.which("clang")
        if compiler is None:
            return None
        sdk = os.environ.get("EASYSPLAT_TEST_SDK")
        root = Path(tempfile.mkdtemp(prefix="easysplat-importer-read-error."))
        cls.read_error_shim_root = root
        source = root / "read_error.c"
        library = root / "read_error.dylib"
        source.write_text(
            "#include <errno.h>\n"
            "#include <fcntl.h>\n"
            "#include <limits.h>\n"
            "#include <stdlib.h>\n"
            "#include <string.h>\n"
            "#include <sys/syscall.h>\n"
            "#include <unistd.h>\n"
            "#define DYLD_INTERPOSE(replacement, replacee) "
            "__attribute__((used)) static struct { const void *replacement; "
            "const void *replacee; } _interpose_##replacee "
            '__attribute__((section("__DATA,__interpose"))) = '
            "{ (const void *)(unsigned long)&replacement, "
            "(const void *)(unsigned long)&replacee };\n"
            "static volatile int target_reads = 0;\n"
            "static ssize_t controlled_read(int descriptor, void *buffer, "
            "size_t count) {\n"
            '  const char *target = getenv("EASYSPLAT_TEST_MATCH_LIST_PATH");\n'
            "  char path[PATH_MAX];\n"
            "  if (target != 0 && fcntl(descriptor, F_GETPATH, path) == 0 &&\n"
            "      strcmp(path, target) == 0) {\n"
            "    if (__sync_add_and_fetch(&target_reads, 1) > 1) {\n"
            "      errno = EIO; return -1;\n"
            "    }\n"
            "    if (count > 128) count = 128;\n"
            "  }\n"
            "  return (ssize_t)syscall(SYS_read, descriptor, buffer, count);\n"
            "}\n"
            "DYLD_INTERPOSE(controlled_read, read)\n",
            encoding="utf-8",
        )
        arguments = [compiler, "-dynamiclib"]
        if sdk:
            arguments.extend(("-isysroot", sdk))
        arguments.extend((str(source), "-o", str(library)))
        result = subprocess.run(
            arguments,
            check=False,
            capture_output=True,
            text=True,
        )
        if result.returncode == 0:
            return library
        shutil.rmtree(root, ignore_errors=True)
        cls.read_error_shim_root = None
        if os.environ.get("EASYSPLAT_TEST_CLANG"):
            raise RuntimeError(
                "could not build required importer read-error shim: "
                + (result.stderr.strip() or result.stdout.strip())
            )
        return None

    @classmethod
    def tearDownClass(cls) -> None:
        if hasattr(cls, "fixture_root"):
            shutil.rmtree(cls.fixture_root, ignore_errors=True)
        if cls.boundary_shim_root is not None:
            shutil.rmtree(cls.boundary_shim_root, ignore_errors=True)
            cls.boundary_shim_root = None
            cls.boundary_shim = None
        if cls.read_error_shim_root is not None:
            shutil.rmtree(cls.read_error_shim_root, ignore_errors=True)
            cls.read_error_shim_root = None
            cls.read_error_shim = None

    @classmethod
    def _environment(cls) -> dict[str, str]:
        environment = os.environ.copy()
        if cls.runtime_library_path:
            environment["DYLD_LIBRARY_PATH"] = cls.runtime_library_path
        return environment

    @classmethod
    def _invoke(cls, arguments: list[str]) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            [str(cls.native_binary), *arguments],
            check=False,
            capture_output=True,
            text=True,
            env=cls._environment(),
            timeout=60,
        )

    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory(
            prefix="easysplat-matches-importer-test."
        )
        self.root = Path(self.temporary.name).resolve()
        self.database = self.root / "features.db"
        shutil.copyfile(self.fixture_database, self.database)
        self.pairs = self.root / "pairs.txt"
        self.pairs.write_text("000.png 001.png\n", encoding="utf-8")

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def _arguments(
        self,
        *,
        database: Path | None = None,
        match_list: Path | None = None,
        match_type: str = "pairs",
        require_empty: str | None = "1",
    ) -> list[str]:
        arguments = [
            "matches_importer",
            "--database_path",
            str(database or self.database),
            "--match_list_path",
            str(match_list or self.pairs),
            "--match_type",
            match_type,
        ]
        if require_empty is not None:
            arguments.extend(
                ("--EasySplat.require_empty_matching_results", require_empty)
            )
        arguments.extend(
            (
                "--TwoViewGeometry.random_seed",
                "42",
                "--FeatureMatching.use_gpu",
                "0",
                "--FeatureMatching.num_threads",
                "1",
                "--FeatureMatching.max_num_matches",
                "512",
                "--SiftMatching.cpu_brute_force_matcher",
                "1",
                "--log_target",
                "stderr",
            )
        )
        return arguments

    def _run(
        self,
        *,
        database: Path | None = None,
        match_list: Path | None = None,
        match_type: str = "pairs",
        require_empty: str | None = "1",
    ) -> subprocess.CompletedProcess[str]:
        return self._invoke(
            self._arguments(
                database=database,
                match_list=match_list,
                match_type=match_type,
                require_empty=require_empty,
            )
        )

    @staticmethod
    def _snapshot(database: Path) -> tuple[list[tuple[object, ...]], ...]:
        with open_sqlite(database) as connection:
            return tuple(
                connection.execute(f"SELECT * FROM {table} ORDER BY pair_id").fetchall()
                for table in ("matches", "two_view_geometries")
            )

    @staticmethod
    def _pair_id(database: Path) -> int:
        with open_sqlite(database) as connection:
            image_ids = [
                row[0]
                for row in connection.execute(
                    "SELECT image_id FROM images ORDER BY name"
                ).fetchall()
            ]
        if len(image_ids) != 2:
            raise AssertionError(f"unexpected image ids: {image_ids!r}")
        return min(image_ids) * 2_147_483_647 + max(image_ids)

    @classmethod
    def _insert_zero_length_result(cls, database: Path, table: str) -> None:
        pair_id = cls._pair_id(database)
        with open_sqlite(database) as connection:
            if table == "matches":
                connection.execute(
                    "INSERT INTO matches(pair_id, rows, cols, data) "
                    "VALUES (?, 0, 2, NULL)",
                    (pair_id,),
                )
            elif table == "two_view_geometries":
                connection.execute(
                    "INSERT INTO two_view_geometries"
                    "(pair_id, rows, cols, data, config) "
                    "VALUES (?, 0, 2, NULL, 0)",
                    (pair_id,),
                )
            else:
                raise AssertionError(f"unsupported result table: {table}")
            connection.commit()

    def _write_imported_matches(self) -> Path:
        imported = self.root / "imported-matches.txt"
        imported.write_text(
            "000.png 001.png\n"
            + "".join(f"{index} {index}\n" for index in range(24))
            + "\n",
            encoding="utf-8",
        )
        return imported

    def _write_partially_valid_import(self) -> Path:
        imported = self.root / "partially-valid-matches.txt"
        imported.write_text(
            "000.png 001.png\n"
            + "".join(f"{index} {index}\n" for index in range(24))
            + "\nmissing.png 000.png\n0 0\n\n",
            encoding="utf-8",
        )
        return imported

    def test_help_exposes_required_empty_result_option(self) -> None:
        result = self._invoke(["matches_importer", "-h"])
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn(
            "--EasySplat.require_empty_matching_results",
            result.stdout + result.stderr,
        )

    def test_omitted_option_matches_explicit_false_upstream_behavior(self) -> None:
        omitted_database = self.root / "omitted.db"
        false_database = self.root / "false.db"
        shutil.copyfile(self.fixture_database, omitted_database)
        shutil.copyfile(self.fixture_database, false_database)

        omitted = self._run(database=omitted_database, require_empty=None)
        explicit_false = self._run(database=false_database, require_empty="0")

        self.assertEqual(omitted.returncode, 0, omitted.stdout + omitted.stderr)
        self.assertEqual(
            explicit_false.returncode,
            0,
            explicit_false.stdout + explicit_false.stderr,
        )
        self.assertEqual(
            self._snapshot(omitted_database),
            self._snapshot(false_database),
        )

    def test_required_pair_list_rejects_every_invalid_line_atomically(self) -> None:
        cases = {
            "missing-image": "000.png 001.png\n000.png missing.png\n",
            "missing-second-name": "000.png 001.png\n000.png\n",
            "extra-name": "000.png 001.png\n000.png 001.png extra.png\n",
            "self-pair": "000.png 001.png\n000.png 000.png\n",
        }
        for name, contents in cases.items():
            with self.subTest(name=name):
                database = self.root / f"invalid-{name}.db"
                pair_list = self.root / f"invalid-{name}.txt"
                shutil.copyfile(self.fixture_database, database)
                pair_list.write_text(contents, encoding="utf-8")
                before = self._snapshot(database)

                result = self._run(
                    database=database,
                    match_list=pair_list,
                    require_empty="1",
                )

                self.assertNotEqual(
                    result.returncode,
                    0,
                    result.stdout + result.stderr,
                )
                self.assertEqual(self._snapshot(database), before)

    def test_required_pair_list_open_failure_is_typed_and_atomic(self) -> None:
        missing = self.root / "missing-pairs.txt"
        before = self._snapshot(self.database)

        result = self._run(match_list=missing, require_empty="1")

        self.assertGreater(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn(
            "Could not open image pair list",
            result.stdout + result.stderr,
        )
        self.assertEqual(self._snapshot(self.database), before)

    def test_false_pair_list_preserves_upstream_skip_behavior(self) -> None:
        pair_list = self.root / "upstream-skip.txt"
        pair_list.write_text(
            "000.png 001.png\n000.png missing.png\n",
            encoding="utf-8",
        )

        result = self._run(match_list=pair_list, require_empty="0")

        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        matches, verified = self._snapshot(self.database)
        self.assertEqual(len(matches), 1)
        self.assertEqual(len(verified), 1)

    def test_empty_true_matches_upstream_successful_output(self) -> None:
        upstream_database = self.root / "upstream.db"
        shutil.copyfile(self.fixture_database, upstream_database)
        required = self._run(require_empty="1")
        upstream = self._run(database=upstream_database, require_empty="0")
        self.assertEqual(required.returncode, 0, required.stdout + required.stderr)
        self.assertEqual(upstream.returncode, 0, upstream.stdout + upstream.stderr)
        required_snapshot = self._snapshot(self.database)
        self.assertEqual(required_snapshot, self._snapshot(upstream_database))
        self.assertGreater(len(required_snapshot[0]), 0)

    def test_empty_schedule_commits_without_inventing_result_rows(self) -> None:
        empty_pairs = self.root / "empty-pairs.txt"
        empty_pairs.write_text("", encoding="utf-8")
        before = self._snapshot(self.database)
        result = self._run(match_list=empty_pairs, require_empty="1")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(self._snapshot(self.database), before)

    def test_true_rejects_every_existing_result_row_without_mutation(self) -> None:
        for table in ("matches", "two_view_geometries"):
            with self.subTest(table=table):
                database = self.root / f"existing-{table}.db"
                shutil.copyfile(self.fixture_database, database)
                self._insert_zero_length_result(database, table)
                before = self._snapshot(database)
                result = self._run(database=database, require_empty="1")
                self.assertNotEqual(
                    result.returncode,
                    0,
                    result.stdout + result.stderr,
                )
                self.assertIn(
                    "requires both matching result tables to be empty",
                    result.stdout + result.stderr,
                )
                self.assertEqual(self._snapshot(database), before)

    def test_false_preserves_upstream_existing_result_behavior(self) -> None:
        self._insert_zero_length_result(self.database, "matches")
        result = self._run(require_empty="0")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(len(self._snapshot(self.database)[0]), 1)

    def test_committed_wal_only_row_is_rejected(self) -> None:
        reader = sqlite3.connect(self.database)
        writer = sqlite3.connect(self.database)
        try:
            self.assertEqual(
                writer.execute("PRAGMA journal_mode=WAL").fetchone()[0], "wal"
            )
            writer.execute("PRAGMA wal_autocheckpoint=0")
            reader.execute("BEGIN")
            reader.execute("SELECT COUNT(*) FROM matches").fetchone()
            pair_id = self._pair_id(self.database)
            writer.execute(
                "INSERT INTO matches(pair_id, rows, cols, data) VALUES (?, 0, 2, NULL)",
                (pair_id,),
            )
            writer.commit()
            wal = Path(f"{self.database}-wal")
            self.assertTrue(wal.is_file())
            self.assertGreater(wal.stat().st_size, 0)

            before = self._snapshot(self.database)
            result = self._run(require_empty="1")
            self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertIn(
                "requires both matching result tables to be empty",
                result.stdout + result.stderr,
            )
            self.assertEqual(self._snapshot(self.database), before)
        finally:
            reader.close()
            writer.close()

    def test_active_immediate_writer_fails_closed_without_mutation(self) -> None:
        writer = sqlite3.connect(self.database)
        try:
            writer.execute("BEGIN IMMEDIATE")
            before = self._snapshot(self.database)
            result = self._run(require_empty="1")
            self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertIn("exclusive database ownership", result.stdout + result.stderr)
            self.assertEqual(self._snapshot(self.database), before)
        finally:
            writer.rollback()
            writer.close()

    def test_job_transaction_blocks_writer_after_setup_until_commit(self) -> None:
        pair_fifo = self.root / "pairs.fifo"
        os.mkfifo(pair_fifo)
        fifo_opened = threading.Event()
        release_fifo = threading.Event()
        feeder_errors: list[BaseException] = []

        def feed_pairs() -> None:
            try:
                with pair_fifo.open("w", encoding="utf-8") as stream:
                    fifo_opened.set()
                    if not release_fifo.wait(timeout=10):
                        raise TimeoutError("pair FIFO release timed out")
                    stream.write("000.png 001.png\n")
            except BaseException as error:
                feeder_errors.append(error)
                fifo_opened.set()

        feeder = threading.Thread(target=feed_pairs, daemon=True)
        feeder.start()
        process = subprocess.Popen(
            [
                str(self.native_binary),
                *self._arguments(match_list=pair_fifo, require_empty="1"),
            ],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            env=self._environment(),
        )
        try:
            self.assertTrue(fifo_opened.wait(timeout=10), "pair FIFO was not opened")
            self.assertFalse(feeder_errors, feeder_errors)
            with open_sqlite(self.database, timeout=0, isolation_level=None) as writer:
                with self.assertRaisesRegex(sqlite3.OperationalError, "locked"):
                    writer.execute("BEGIN IMMEDIATE")
            release_fifo.set()
            stdout, stderr = process.communicate(timeout=60)
        finally:
            release_fifo.set()
            if process.poll() is None:
                process.kill()
                process.communicate()
            feeder.join(timeout=10)

        self.assertFalse(feeder.is_alive(), "pair FIFO feeder did not finish")
        self.assertFalse(feeder_errors, feeder_errors)
        self.assertEqual(process.returncode, 0, stdout + stderr)
        matches, verified = self._snapshot(self.database)
        self.assertEqual(len(matches), 1)
        self.assertEqual(len(verified), 1)

    def test_hard_link_created_during_job_prevents_commit(self) -> None:
        pair_fifo = self.root / "hard-link-race-pairs.fifo"
        os.mkfifo(pair_fifo)
        fifo_opened = threading.Event()
        release_fifo = threading.Event()
        feeder_errors: list[BaseException] = []

        def feed_pairs() -> None:
            try:
                with pair_fifo.open("w", encoding="utf-8") as stream:
                    fifo_opened.set()
                    if not release_fifo.wait(timeout=10):
                        raise TimeoutError("pair FIFO release timed out")
                    stream.write("000.png 001.png\n")
            except BaseException as error:
                feeder_errors.append(error)
                fifo_opened.set()

        before = self._snapshot(self.database)
        feeder = threading.Thread(target=feed_pairs, daemon=True)
        feeder.start()
        process = subprocess.Popen(
            [
                str(self.native_binary),
                *self._arguments(match_list=pair_fifo, require_empty="1"),
            ],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            env=self._environment(),
        )
        raced_link = self.root / "raced-hard-link.db"
        try:
            self.assertTrue(fifo_opened.wait(timeout=10), "pair FIFO was not opened")
            self.assertFalse(feeder_errors, feeder_errors)
            os.link(self.database, raced_link)
            release_fifo.set()
            stdout, stderr = process.communicate(timeout=60)
        finally:
            release_fifo.set()
            if process.poll() is None:
                process.kill()
                process.communicate()
            feeder.join(timeout=10)
            raced_link.unlink(missing_ok=True)

        self.assertFalse(feeder.is_alive(), "pair FIFO feeder did not finish")
        self.assertFalse(feeder_errors, feeder_errors)
        self.assertNotEqual(process.returncode, 0, stdout + stderr)
        self.assertIn("database path changed", stdout + stderr)
        self.assertEqual(self._snapshot(self.database), before)

    def test_namespace_swaps_fail_at_each_precommit_boundary(self) -> None:
        if self.boundary_shim is None:
            self.skipTest("could not build importer boundary shim")
        for phase in ("before_open", "after_open", "before_precommit"):
            with self.subTest(phase=phase):
                database = self.root / f"{phase}.db"
                moved_database = self.root / f"{phase}-opened.db"
                replacement_database = self.root / f"{phase}-replacement.db"
                shutil.copyfile(self.fixture_database, database)
                shutil.copyfile(self.fixture_database, replacement_database)
                original_before = self._snapshot(database)
                replacement_before = self._snapshot(replacement_database)
                environment = self._environment()
                environment.update(
                    {
                        "DYLD_INSERT_LIBRARIES": str(self.boundary_shim),
                        "EASYSPLAT_TEST_IMPORTER_SWAP_PHASE": phase,
                        "EASYSPLAT_TEST_IMPORTER_PATH": str(database),
                        "EASYSPLAT_TEST_IMPORTER_MOVED": str(moved_database),
                        "EASYSPLAT_TEST_IMPORTER_REPLACEMENT": str(
                            replacement_database
                        ),
                    }
                )

                result = subprocess.run(
                    [
                        str(self.native_binary),
                        *self._arguments(database=database, require_empty="1"),
                    ],
                    check=False,
                    capture_output=True,
                    text=True,
                    env=environment,
                    timeout=60,
                )

                self.assertNotEqual(
                    result.returncode,
                    0,
                    result.stdout + result.stderr,
                )
                self.assertRegex(
                    result.stdout + result.stderr,
                    r"database path changed|bound database descriptor",
                )
                self.assertTrue(database.is_symlink())
                self.assertEqual(self._snapshot(moved_database), original_before)
                self.assertEqual(
                    self._snapshot(replacement_database), replacement_before
                )

    def test_transient_swap_only_during_sqlite_open_cannot_bind_replacement(
        self,
    ) -> None:
        if self.boundary_shim is None:
            self.skipTest("could not build importer boundary shim")
        moved_database = self.root / "during-open-original.db"
        replacement_database = self.root / "during-open-replacement.db"
        shutil.copyfile(self.fixture_database, replacement_database)
        original_before = self._snapshot(self.database)
        replacement_before = self._snapshot(replacement_database)
        environment = self._environment()
        environment.update(
            {
                "DYLD_INSERT_LIBRARIES": str(self.boundary_shim),
                "EASYSPLAT_TEST_IMPORTER_SWAP_PHASE": "during_open_restore",
                "EASYSPLAT_TEST_IMPORTER_PATH": str(self.database),
                "EASYSPLAT_TEST_IMPORTER_MOVED": str(moved_database),
                "EASYSPLAT_TEST_IMPORTER_REPLACEMENT": str(replacement_database),
            }
        )
        result = subprocess.run(
            [str(self.native_binary), *self._arguments(require_empty="1")],
            check=False,
            capture_output=True,
            text=True,
            env=environment,
            timeout=60,
        )
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("database", result.stdout + result.stderr)
        self.assertEqual(self._snapshot(self.database), original_before)
        self.assertEqual(self._snapshot(replacement_database), replacement_before)
        self.assertFalse(moved_database.exists())

    def test_namespace_swap_after_commit_remains_successful(self) -> None:
        if self.boundary_shim is None:
            self.skipTest("could not build importer boundary shim")
        moved_database = self.root / "after-commit-opened.db"
        replacement_database = self.root / "after-commit-replacement.db"
        shutil.copyfile(self.fixture_database, replacement_database)
        replacement_before = self._snapshot(replacement_database)
        environment = self._environment()
        environment.update(
            {
                "DYLD_INSERT_LIBRARIES": str(self.boundary_shim),
                "EASYSPLAT_TEST_IMPORTER_SWAP_PHASE": "after_commit",
                "EASYSPLAT_TEST_IMPORTER_PATH": str(self.database),
                "EASYSPLAT_TEST_IMPORTER_MOVED": str(moved_database),
                "EASYSPLAT_TEST_IMPORTER_REPLACEMENT": str(replacement_database),
            }
        )

        result = subprocess.run(
            [str(self.native_binary), *self._arguments(require_empty="1")],
            check=False,
            capture_output=True,
            text=True,
            env=environment,
            timeout=60,
        )

        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertTrue(self.database.is_symlink())
        matches, verified = self._snapshot(moved_database)
        self.assertEqual(len(matches), 1)
        self.assertEqual(len(verified), 1)
        self.assertEqual(self._snapshot(replacement_database), replacement_before)

    def test_required_mode_rejects_symbolic_link_database(self) -> None:
        linked_database = self.root / "linked-features.db"
        linked_database.symlink_to(self.database.name)
        before = self._snapshot(self.database)
        result = self._run(database=linked_database, require_empty="1")
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("not a symbolic link", result.stdout + result.stderr)
        self.assertEqual(self._snapshot(self.database), before)

    def test_required_mode_rejects_hard_linked_database(self) -> None:
        linked_database = self.root / "hard-linked-features.db"
        os.link(self.database, linked_database)
        before = self._snapshot(self.database)
        result = self._run(database=linked_database, require_empty="1")
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("exactly one hard link", result.stdout + result.stderr)
        self.assertEqual(self._snapshot(self.database), before)

    def test_partial_raw_and_inlier_failures_roll_back_every_result_byte(self) -> None:
        imported = self._write_partially_valid_import()
        for match_type, written_table in (
            ("raw", "matches"),
            ("inliers", "two_view_geometries"),
        ):
            with self.subTest(match_type=match_type):
                control = self.root / f"partial-control-{match_type}.db"
                shutil.copyfile(self.fixture_database, control)
                control_result = self._run(
                    database=control,
                    match_list=imported,
                    match_type=match_type,
                    require_empty="0",
                )
                self.assertEqual(
                    control_result.returncode,
                    0,
                    control_result.stdout + control_result.stderr,
                )
                control_snapshot = self._snapshot(control)
                table_index = 0 if written_table == "matches" else 1
                self.assertGreater(len(control_snapshot[table_index]), 0)

                database = self.root / f"partial-required-{match_type}.db"
                shutil.copyfile(self.fixture_database, database)
                before_rows = self._snapshot(database)
                result = self._run(
                    database=database,
                    match_list=imported,
                    match_type=match_type,
                    require_empty="1",
                )
                self.assertNotEqual(
                    result.returncode,
                    0,
                    result.stdout + result.stderr,
                )
                self.assertIn("did not complete cleanly", result.stdout + result.stderr)
                self.assertEqual(self._snapshot(database), before_rows)

    def test_raw_and_inlier_require_exact_headers_and_match_rows(self) -> None:
        cases = {
            "header-extra": "000.png 001.png trailing\n0 0\n\n",
            "self-pair": "000.png 000.png\n0 0\n\n",
            "match-extra": "000.png 001.png\n0 0 trailing\n\n",
            "match-missing": "000.png 001.png\n0\n\n",
            "match-negative": "000.png 001.png\n-1 0\n\n",
            "match-overflow": "000.png 001.png\n4294967296 0\n\n",
            "match-nonnumeric": "000.png 001.png\nzero 0\n\n",
            "match-out-of-range": "000.png 001.png\n999 0\n\n",
        }
        for match_type in ("raw", "inliers"):
            for name, contents in cases.items():
                with self.subTest(match_type=match_type, case=name):
                    database = self.root / f"grammar-{match_type}-{name}.db"
                    imported = self.root / f"grammar-{match_type}-{name}.txt"
                    shutil.copyfile(self.fixture_database, database)
                    imported.write_text(contents, encoding="utf-8")
                    before = self._snapshot(database)
                    result = self._run(
                        database=database,
                        match_list=imported,
                        match_type=match_type,
                        require_empty="1",
                    )
                    self.assertNotEqual(
                        result.returncode,
                        0,
                        result.stdout + result.stderr,
                    )
                    self.assertEqual(self._snapshot(database), before)

    def test_raw_and_inlier_read_errors_never_commit_partial_blocks(self) -> None:
        if self.read_error_shim is None:
            self.skipTest("could not build importer read-error shim")
        imported = self.root / "read-error-matches.txt"
        imported.write_text(
            "000.png 001.png\n"
            + "".join(f"{index % 24} {index % 24}\n" for index in range(80))
            + "\n",
            encoding="utf-8",
        )
        for match_type in ("raw", "inliers"):
            with self.subTest(match_type=match_type):
                database = self.root / f"read-error-{match_type}.db"
                shutil.copyfile(self.fixture_database, database)
                before = self._snapshot(database)
                environment = self._environment()
                environment.update(
                    {
                        "DYLD_INSERT_LIBRARIES": str(self.read_error_shim),
                        "EASYSPLAT_TEST_MATCH_LIST_PATH": str(imported),
                    }
                )
                result = subprocess.run(
                    [
                        str(self.native_binary),
                        *self._arguments(
                            database=database,
                            match_list=imported,
                            match_type=match_type,
                            require_empty="1",
                        ),
                    ],
                    check=False,
                    capture_output=True,
                    text=True,
                    env=environment,
                    timeout=60,
                )
                self.assertNotEqual(
                    result.returncode,
                    0,
                    result.stdout + result.stderr,
                )
                self.assertEqual(self._snapshot(database), before)

    def test_termination_rolls_back_fifo_blocked_required_import(self) -> None:
        pair_fifo = self.root / "terminated-pairs.fifo"
        os.mkfifo(pair_fifo)
        fifo_opened = threading.Event()
        release_fifo = threading.Event()
        feeder_errors: list[BaseException] = []

        def hold_fifo_open() -> None:
            try:
                with pair_fifo.open("w", encoding="utf-8"):
                    fifo_opened.set()
                    if not release_fifo.wait(timeout=10):
                        raise TimeoutError("pair FIFO release timed out")
            except BrokenPipeError:
                fifo_opened.set()
            except BaseException as error:
                feeder_errors.append(error)
                fifo_opened.set()

        before_rows = self._snapshot(self.database)
        feeder = threading.Thread(target=hold_fifo_open, daemon=True)
        feeder.start()
        process = subprocess.Popen(
            [
                str(self.native_binary),
                *self._arguments(match_list=pair_fifo, require_empty="1"),
            ],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            env=self._environment(),
        )
        try:
            self.assertTrue(fifo_opened.wait(timeout=10), "pair FIFO was not opened")
            self.assertFalse(feeder_errors, feeder_errors)
            with open_sqlite(self.database, timeout=0, isolation_level=None) as writer:
                with self.assertRaisesRegex(sqlite3.OperationalError, "locked"):
                    writer.execute("BEGIN IMMEDIATE")
            process.terminate()
            stdout, stderr = process.communicate(timeout=10)
        finally:
            release_fifo.set()
            if process.poll() is None:
                process.kill()
                process.communicate()
            feeder.join(timeout=10)

        self.assertFalse(feeder.is_alive(), "pair FIFO holder did not finish")
        self.assertFalse(feeder_errors, feeder_errors)
        self.assertLess(process.returncode, 0, stdout + stderr)
        self.assertEqual(self._snapshot(self.database), before_rows)
        with open_sqlite(self.database, timeout=0, isolation_level=None) as writer:
            self.assertEqual(
                writer.execute("PRAGMA integrity_check").fetchone(),
                ("ok",),
            )
            writer.execute("BEGIN IMMEDIATE")
            writer.rollback()

    def test_raw_and_inlier_imports_honor_required_empty_database(self) -> None:
        imported = self._write_imported_matches()
        for match_type in ("raw", "inliers"):
            with self.subTest(match_type=match_type):
                database = self.root / f"{match_type}.db"
                shutil.copyfile(self.fixture_database, database)
                result = self._run(
                    database=database,
                    match_list=imported,
                    match_type=match_type,
                    require_empty="1",
                )
                self.assertEqual(
                    result.returncode,
                    0,
                    result.stdout + result.stderr,
                )
                matches, verified = self._snapshot(database)
                if match_type == "raw":
                    self.assertGreater(len(matches), 0)
                self.assertGreater(len(verified), 0)

    def test_raw_and_inlier_imports_reject_existing_results(self) -> None:
        imported = self._write_imported_matches()
        for match_type, table in (
            ("raw", "matches"),
            ("inliers", "two_view_geometries"),
        ):
            with self.subTest(match_type=match_type):
                database = self.root / f"existing-{match_type}.db"
                shutil.copyfile(self.fixture_database, database)
                self._insert_zero_length_result(database, table)
                before = self._snapshot(database)
                result = self._run(
                    database=database,
                    match_list=imported,
                    match_type=match_type,
                    require_empty="1",
                )
                self.assertNotEqual(
                    result.returncode,
                    0,
                    result.stdout + result.stderr,
                )
                self.assertEqual(self._snapshot(database), before)


if __name__ == "__main__":
    unittest.main(verbosity=2)
