#!/usr/bin/env python3

from __future__ import annotations

import ast
import binascii
import hashlib
import json
import math
import os
import runpy
import shutil
import stat
import struct
import subprocess
import sys
import tempfile
import unittest
from unittest import mock
import zlib
from pathlib import Path


RELEASE_DIR = Path(__file__).resolve().parents[1]
SCRIPT = RELEASE_DIR / "generate_release_fixture.py"
MANIFEST = RELEASE_DIR / "release_fixture_manifest.json"
PNG_SIGNATURE = b"\x89PNG\r\n\x1a\n"


def canonical_json(value: object) -> bytes:
    return (json.dumps(value, indent=2, sort_keys=True) + "\n").encode("utf-8")


def run_generator(
    *arguments: str, expect_success: bool = True
) -> subprocess.CompletedProcess[str]:
    result = subprocess.run(
        [sys.executable, "-I", os.fspath(SCRIPT), *arguments],
        check=False,
        capture_output=True,
        text=True,
    )
    if expect_success and result.returncode != 0:
        raise AssertionError(result.stderr)
    if not expect_success and result.returncode == 0:
        raise AssertionError("invalid release fixture operation was accepted")
    return result


def read_png(path: Path) -> tuple[dict[str, int], bytes, list[str]]:
    payload = path.read_bytes()
    if not payload.startswith(PNG_SIGNATURE):
        raise AssertionError(f"{path.name} has no PNG signature")
    offset = len(PNG_SIGNATURE)
    chunks: list[str] = []
    idat = bytearray()
    header: dict[str, int] = {}
    while offset < len(payload):
        length = struct.unpack(">I", payload[offset : offset + 4])[0]
        kind = payload[offset + 4 : offset + 8]
        data = payload[offset + 8 : offset + 8 + length]
        crc = struct.unpack(">I", payload[offset + 8 + length : offset + 12 + length])[
            0
        ]
        if binascii.crc32(kind + data) & 0xFFFFFFFF != crc:
            raise AssertionError(f"{path.name} has an invalid {kind!r} CRC")
        chunks.append(kind.decode("ascii"))
        if kind == b"IHDR":
            width, height, bit_depth, color_type, compression, filtering, interlace = (
                struct.unpack(">IIBBBBB", data)
            )
            header = {
                "width": width,
                "height": height,
                "bitDepth": bit_depth,
                "colorType": color_type,
                "compression": compression,
                "filter": filtering,
                "interlace": interlace,
            }
        elif kind == b"IDAT":
            idat.extend(data)
        offset += 12 + length
        if kind == b"IEND":
            break
    if offset != len(payload):
        raise AssertionError(f"{path.name} has trailing PNG bytes")
    return header, zlib.decompress(bytes(idat)), chunks


def fixture_paths(root: Path) -> list[Path]:
    return sorted(
        (path for path in root.rglob("*") if path.is_file()),
        key=lambda path: path.relative_to(root).as_posix(),
    )


def camera_basis(
    yaw_degrees: float, pitch_degrees: float
) -> tuple[tuple[float, ...], ...]:
    yaw = math.radians(yaw_degrees)
    pitch = math.radians(pitch_degrees)
    forward = (
        math.sin(yaw) * math.cos(pitch),
        math.sin(pitch),
        math.cos(yaw) * math.cos(pitch),
    )
    right = (math.cos(yaw), 0.0, -math.sin(yaw))
    up = (
        -math.sin(yaw) * math.sin(pitch),
        math.cos(pitch),
        -math.cos(yaw) * math.sin(pitch),
    )
    return forward, right, up


def project(
    point: list[float], view: dict[str, object], camera: dict[str, object]
) -> tuple[float, float]:
    position = view["positionMeters"]
    assert isinstance(position, list)
    relative = tuple(float(point[index]) - float(position[index]) for index in range(3))
    forward, right, up = camera_basis(
        float(view["yawDegrees"]), float(view["pitchDegrees"])
    )
    depth = sum(relative[index] * forward[index] for index in range(3))
    horizontal = sum(relative[index] * right[index] for index in range(3))
    vertical = sum(relative[index] * up[index] for index in range(3))
    return (
        float(camera["cxPixels"]) + float(camera["fxPixels"]) * horizontal / depth,
        float(camera["cyPixels"]) - float(camera["fyPixels"]) * vertical / depth,
    )


def back_project_to_depth(
    pixel_x: int,
    pixel_y: int,
    depth: float,
    view: dict[str, object],
    camera: dict[str, object],
) -> list[float]:
    position = view["positionMeters"]
    basis = view["basisWorldFromCamera"]
    assert isinstance(position, list)
    assert isinstance(basis, dict)
    forward = basis["forward"]
    right = basis["right"]
    up = basis["up"]
    assert isinstance(forward, list)
    assert isinstance(right, list)
    assert isinstance(up, list)
    image_x = (pixel_x + 0.5 - float(camera["cxPixels"])) / float(camera["fxPixels"])
    image_y = (pixel_y + 0.5 - float(camera["cyPixels"])) / float(camera["fyPixels"])
    direction = [
        float(forward[index])
        + float(right[index]) * image_x
        - float(up[index]) * image_y
        for index in range(3)
    ]
    distance = (depth - float(position[2])) / direction[2]
    return [float(position[index]) + distance * direction[index] for index in range(3)]


class ReleaseFixtureManifestTests(unittest.TestCase):
    def setUp(self) -> None:
        self.manifest = json.loads(MANIFEST.read_text(encoding="utf-8"))

    def test_generator_and_manifest_are_checked_in_canonical_contracts(self) -> None:
        self.assertTrue(SCRIPT.is_file())
        self.assertEqual(MANIFEST.read_bytes(), canonical_json(self.manifest))
        self.assertEqual(self.manifest.get("schemaVersion"), 1)
        self.assertEqual(self.manifest["fixtureID"], "org.easysplat.release-smoke.v1")
        self.assertEqual(self.manifest["license"]["spdxID"], "MIT")
        self.assertEqual(self.manifest["provenance"]["sourceAssets"], [])
        self.assertTrue(self.manifest["provenance"]["synthetic"])

    def test_manifest_pins_generator_source_and_stdlib_only_implementation(
        self,
    ) -> None:
        source = SCRIPT.read_bytes()
        self.assertIn(b"SPDX-License-Identifier: MIT", source)
        self.assertEqual(
            self.manifest["provenance"]["generatorSHA256"],
            hashlib.sha256(source).hexdigest(),
        )
        tree = ast.parse(source)
        imported = {
            alias.name.partition(".")[0]
            for node in ast.walk(tree)
            if isinstance(node, ast.Import)
            for alias in node.names
        }
        imported.update(
            node.module.partition(".")[0]
            for node in ast.walk(tree)
            if isinstance(node, ast.ImportFrom) and node.module
        )
        allowed_stdlib = {
            "__future__",
            "argparse",
            "binascii",
            "ctypes",
            "errno",
            "hashlib",
            "json",
            "math",
            "os",
            "pathlib",
            "re",
            "shutil",
            "stat",
            "struct",
            "sys",
            "tempfile",
            "unicodedata",
        }
        self.assertLessEqual(imported, allowed_stdlib)
        self.assertIn(
            b"def read_authenticated_file(\n    path: Path, expected_mode: int, expected_size: int\n)",
            source,
        )

    def test_exclusive_publication_uses_portable_macos_flags(self) -> None:
        class FakeRename:
            def __init__(self) -> None:
                self.calls: list[tuple[int, bytes, int, bytes, int]] = []
                self.argtypes: object = None
                self.restype: object = None

            def __call__(
                self,
                source_directory_descriptor: int,
                source_name: bytes,
                destination_directory_descriptor: int,
                destination_name: bytes,
                flags: int,
            ) -> int:
                self.calls.append(
                    (
                        source_directory_descriptor,
                        source_name,
                        destination_directory_descriptor,
                        destination_name,
                        flags,
                    )
                )
                return 0

        namespace = runpy.run_path(
            os.fspath(SCRIPT), run_name="release_fixture_generator_test"
        )
        rename = FakeRename()
        library = type("FakeLibrary", (), {"renameatx_np": rename})()
        with (
            mock.patch.object(namespace["ctypes"], "CDLL", return_value=library),
            mock.patch.object(namespace["sys"], "platform", "darwin"),
        ):
            namespace["rename_exclusive"](
                37,
                ".fixture.staging-token",
                "fixture",
            )

        self.assertEqual(
            rename.calls,
            [
                (
                    37,
                    b".fixture.staging-token",
                    37,
                    b"fixture",
                    0x00000004,
                )
            ],
        )

        for invalid_name in ("", ".", "..", "/absolute", "nested/name", "bad\0name"):
            with self.subTest(invalid_name=invalid_name):
                with self.assertRaises(namespace["FixtureError"]):
                    namespace["rename_exclusive"](37, invalid_name, "fixture")
                with self.assertRaises(namespace["FixtureError"]):
                    namespace["rename_exclusive"](37, ".fixture.staging-token", invalid_name)
        self.assertEqual(len(rename.calls), 1)

    def test_generation_keeps_source_writable_until_atomic_publication(self) -> None:
        namespace = runpy.run_path(
            os.fspath(SCRIPT), run_name="release_fixture_generator_mode_test"
        )
        observed: list[tuple[int, int]] = []

        def rename_with_macos_15_permissions(
            parent_descriptor: int,
            source_name: str,
            destination_name: str,
        ) -> None:
            source = os.stat(
                source_name,
                dir_fd=parent_descriptor,
                follow_symlinks=False,
            )
            source_mode = stat.S_IMODE(source.st_mode)
            observed.append((source_mode, source.st_ino))
            if source_mode != 0o700:
                raise PermissionError("macOS 15 rejects a read-only source directory")
            os.rename(
                source_name,
                destination_name,
                src_dir_fd=parent_descriptor,
                dst_dir_fd=parent_descriptor,
            )

        temporary_parent = os.path.realpath(
            os.environ.get("RUNNER_TEMP", tempfile.gettempdir())
        )
        with tempfile.TemporaryDirectory(dir=temporary_parent) as temporary:
            output = Path(temporary) / "fixture"
            namespace["generate_fixture"].__globals__["rename_exclusive"] = (
                rename_with_macos_15_permissions
            )
            namespace["generate_fixture"](output)
            output_metadata = output.lstat()
            self.assertEqual(observed, [(0o700, output_metadata.st_ino)])
            self.assertEqual(stat.S_IMODE(output_metadata.st_mode), 0o555)
            namespace["verify_fixture"](output)

    def test_manifest_pins_twelve_pinhole_views_and_multidepth_scene(self) -> None:
        image = self.manifest["image"]
        camera = self.manifest["camera"]
        scene = self.manifest["scene"]
        self.assertEqual(
            image,
            {
                "bitDepth": 8,
                "colorType": "RGB",
                "count": 12,
                "heightPixels": 480,
                "pngEncoding": "filter-none-deflate-stored-v1",
                "widthPixels": 640,
            },
        )
        self.assertEqual(camera["model"], "PINHOLE")
        self.assertEqual(len(camera["views"]), 12)
        self.assertEqual(
            len({tuple(row["positionMeters"]) for row in camera["views"]}), 12
        )
        self.assertGreater(len({row["yawDegrees"] for row in camera["views"]}), 1)
        self.assertGreater(len({row["pitchDegrees"] for row in camera["views"]}), 1)
        self.assertEqual(scene["depthPlanesMeters"], sorted(scene["depthPlanesMeters"]))
        self.assertGreaterEqual(len(scene["depthPlanesMeters"]), 3)
        self.assertEqual(len(self.manifest["files"]), 12)

    def test_parallax_witnesses_are_pinned_projection_math(self) -> None:
        camera = self.manifest["camera"]
        views = camera["views"]
        witnesses = self.manifest["scene"]["parallaxWitnesses"]
        disparities: list[float] = []
        for witness in witnesses:
            expected = witness["viewPixels"]
            projected = [
                project(witness["worldMeters"], views[index], camera)
                for index in (0, 11)
            ]
            self.assertEqual(len(projected), len(expected))
            for actual, pinned in zip(projected, expected):
                self.assertAlmostEqual(actual[0], pinned[0], places=6)
                self.assertAlmostEqual(actual[1], pinned[1], places=6)
            disparities.append(abs(projected[0][0] - projected[1][0]))
        self.assertGreater(disparities[0], disparities[1])
        self.assertGreater(disparities[1], disparities[2])

    def test_rendering_pins_camera_bases_without_runtime_trigonometry(self) -> None:
        source = SCRIPT.read_bytes()
        tree = ast.parse(source)
        forbidden_calls = {
            node.func.attr
            for node in ast.walk(tree)
            if isinstance(node, ast.Call)
            and isinstance(node.func, ast.Attribute)
            and isinstance(node.func.value, ast.Name)
            and node.func.value.id == "math"
            and node.func.attr in {"cos", "radians", "sin"}
        }
        self.assertEqual(forbidden_calls, set())
        for view in self.manifest["camera"]["views"]:
            expected = camera_basis(view["yawDegrees"], view["pitchDegrees"])
            pinned = view["basisWorldFromCamera"]
            self.assertEqual(set(pinned), {"forward", "right", "up"})
            for key, vector in zip(("forward", "right", "up"), expected):
                self.assertEqual(len(pinned[key]), 3)
                for actual, reference in zip(pinned[key], vector):
                    self.assertAlmostEqual(actual, reference, places=15)


class GeneratedReleaseFixtureTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.temporary = tempfile.TemporaryDirectory(
            dir=os.path.realpath(tempfile.gettempdir())
        )
        cls.temp_root = Path(cls.temporary.name)
        cls.fixture = cls.temp_root / "fixture"
        run_generator("generate", "--output", os.fspath(cls.fixture))
        cls.manifest = json.loads(MANIFEST.read_text(encoding="utf-8"))

    @classmethod
    def tearDownClass(cls) -> None:
        for path in sorted(cls.temp_root.rglob("*"), reverse=True):
            if path.is_dir() and not path.is_symlink():
                path.chmod(0o700)
            elif path.exists() and not path.is_symlink():
                path.chmod(0o600)
        cls.temporary.cleanup()

    def copy_fixture(self, name: str) -> Path:
        destination = self.temp_root / name
        shutil.copytree(self.fixture, destination)
        for path in destination.rglob("*"):
            path.chmod(0o700 if path.is_dir() else 0o600)
        destination.chmod(0o700)
        return destination

    def test_generated_tree_is_exact_read_only_single_link_closure(self) -> None:
        expected = [row["path"] for row in self.manifest["files"]]
        actual = [
            path.relative_to(self.fixture).as_posix()
            for path in fixture_paths(self.fixture)
        ]
        self.assertEqual(actual, ["fixture-manifest.json", *expected])
        self.assertEqual(
            (self.fixture / "fixture-manifest.json").read_bytes(), MANIFEST.read_bytes()
        )
        self.assertEqual(stat.S_IMODE(self.fixture.lstat().st_mode), 0o555)
        self.assertEqual(stat.S_IMODE((self.fixture / "images").lstat().st_mode), 0o555)
        for path in fixture_paths(self.fixture):
            metadata = path.lstat()
            self.assertTrue(stat.S_ISREG(metadata.st_mode))
            self.assertEqual(metadata.st_nlink, 1)
            self.assertEqual(stat.S_IMODE(metadata.st_mode), 0o444)

    def test_generated_pngs_are_byte_exact_and_match_pinned_closure(self) -> None:
        aggregate = hashlib.sha256()
        aggregate.update(b"EasySplat release fixture closure v1\0")
        total = 0
        for row in self.manifest["files"]:
            relative = row["path"]
            payload = (self.fixture / relative).read_bytes()
            digest = hashlib.sha256(payload).hexdigest()
            self.assertEqual(len(payload), row["bytes"])
            self.assertEqual(digest, row["sha256"])
            total += len(payload)
            aggregate.update(relative.encode("utf-8"))
            aggregate.update(b"\0")
            aggregate.update(str(len(payload)).encode("ascii"))
            aggregate.update(b"\0")
            aggregate.update(bytes.fromhex(digest))
        self.assertEqual(total, self.manifest["totalBytes"])
        self.assertEqual(aggregate.hexdigest(), self.manifest["closureSHA256"])

    def test_generation_is_deterministic_across_independent_roots(self) -> None:
        second = self.temp_root / "fixture-second"
        run_generator("generate", "--output", os.fspath(second))
        first_paths = [
            path.relative_to(self.fixture).as_posix()
            for path in fixture_paths(self.fixture)
        ]
        second_paths = [
            path.relative_to(second).as_posix() for path in fixture_paths(second)
        ]
        self.assertEqual(first_paths, second_paths)
        for relative in first_paths:
            self.assertEqual(
                (self.fixture / relative).read_bytes(), (second / relative).read_bytes()
            )

    def test_png_format_and_pixel_diversity_are_release_suitable(self) -> None:
        image_digests: set[str] = set()
        for row in self.manifest["files"]:
            path = self.fixture / row["path"]
            header, scanlines, chunks = read_png(path)
            self.assertEqual(
                header,
                {
                    "width": 640,
                    "height": 480,
                    "bitDepth": 8,
                    "colorType": 2,
                    "compression": 0,
                    "filter": 0,
                    "interlace": 0,
                },
            )
            self.assertEqual(chunks, ["IHDR", "IDAT", "IEND"])
            stride = 1 + 640 * 3
            self.assertEqual(len(scanlines), 480 * stride)
            self.assertTrue(
                all(
                    scanlines[offset] == 0
                    for offset in range(0, len(scanlines), stride)
                )
            )
            pixels = b"".join(
                scanlines[offset + 1 : offset + stride]
                for offset in range(0, len(scanlines), stride)
            )
            colors = {pixels[index : index + 3] for index in range(0, len(pixels), 3)}
            self.assertGreater(len(colors), 8_000)
            changed = sum(
                pixels[index : index + 3] != pixels[index - 3 : index]
                for index in range(3, len(pixels), 3)
            )
            self.assertGreater(changed, 200_000)
            image_digests.add(hashlib.sha256(pixels).hexdigest())
        self.assertEqual(len(image_digests), 12)

    def test_rendered_bytes_contain_depth_ordered_cross_view_parallax(self) -> None:
        camera = self.manifest["camera"]
        views = camera["views"]
        depths = self.manifest["scene"]["depthPlanesMeters"]

        def rgb_rows(relative_path: str) -> list[list[bytes]]:
            _, scanlines, _ = read_png(self.fixture / relative_path)
            stride = 1 + 640 * 3
            return [
                [
                    scanlines[
                        row * stride + 1 + column * 3 : row * stride + 4 + column * 3
                    ]
                    for column in range(640)
                ]
                for row in range(480)
            ]

        source = rgb_rows("images/view-01.png")
        target = rgb_rows("images/view-12.png")
        sample_counts = [0, 0, 0]
        correct_matches = [0, 0, 0]
        wrong_depth_matches = [0, 0, 0]

        def window_contains(color: bytes, projected: tuple[float, float]) -> bool:
            center_x = round(projected[0] - 0.5)
            center_y = round(projected[1] - 0.5)
            if not (2 <= center_x < 638 and 2 <= center_y < 478):
                return False
            return any(
                target[row][column] == color
                for row in range(center_y - 2, center_y + 3)
                for column in range(center_x - 2, center_x + 3)
            )

        for pixel_y in range(8, 472, 7):
            for pixel_x in range(8, 632, 7):
                color = source[pixel_y][pixel_x]
                red, green, blue = color
                layer = (
                    0
                    if red > green + 28 and red > blue + 28
                    else 1
                    if green > red + 28 and green > blue + 28
                    else 2
                    if blue > red + 28 and blue > green + 28
                    else None
                )
                if layer is None:
                    continue
                world = back_project_to_depth(
                    pixel_x, pixel_y, float(depths[layer]), views[0], camera
                )
                projected = project(world, views[11], camera)
                center_x = round(projected[0] - 0.5)
                center_y = round(projected[1] - 0.5)
                if not (2 <= center_x < 638 and 2 <= center_y < 478):
                    continue
                sample_counts[layer] += 1
                correct_matches[layer] += window_contains(color, projected)

                wrong_depth = float(depths[(layer + 1) % len(depths)])
                wrong_world = back_project_to_depth(
                    pixel_x, pixel_y, wrong_depth, views[0], camera
                )
                wrong_depth_matches[layer] += window_contains(
                    color, project(wrong_world, views[11], camera)
                )

        self.assertEqual(sample_counts, [1_697, 491, 1_181])
        for layer, minimum_rate in enumerate((0.90, 0.65, 0.35)):
            with self.subTest(layer=layer):
                self.assertGreater(
                    correct_matches[layer] / sample_counts[layer], minimum_rate
                )
                self.assertLess(wrong_depth_matches[layer] / sample_counts[layer], 0.05)

    def test_verify_emits_canonical_attestation_without_private_path(self) -> None:
        attestation = self.temp_root / "fixture-attestation.json"
        result = run_generator(
            "verify",
            "--root",
            os.fspath(self.fixture),
            "--attestation",
            os.fspath(attestation),
        )
        record = json.loads(result.stdout)
        self.assertEqual(attestation.read_bytes(), canonical_json(record))
        self.assertEqual(record["schemaVersion"], 1)
        self.assertEqual(record["status"], "verified")
        self.assertEqual(record["fixtureClosureSHA256"], self.manifest["closureSHA256"])
        self.assertEqual(
            record["fixtureManifestSHA256"],
            hashlib.sha256(MANIFEST.read_bytes()).hexdigest(),
        )
        self.assertEqual(
            record["generatorSHA256"], self.manifest["provenance"]["generatorSHA256"]
        )
        self.assertNotIn(
            os.fspath(self.temp_root), attestation.read_text(encoding="utf-8")
        )
        self.assertEqual(stat.S_IMODE(attestation.lstat().st_mode), 0o600)

    def test_verify_rejects_content_inventory_and_link_tampering(self) -> None:
        mutations = ("content", "extra", "symlink", "hardlink")
        for mutation in mutations:
            with self.subTest(mutation=mutation):
                root = self.copy_fixture(f"tampered-{mutation}")
                image = root / self.manifest["files"][0]["path"]
                if mutation == "content":
                    payload = bytearray(image.read_bytes())
                    payload[-20] ^= 1
                    image.write_bytes(payload)
                elif mutation == "extra":
                    (root / "images/extra.png").write_bytes(b"unexpected")
                elif mutation == "symlink":
                    image.unlink()
                    image.symlink_to("view-02.png")
                else:
                    image.unlink()
                    os.link(root / self.manifest["files"][1]["path"], image)
                for candidate in root.rglob("*"):
                    if candidate.is_symlink():
                        continue
                    candidate.chmod(0o555 if candidate.is_dir() else 0o444)
                root.chmod(0o555)
                result = run_generator(
                    "verify", "--root", os.fspath(root), expect_success=False
                )
                self.assertRegex(
                    result.stderr.lower(), "changed|closure|inventory|link|regular"
                )

    def test_verify_rejects_oversized_sparse_file_before_reading_without_mutation(
        self,
    ) -> None:
        root = self.copy_fixture("tampered-oversized")
        image = root / self.manifest["files"][0]["path"]
        neighbor = root / self.manifest["files"][1]["path"]
        expected_size = int(self.manifest["files"][0]["bytes"])
        sparse_size = 8 * 1024 * 1024 * 1024
        neighbor_digest = hashlib.sha256(neighbor.read_bytes()).hexdigest()
        with image.open("r+b") as handle:
            handle.truncate(sparse_size)
        for candidate in root.rglob("*"):
            candidate.chmod(0o555 if candidate.is_dir() else 0o444)
        root.chmod(0o555)

        identity_fields = (
            "st_dev",
            "st_ino",
            "st_mode",
            "st_nlink",
            "st_size",
            "st_mtime_ns",
            "st_ctime_ns",
        )
        before = image.lstat()
        before_identity = tuple(getattr(before, field) for field in identity_fields)
        before_inventory = [
            path.relative_to(root).as_posix() for path in fixture_paths(root)
        ]
        attestation = self.temp_root / "oversized-attestation.json"

        result = run_generator(
            "verify",
            "--root",
            os.fspath(root),
            "--attestation",
            os.fspath(attestation),
            expect_success=False,
        )

        self.assertIn(
            f"expected {expected_size} bytes, found {sparse_size}", result.stderr
        )
        after = image.lstat()
        self.assertEqual(
            tuple(getattr(after, field) for field in identity_fields), before_identity
        )
        self.assertEqual(
            hashlib.sha256(neighbor.read_bytes()).hexdigest(), neighbor_digest
        )
        self.assertEqual(
            [path.relative_to(root).as_posix() for path in fixture_paths(root)],
            before_inventory,
        )
        self.assertFalse(attestation.exists())
        self.assertFalse(
            any("staging" in path.name for path in self.temp_root.iterdir())
        )

    def test_generation_refuses_existing_relative_and_symlink_unsafe_outputs(
        self,
    ) -> None:
        existing_empty = self.temp_root / "existing-empty"
        existing_empty.mkdir()
        existing_nonempty = self.temp_root / "existing-nonempty"
        existing_nonempty.mkdir()
        sentinel = existing_nonempty / "sentinel"
        sentinel.write_text("preserve\n", encoding="utf-8")
        existing_file = self.temp_root / "existing-file"
        existing_file.write_text("preserve\n", encoding="utf-8")
        symlink_output = self.temp_root / "symlink-output"
        symlink_output.symlink_to(existing_empty, target_is_directory=True)
        real_parent = self.temp_root / "real-parent"
        real_parent.mkdir()
        alias_parent = self.temp_root / "alias-parent"
        alias_parent.symlink_to(real_parent, target_is_directory=True)
        unsafe = (
            Path("relative-fixture"),
            existing_empty,
            existing_nonempty,
            existing_file,
            symlink_output,
            alias_parent / "fixture",
            self.temp_root / "real-parent/../normalized-away",
        )
        for output in unsafe:
            with self.subTest(output=output):
                run_generator(
                    "generate", "--output", os.fspath(output), expect_success=False
                )
        self.assertEqual(sentinel.read_text(encoding="utf-8"), "preserve\n")
        self.assertEqual(existing_file.read_text(encoding="utf-8"), "preserve\n")
        self.assertEqual(list(real_parent.iterdir()), [])
        self.assertFalse((self.temp_root / "normalized-away").exists())
        self.assertFalse(
            any("staging" in path.name for path in self.temp_root.iterdir()),
            "failed generation left a staging tree",
        )

    def test_generation_failure_never_publishes_partial_output(self) -> None:
        copied_release = self.temp_root / "copied-release"
        copied_release.mkdir()
        copied_script = copied_release / SCRIPT.name
        copied_manifest = copied_release / MANIFEST.name
        shutil.copy2(SCRIPT, copied_script)
        shutil.copy2(MANIFEST, copied_manifest)
        copied_manifest.write_text("{}\n", encoding="utf-8")
        output = self.temp_root / "partial-output"
        result = subprocess.run(
            [
                sys.executable,
                "-I",
                os.fspath(copied_script),
                "generate",
                "--output",
                os.fspath(output),
            ],
            check=False,
            capture_output=True,
            text=True,
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(output.exists())
        self.assertFalse(
            any("staging" in path.name for path in self.temp_root.iterdir())
        )


class ReleaseFixtureIntegrationContractTests(unittest.TestCase):
    def test_packaged_validators_require_the_input_manifest_argument(self) -> None:
        packaged_smoke = RELEASE_DIR / "lib/packaged_app_bootstrap_smoke.sh"
        cases = (
            (
                "packaged_app_attestation_snapshot",
                10,
                "Packaged attestation validation requires an input manifest.",
            ),
            (
                "validate_packaged_app_bootstrap_result",
                9,
                "Packaged app bootstrap validation requires an input manifest.",
            ),
        )
        for function, argument_count, expected_error in cases:
            with self.subTest(function=function):
                result = subprocess.run(
                    [
                        "/bin/bash",
                        "-c",
                        f'source "$1"; shift; {function} "$@"',
                        "bash",
                        os.fspath(packaged_smoke),
                        *(["missing"] * argument_count),
                    ],
                    check=False,
                    capture_output=True,
                    text=True,
                )
                self.assertNotEqual(result.returncode, 0)
                self.assertIn(expected_error, result.stderr)

    def test_packaged_validators_have_no_digest_optional_marker_path(self) -> None:
        source = (RELEASE_DIR / "lib/packaged_app_bootstrap_smoke.sh").read_text(
            encoding="utf-8"
        )
        for legacy_fragment in (
            "len(sys.argv) not in (11, 12)",
            "if input_manifest_data is not None",
            'input_manifest_path=${10:-}',
            "if input_manifest_path is not None",
            "Legacy packaged marker unexpectedly binds an input manifest.",
        ):
            with self.subTest(fragment=legacy_fragment):
                self.assertNotIn(legacy_fragment, source)

    def test_workflow_generates_once_per_host_without_repository_variable(self) -> None:
        workflow = (
            RELEASE_DIR.parents[1] / ".github/workflows/release-app.yml"
        ).read_text(encoding="utf-8")
        self.assertNotIn("vars.EASYSPLAT_RELEASE_FIXTURE", workflow)
        self.assertNotIn("RELEASE_FIXTURE:", workflow)
        self.assertEqual(workflow.count('generate_release_fixture.py" generate \\'), 2)
        self.assertEqual(workflow.count('generate_release_fixture.py" verify \\'), 2)
        self.assertEqual(workflow.count('--fixture "$FIXTURE_ROOT" \\'), 2)
        self.assertEqual(
            workflow.count('FIXTURE_ROOT="$RUNNER_TEMP/easysplat-release-fixture"'), 2
        )

    def test_release_verifier_rechecks_one_media_closure_and_binds_evidence(self) -> None:
        source = (RELEASE_DIR / "verify_release.sh").read_text(encoding="utf-8")
        calls = [
            line.strip()
            for line in source.splitlines()
            if line.strip() == "assert_release_fixture_unchanged"
        ]
        self.assertEqual(len(calls), 8)
        self.assertEqual(source.count('--input-manifest "$E2E_INPUT_MANIFEST" \\'), 3)
        self.assertEqual(source.count('--input-root "$E2E_FIXTURE" \\'), 3)
        self.assertIn('run_packaged_app_bootstrap_smoke "$E2E_FIXTURE_MEDIA"', source)
        self.assertIn("EASYSPLAT_RELEASE_FIXTURE is forbidden", source)
        self.assertIn("release-fixture-attestation.json", source)
        self.assertIn("Release fixture manifest SHA-256: ", source)
        self.assertIn("Release fixture generator SHA-256: ", source)
        self.assertIn("Release fixture closure SHA-256: ", source)
        self.assertIn(
            "Generated release fixture must be disjoint from evidence, app, repository, and toolchain roots.",
            source,
        )

    def test_release_gates_exercise_generator_and_forbid_legacy_input(self) -> None:
        workflow_check = (RELEASE_DIR.parents[0] / "ci/check_workflows.sh").read_text(
            encoding="utf-8"
        )
        release_tests = (
            RELEASE_DIR.parents[0] / "ci/test_release_scripts.sh"
        ).read_text(encoding="utf-8")
        readme = (RELEASE_DIR.parents[1] / "README.md").read_text(encoding="utf-8")
        self.assertIn(
            "must not depend on a caller or repository fixture variable", workflow_check
        )
        self.assertIn("test_generate_release_fixture.py", release_tests)
        self.assertNotIn("release-verifier-fixture.mov", release_tests)
        self.assertEqual(
            release_tests.count(
                'generate_release_fixture.py" generate \\\n  --output "$fixture"'
            ),
            1,
        )
        self.assertIn(
            'chmod -R u+w "$release_fixture_root"',
            release_tests,
        )
        self.assertIn("EASYSPLAT_RELEASE_FIXTURE is forbidden", release_tests)
        self.assertIn("Fixture reproducibility proves input integrity only.", readme)
        self.assertIn("at least 11 of 12 views plus native msplat training", readme)


if __name__ == "__main__":
    unittest.main()
