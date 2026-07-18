#!/usr/bin/env python3
from __future__ import annotations

import hashlib
import json
import os
import shutil
import sqlite3
import struct
import subprocess
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[3]
BUILD_SCRIPT = ROOT / "scripts/toolchain/build_colmap.sh"
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


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        while chunk := stream.read(1024 * 1024):
            digest.update(chunk)
    return digest.hexdigest()


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


def ordinary_images(*, rows: int = 20) -> list[tuple[str, list[tuple[float, ...]], list[bytes]]]:
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
        self.assertLess(PATCH_PATH.stat().st_size, 16_384)

    def test_build_script_pins_reviewed_faiss_and_generic_apple_silicon(self) -> None:
        script = BUILD_SCRIPT.read_text(encoding="utf-8")
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
        self.assertIn('(\"-mcpu\", \"native\")', script)
        self.assertIn('(\"-march\", \"native\")', script)
        self.assertNotIn("-mcpu=native", script)
        self.assertNotIn("-march=native", script)

    def test_compile_command_audit_executes_and_rejects_host_tuning(self) -> None:
        script = BUILD_SCRIPT.read_text(encoding="utf-8")
        marker = 'python3 - "$BUILD/compile_commands.json" <<\'PY\'\n'
        self.assertEqual(script.count(marker), 1)
        audit = script.split(marker, 1)[1].split("\nPY\n", 1)[0]

        with tempfile.TemporaryDirectory() as directory:
            commands = Path(directory) / "compile_commands.json"

            def run(command: str) -> subprocess.CompletedProcess[str]:
                commands.write_text(
                    json.dumps([{"command": command, "file": "/tmp/source.cc"}]),
                    encoding="utf-8",
                )
                return subprocess.run(
                    ["python3", "-", str(commands)],
                    input=audit,
                    check=False,
                    capture_output=True,
                    text=True,
                )

            allowed = run("clang++ -mcpu apple-m1 -c /tmp/source.cc")
            self.assertEqual(allowed.returncode, 0, allowed.stdout + allowed.stderr)
            for command in (
                "clang++ -mcpu native -c /tmp/source.cc",
                "clang++ -march=native -c /tmp/source.cc",
            ):
                with self.subTest(command=command):
                    rejected = run(command)
                    self.assertNotEqual(rejected.returncode, 0)
                    self.assertIn(
                        "host-specific compiler tuning entered the build",
                        rejected.stdout + rejected.stderr,
                    )

    def test_retriever_preflights_faiss_boundaries_and_aggregate_memory(self) -> None:
        source = (OVERLAY_ROOT / "local_vocab_retriever.cc").read_text(
            encoding="utf-8"
        )
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
        source = (OVERLAY_ROOT / "local_vocab_retriever.cc").read_text(
            encoding="utf-8"
        )
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
        source = (OVERLAY_ROOT / "local_vocab_retriever.cc").read_text(
            encoding="utf-8"
        )
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
            'python3 "$ROOT/scripts/toolchain/tests/'
            'test_native_colmap_retriever.py"\n',
            release_test,
        )

        build_script = BUILD_SCRIPT.read_text(encoding="utf-8")
        self.assertIn("validate_native_retriever()", build_script)
        self.assertIn(
            'EASYSPLAT_NATIVE_COLMAP_BIN="$INSTALL/bin/colmap"',
            build_script,
        )
        self.assertIn(
            'EASYSPLAT_NATIVE_COLMAP_DYLD_LIBRARY_PATH="$runtime_path"',
            build_script,
        )
        self.assertIn(
            'test_native_colmap_retriever.py" NativeRetrieverTests',
            build_script,
        )
        self.assertNotIn('EASYSPLAT_PYCOLMAP_COLMAP_BIN=""', build_script)
        self.assertRegex(
            build_script,
            r"validate_commands\s*\nvalidate_native_retriever\s*\n",
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
            "__attribute__((section(\"__DATA,__interpose\"))) = "
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
            result = subprocess.run(
                [
                    clang,
                    "-dynamiclib",
                    str(source_path),
                    "-lsqlite3",
                    "-o",
                    str(library_path),
                ],
                check=False,
                capture_output=True,
                text=True,
            )
            if result.returncode == 0:
                shims[name] = library_path
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
            for option, value in zip(extra[::2], extra[1::2], strict=True):
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
            [path for path in self.root.iterdir() if path.name.startswith(".pairs.txt.")],
            [],
        )

    def assertNoTemporaryOutput(self) -> None:
        self.assertEqual(
            [path for path in self.root.iterdir() if path.name.startswith(".pairs.txt.")],
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
        excluded_file.write_text(
            "000-alpha.jpg 001-bravo.jpg\n", encoding="utf-8"
        )
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

    def test_image_name_metadata_rejects_oversized_names_before_materializing(self) -> None:
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

    def test_optional_descriptor_type_column_and_default_threads_are_supported(self) -> None:
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
                "UPDATE images SET name = '000-alpha.jpg' "
                "WHERE name = '001-bravo.jpg'",
                "duplicate image names",
            ),
            (
                "whitespace-name",
                "UPDATE images SET name = 'bad name.jpg' "
                "WHERE name = '001-bravo.jpg'",
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

    def test_four_and_six_column_keypoints_match_the_python_oracle(self) -> None:
        if self.oracle_binary is None:
            self.skipTest("set EASYSPLAT_PYCOLMAP_COLMAP_BIN for oracle parity")
        images = ordinary_images()
        images[1] = (images[1][0], keypoints6(20, scale_offset=1.0), images[1][2])
        mixed_database = self.root / "mixed-keypoints.db"
        create_feature_database(mixed_database, images)
        native_output = self.root / "native.txt"
        oracle_output = self.root / "oracle.txt"
        native = self._run(database=mixed_database, output=native_output)
        oracle = self._run(
            database=mixed_database,
            output=oracle_output,
            binary=self.oracle_binary,
        )
        self.assertEqual(native.returncode, 0, native.stdout + native.stderr)
        self.assertEqual(oracle.returncode, 0, oracle.stdout + oracle.stderr)
        self.assertEqual(native_output.read_bytes(), oracle_output.read_bytes())

    def test_top_scale_selection_and_even_training_sampling_match_oracle(self) -> None:
        if self.oracle_binary is None:
            self.skipTest("set EASYSPLAT_PYCOLMAP_COLMAP_BIN for oracle parity")
        images = []
        for image_index, center in enumerate((7, 41, 133, 219)):
            row_count = 180
            scales = [float((row * 37 + image_index * 11) % 251 + 1) for row in range(row_count)]
            keypoints = [
                (float(row), float(row + 1), scales[row], 0.0)
                for row in range(row_count)
            ]
            descriptors = [descriptor(center, row) for row in range(row_count)]
            images.append((f"{image_index:03d}.jpg", keypoints, descriptors))
        sampled_database = self.root / "sampled.db"
        create_feature_database(sampled_database, images)
        native_output = self.root / "native-sampled.txt"
        oracle_output = self.root / "oracle-sampled.txt"
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
        oracle = self._run(
            database=sampled_database,
            output=oracle_output,
            extra=options,
            binary=self.oracle_binary,
        )
        self.assertEqual(native.returncode, 0, native.stdout + native.stderr)
        self.assertEqual(oracle.returncode, 0, oracle.stdout + oracle.stderr)
        self.assertEqual(native_output.read_bytes(), oracle_output.read_bytes())

    def test_top_scale_ties_retain_original_row_order(self) -> None:
        if self.oracle_binary is None:
            self.skipTest("set EASYSPLAT_PYCOLMAP_COLMAP_BIN for oracle parity")
        images = []
        for image_index, center in enumerate((5, 53, 137, 223)):
            keypoints = [
                (float(row), float(row + 1), 10.0, 0.0) for row in range(12)
            ]
            descriptors = [descriptor(center, row) for row in range(12)]
            images.append((f"{image_index:03d}.jpg", keypoints, descriptors))
        tied_database = self.root / "top-scale-ties.db"
        create_feature_database(tied_database, images)
        native_output = self.root / "native-ties.txt"
        oracle_output = self.root / "oracle-ties.txt"
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
        oracle = self._run(
            database=tied_database,
            output=oracle_output,
            extra=options,
            binary=self.oracle_binary,
        )
        self.assertEqual(native.returncode, 0, native.stdout + native.stderr)
        self.assertEqual(oracle.returncode, 0, oracle.stdout + oracle.stderr)
        self.assertEqual(native_output.read_bytes(), oracle_output.read_bytes())

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
            for index, name in enumerate(sorted(image[0] for image in ordinary_images()))
        }
        undirected = set()
        for line in lines:
            first, second = line.split()
            self.assertNotEqual(first, second)
            self.assertGreaterEqual(abs(lexical_order[first] - lexical_order[second]), 2)
            edge = tuple(sorted((first, second)))
            self.assertNotIn(edge, undirected)
            undirected.add(edge)
            self.assertNotEqual(edge, ("000-alpha.jpg", "002-charlie.jpg"))

    def test_equal_scores_use_lexical_tie_breaking(self) -> None:
        rows = 24
        shared = [descriptor(31, row) for row in range(rows)]
        images = [
            ("000-query.jpg", keypoints4(rows), [descriptor(30, row) for row in range(rows)]),
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
        self.assertEqual(successful.returncode, 0, successful.stdout + successful.stderr)
        expected_bytes = expected_output.read_bytes()

        self.output.write_text("preserve me\n", encoding="utf-8")
        result = self._run(
            environment={"DYLD_INSERT_LIBRARIES": str(shim)},
        )
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("could not sync output pair list directory", result.stdout + result.stderr)
        self.assertEqual(self.output.read_bytes(), expected_bytes)
        self.assertNoTemporaryOutput()

    def test_non_tied_fixture_exactly_matches_frozen_python_oracle(self) -> None:
        if self.oracle_binary is None:
            self.skipTest("set EASYSPLAT_PYCOLMAP_COLMAP_BIN for oracle parity")
        query_list = self.root / "oracle-queries.txt"
        query_list.write_text("000-alpha.jpg\n002-charlie.jpg\n", encoding="utf-8")
        native_output = self.root / "native-oracle.txt"
        oracle_output = self.root / "python-oracle.txt"
        options = ["--query_image_list_path", str(query_list)]
        native = self._run(output=native_output, extra=options)
        oracle = self._run(
            output=oracle_output,
            extra=options,
            binary=self.oracle_binary,
        )
        self.assertEqual(native.returncode, 0, native.stdout + native.stderr)
        self.assertEqual(oracle.returncode, 0, oracle.stdout + oracle.stderr)
        self.assertEqual(native_output.read_bytes(), oracle_output.read_bytes())


if __name__ == "__main__":
    unittest.main(verbosity=2)
