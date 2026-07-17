from __future__ import annotations

import hashlib
import json
import os
import platform
import stat
import struct
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

import numpy
from PIL import Image, ImageCms


ROOT = Path(__file__).resolve().parents[3]
SCRIPT = ROOT / "scripts" / "benchmark" / "prepare_render_targets.py"
FISHTANK_CAMERA = {
    "model": "SIMPLE_RADIAL",
    "width": 1600,
    "height": 900,
    "parameters": [
        1389.4478870572798,
        800.0,
        450.0,
        -0.019153315980710926,
    ],
}


def sha256(path: Path) -> str:
    return "sha256:" + hashlib.sha256(path.read_bytes()).hexdigest()


def canonical_bytes(value: object) -> bytes:
    return (
        json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=False)
        + "\n"
    ).encode("utf-8")


def projection(width: int, height: int, fx: float, fy: float, cx: float, cy: float) -> list[float]:
    return [
        2.0 * fx / width,
        0.0,
        0.0,
        0.0,
        0.0,
        2.0 * fy / height,
        0.0,
        0.0,
        1.0 - 2.0 * cx / width,
        2.0 * cy / height - 1.0,
        -1.0002000331878662,
        -1.0,
        0.0,
        0.0,
        -0.020002000033855438,
        0.0,
    ]


def render_camera(width: int, height: int, fx: float, fy: float, cx: float, cy: float) -> dict[str, object]:
    return {
        "width": width,
        "height": height,
        "projection_matrix_column_major": projection(width, height, fx, fy, cx, cy),
        "world_to_camera_matrix_column_major": [
            1.0,
            0.0,
            0.0,
            0.0,
            0.0,
            1.0,
            0.0,
            0.0,
            0.0,
            0.0,
            1.0,
            0.0,
            0.0,
            0.0,
            0.0,
            1.0,
        ],
    }


class RenderTargetPreparationTests(unittest.TestCase):
    def run_helper(
        self,
        root: Path,
        spec: dict[str, object],
        *,
        expect_success: bool = True,
        expect_target_absent: bool = True,
        native_helper: Path | None = None,
    ) -> subprocess.CompletedProcess[str]:
        helper = native_helper or self.make_native_helper(root)
        spec_path = root / "render-target-spec.json"
        spec_path.write_bytes(canonical_bytes(spec))
        result = subprocess.run(
            [
                sys.executable,
                str(SCRIPT),
                "--artifact-root",
                str(root),
                "--spec",
                str(spec_path),
                "--output",
                str(root / "ground-truth-preparation.json"),
                "--native-helper",
                str(helper),
            ],
            cwd=ROOT,
            check=False,
            capture_output=True,
            text=True,
        )
        if expect_success:
            self.assertEqual(result.returncode, 0, result.stderr)
        else:
            self.assertNotEqual(result.returncode, 0, result.stdout)
            self.assertFalse((root / "ground-truth-preparation.json").exists())
            if expect_target_absent:
                self.assertFalse((root / "rendering" / "ground-truth").exists())
        return result

    def make_native_helper(self, root: Path) -> Path:
        helper_root = root / "native-helper"
        helper_root.mkdir(exist_ok=True)
        helper = helper_root / "easysplat-train"
        metallib = helper_root / "default.metallib"
        helper.write_text(
            """#!/usr/bin/env python3
import argparse, hashlib, json, os, struct
from pathlib import Path
from PIL import Image

def content(path):
    return path.read_bytes()

def sha(data):
    return "sha256:" + hashlib.sha256(data).hexdigest()

def build_digest(root):
    digest = hashlib.sha256(b"EasySplat file digest v1")
    for name in ("easysplat-train", "default.metallib"):
        data = content(root / name)
        encoded = name.encode()
        digest.update(struct.pack(">Q", len(encoded)))
        digest.update(encoded)
        digest.update(struct.pack(">Q", len(data)))
        digest.update(data)
    return "sha256:" + digest.hexdigest()

parser = argparse.ArgumentParser()
parser.add_argument("--benchmark-decode", required=True)
parser.add_argument("--benchmark-decode-output", required=True)
args = parser.parse_args()
source = Path(args.benchmark_decode)
output = Path(args.benchmark_decode_output)
with Image.open(source) as image:
    image.load()
    rgb = image.convert("RGB")
    pixels = rgb.tobytes()
    width, height = rgb.size
descriptor = os.open(output, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
with os.fdopen(descriptor, "wb") as handle:
    handle.write(pixels)
    handle.flush()
    os.fsync(handle.fileno())
root = Path(__file__).resolve().parent
executable = content(Path(__file__))
metal = content(root / "default.metallib")
source_bytes = content(source)
print(json.dumps({
    "contract": "native_coregraphics_imageio_rgb8_v1",
    "executable_bytes": len(executable),
    "executable_sha256": sha(executable),
    "height": height,
    "metallib_bytes": len(metal),
    "metallib_sha256": sha(metal),
    "mode": "benchmark_decode",
    "mode_version": 1,
    "msplat_source_commit": "106499b0a53f82b0c92d013b0861fbebd341b17e",
    "output_bytes": len(pixels),
    "output_sha256": sha(pixels),
    "pixel_sha256": sha(pixels),
    "schema_version": 1,
    "source_bytes": len(source_bytes),
    "source_sha256": sha(source_bytes),
    "status": "completed",
    "trainer_build_digest": build_digest(root),
    "width": width,
}, sort_keys=True, separators=(",", ":")))
""",
            encoding="utf-8",
        )
        helper.chmod(stat.S_IRUSR | stat.S_IWUSR | stat.S_IXUSR)
        metallib.write_bytes(b"fixture metallib")
        return helper

    def native_identity(self, helper: Path) -> dict[str, object]:
        executable = helper.read_bytes()
        metallib = (helper.parent / "default.metallib").read_bytes()
        digest = hashlib.sha256(b"EasySplat file digest v1")
        for name, data in (("easysplat-train", executable), ("default.metallib", metallib)):
            encoded = name.encode()
            digest.update(struct.pack(">Q", len(encoded)))
            digest.update(encoded)
            digest.update(struct.pack(">Q", len(data)))
            digest.update(data)
        return {
            "contract": "native_coregraphics_imageio_rgb8_v1",
            "mode_version": 1,
            "executable_bytes": len(executable),
            "executable_sha256": "sha256:" + hashlib.sha256(executable).hexdigest(),
            "metallib_bytes": len(metallib),
            "metallib_sha256": "sha256:" + hashlib.sha256(metallib).hexdigest(),
            "trainer_build_digest": "sha256:" + digest.hexdigest(),
            "msplat_source_commit": "106499b0a53f82b0c92d013b0861fbebd341b17e",
        }

    def mutating_native_helper(self, root: Path, statement: str) -> Path:
        helper = self.make_native_helper(root)
        source = helper.read_text(encoding="utf-8")
        helper.write_text(
            source.replace("print(json.dumps({", statement + "\nprint(json.dumps({", 1),
            encoding="utf-8",
        )
        helper.chmod(stat.S_IRUSR | stat.S_IWUSR | stat.S_IXUSR)
        return helper

    def direct_native_decode(self, helper: Path, source: Path, output: Path) -> dict[str, object]:
        completed = subprocess.run(
            [
                str(helper),
                "--benchmark-decode",
                str(source),
                "--benchmark-decode-output",
                str(output),
            ],
            cwd=helper.parent,
            check=False,
            capture_output=True,
            text=True,
        )
        self.assertEqual(completed.returncode, 0, completed.stderr)
        self.assertEqual(completed.stderr, "")
        return json.loads(completed.stdout)

    def make_source(
        self,
        root: Path,
        *,
        size: tuple[int, int] = (64, 64),
        image_format: str = "PNG",
    ) -> Path:
        source = root / "rendering" / "source" / (
            "holdout.jpg" if image_format == "JPEG" else "holdout.png"
        )
        source.parent.mkdir(parents=True, exist_ok=True)
        width, height = size
        columns = numpy.arange(width, dtype=numpy.uint16)[None, :]
        rows = numpy.arange(height, dtype=numpy.uint16)[:, None]
        pixels = numpy.empty((height, width, 3), dtype=numpy.uint8)
        pixels[:, :, 0] = (columns * 3 + rows * 5) % 256
        pixels[:, :, 1] = (columns * 7 + rows * 11) % 256
        pixels[:, :, 2] = (columns * 13 + rows * 17) % 256
        Image.fromarray(pixels, mode="RGB").save(source, format=image_format)
        return source

    def make_spec(
        self,
        root: Path,
        source: Path,
        source_camera: dict[str, object],
        target_camera: dict[str, object],
        *,
        native_helper: Path | None = None,
    ) -> dict[str, object]:
        relative = source.relative_to(root).as_posix()
        source_format = "jpeg_rgb8" if source.suffix.lower() == ".jpg" else "png_rgb8"
        selection = root / "selection-manifest.json"
        selection.write_bytes(
            canonical_bytes(
                {
                    "schema_version": 1,
                    "views": [
                        {"view_index": 4, "clip_id": "clip-0", "source_kind": "photo"}
                    ],
                }
            )
        )
        helper = native_helper or self.make_native_helper(root)
        return {
            "schema_version": 2,
            "input_digest": "sha256:" + "1" * 64,
            "selection_manifest": {
                "path": "selection-manifest.json",
                "sha256": sha256(selection),
            },
            "producer": {
                "path": "scripts/benchmark/prepare_render_targets.py",
                "sha256": sha256(SCRIPT),
            },
            "native_decoder": self.native_identity(helper),
            "runtime": {
                "implementation": platform.python_implementation().lower(),
                "python_version": platform.python_version(),
                "numpy_version": numpy.__version__,
                "pillow_version": Image.__version__,
            },
            "views": [
                {
                    "holdout_index": 4,
                    "source": {
                        "path": relative,
                        "sha256": sha256(source),
                        "format": source_format,
                        "width": source_camera["width"],
                        "height": source_camera["height"],
                    },
                    "source_camera": source_camera,
                    "render_camera": target_camera,
                    "target_path": "rendering/ground-truth/000004.png",
                }
            ],
        }

    def test_matches_native_msplat_simple_radial_crop_and_intrinsics(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = self.make_source(root, size=(1600, 900), image_format="JPEG")
            expected_parameters = [1389.4478870572798, 1389.4478870572798, 800.0, 450.0]
            spec = self.make_spec(
                root,
                source,
                FISHTANK_CAMERA,
                render_camera(1600, 899, *expected_parameters),
            )

            self.run_helper(root, spec)

            receipt = json.loads((root / "ground-truth-preparation.json").read_text())
            view = receipt["views"][0]
            self.assertEqual(receipt["schema_version"], 2)
            self.assertEqual(view["transform"]["roi"], [0, 0, 1600, 899])
            self.assertEqual(view["target"]["width"], 1600)
            self.assertEqual(view["target"]["height"], 899)
            self.assertEqual(view["target_camera"]["model"], "PINHOLE")
            self.assertEqual(view["target_camera"]["parameters"], expected_parameters)
            with Image.open(root / view["target"]["path"]) as output:
                self.assertEqual(output.mode, "RGB")
                self.assertEqual(output.size, (1600, 899))

    def test_normalizes_pinhole_without_changing_pixels(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = self.make_source(root)
            source_camera = {
                "model": "PINHOLE",
                "width": 64,
                "height": 64,
                "parameters": [52.0, 51.0, 31.5, 32.0],
            }
            spec = self.make_spec(
                root,
                source,
                source_camera,
                render_camera(64, 64, 52.0, 51.0, 31.5, 32.0),
            )

            self.run_helper(root, spec)

            receipt = json.loads((root / "ground-truth-preparation.json").read_text())
            view = receipt["views"][0]
            self.assertEqual(view["transform"], {"kind": "identity", "roi": [0, 0, 64, 64]})
            self.assertEqual(
                view["target_camera"],
                {
                    "model": "PINHOLE",
                    "width": 64,
                    "height": 64,
                    "parameters": [52.0, 51.0, 31.5, 32.0],
                },
            )
            with Image.open(source) as expected, Image.open(root / view["target"]["path"]) as actual:
                self.assertEqual(actual.convert("RGB").tobytes(), expected.convert("RGB").tobytes())

    def test_rejects_unsupported_camera_model_without_partial_outputs(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = self.make_source(root)
            source_camera = {
                "model": "OPENCV_FISHEYE",
                "width": 64,
                "height": 64,
                "parameters": [52.0, 51.0, 31.5, 32.0, 0.1, 0.0, 0.0, 0.0],
            }
            spec = self.make_spec(root, source, source_camera, render_camera(64, 64, 52, 51, 31.5, 32))

            result = self.run_helper(root, spec, expect_success=False)

            self.assertIn("unsupported camera model", result.stderr.lower())

    def test_rejects_corrupt_digest_and_dimension_mismatches(self) -> None:
        mutations = {
            "corrupt": lambda root, source, spec: source.write_bytes(b"not an image"),
            "digest": lambda root, source, spec: spec["views"][0]["source"].update(
                {"sha256": "sha256:" + "0" * 64}
            ),
            "dimension": lambda root, source, spec: spec["views"][0]["source"].update(
                {"width": 65}
            ),
        }
        for label, mutate in mutations.items():
            with self.subTest(label=label), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                source = self.make_source(root)
                source_camera = {
                    "model": "SIMPLE_PINHOLE",
                    "width": 64,
                    "height": 64,
                    "parameters": [52.0, 31.5, 32.0],
                }
                spec = self.make_spec(
                    root,
                    source,
                    source_camera,
                    render_camera(64, 64, 52.0, 52.0, 31.5, 32.0),
                )
                mutate(root, source, spec)

                self.run_helper(root, spec, expect_success=False)

    def test_rejects_symlinked_sources_and_output_collisions(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            outside = root / "outside.png"
            Image.new("RGB", (64, 64), (1, 2, 3)).save(outside)
            linked = root / "rendering" / "source" / "holdout.png"
            linked.parent.mkdir(parents=True)
            linked.symlink_to(outside)
            source_camera = {
                "model": "PINHOLE",
                "width": 64,
                "height": 64,
                "parameters": [52.0, 52.0, 31.5, 32.0],
            }
            spec = self.make_spec(
                root,
                linked,
                source_camera,
                render_camera(64, 64, 52.0, 52.0, 31.5, 32.0),
            )

            result = self.run_helper(root, spec, expect_success=False)
            self.assertIn("symbolic link", result.stderr.lower())

        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = self.make_source(root)
            source_camera = {
                "model": "PINHOLE",
                "width": 64,
                "height": 64,
                "parameters": [52.0, 52.0, 31.5, 32.0],
            }
            spec = self.make_spec(
                root,
                source,
                source_camera,
                render_camera(64, 64, 52.0, 52.0, 31.5, 32.0),
            )
            (root / "rendering" / "ground-truth").mkdir(parents=True)

            result = self.run_helper(
                root,
                spec,
                expect_success=False,
                expect_target_absent=False,
            )
            self.assertIn("already exists", result.stderr.lower())

    def test_is_byte_reproducible_across_artifact_roots(self) -> None:
        outputs: list[tuple[bytes, bytes]] = []
        for _ in range(2):
            with tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                source = self.make_source(root)
                source_camera = {
                    "model": "SIMPLE_PINHOLE",
                    "width": 64,
                    "height": 64,
                    "parameters": [52.0, 31.5, 32.0],
                }
                spec = self.make_spec(
                    root,
                    source,
                    source_camera,
                    render_camera(64, 64, 52.0, 52.0, 31.5, 32.0),
                )
                self.run_helper(root, spec)
                outputs.append(
                    (
                        (root / "ground-truth-preparation.json").read_bytes(),
                        (root / "rendering" / "ground-truth" / "000004.png").read_bytes(),
                    )
                )

        self.assertEqual(outputs[0], outputs[1])

    def test_matches_native_msplat_cross_check_fixture(self) -> None:
        fixture_path = ROOT / "scripts" / "benchmark" / "fixtures" / "msplat-render-target-cross-check.json"
        fixture = json.loads(fixture_path.read_text(encoding="utf-8"))
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = self.make_source(
                root,
                size=(fixture["source_camera"]["width"], fixture["source_camera"]["height"]),
            )
            spec = self.make_spec(
                root,
                source,
                fixture["source_camera"],
                fixture["render_camera"],
            )

            self.run_helper(root, spec)

            receipt = json.loads((root / "ground-truth-preparation.json").read_text())
            view = receipt["views"][0]
            self.assertEqual(
                view["source"]["pixel_sha256"],
                fixture["expected_source_pixel_sha256"],
            )
            self.assertEqual(view["transform"]["roi"], fixture["expected_roi"])
            self.assertEqual(view["target_camera"], fixture["expected_target_camera"])
            self.assertEqual(view["target"]["pixel_sha256"], fixture["expected_pixel_sha256"])

    def test_float32_zero_radial_coefficients_are_identity(self) -> None:
        for coefficient in (0.0, -0.0, 1e-50, -1e-50):
            with self.subTest(coefficient=coefficient), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                source = self.make_source(root)
                source_camera = {
                    "model": "SIMPLE_RADIAL",
                    "width": 64,
                    "height": 64,
                    "parameters": [52.0, 31.5, 32.0, coefficient],
                }
                spec = self.make_spec(
                    root,
                    source,
                    source_camera,
                    render_camera(64, 64, 52.0, 52.0, 31.5, 32.0),
                )

                self.run_helper(root, spec)

                receipt = json.loads((root / "ground-truth-preparation.json").read_text())
                view = receipt["views"][0]
                self.assertEqual(view["transform"], {"kind": "identity", "roi": [0, 0, 64, 64]})
                self.assertEqual(view["source"]["pixel_sha256"], view["target"]["pixel_sha256"])

    def test_native_decoder_pixel_parity_for_png_jpeg_icc_and_exif(self) -> None:
        native = ROOT / "Toolchains" / "build" / "msplat" / "native-build" / "msplat"
        if not native.is_file() or not os.access(native, os.X_OK):
            self.skipTest("native msplat build is unavailable")
        srgb = ImageCms.ImageCmsProfile(ImageCms.createProfile("sRGB")).tobytes()
        cases = {
            "plain_png": ("PNG", {}),
            "subsampled_jpeg": ("JPEG", {"quality": 83, "subsampling": 2}),
            "icc_png": ("PNG", {"icc_profile": srgb}),
            "icc_jpeg": ("JPEG", {"quality": 87, "subsampling": 2, "icc_profile": srgb}),
            "exif_orientation": (
                "JPEG",
                {"quality": 91, "subsampling": 2, "exif": Image.Exif()},
            ),
        }
        cases["exif_orientation"][1]["exif"][274] = 6
        for label, (image_format, options) in cases.items():
            with self.subTest(label=label), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                source = self.make_source(root, image_format=image_format)
                with Image.open(source) as image:
                    image.save(source, format=image_format, **options)
                direct_output = root / "direct.rgb8"
                native_receipt = self.direct_native_decode(native, source, direct_output)
                width = native_receipt["width"]
                height = native_receipt["height"]
                camera_model = {
                    "model": "PINHOLE",
                    "width": width,
                    "height": height,
                    "parameters": [52.0, 51.0, width / 2, height / 2],
                }
                spec = self.make_spec(
                    root,
                    source,
                    camera_model,
                    render_camera(width, height, 52.0, 51.0, width / 2, height / 2),
                    native_helper=native,
                )

                self.run_helper(root, spec, native_helper=native)

                preparation = json.loads((root / "ground-truth-preparation.json").read_text())
                prepared_source = preparation["views"][0]["source"]
                self.assertEqual(prepared_source["pixel_sha256"], native_receipt["pixel_sha256"])
                self.assertEqual(
                    prepared_source["native_decoded_rgb8_sha256"],
                    native_receipt["pixel_sha256"],
                )

    def test_rejects_symlinked_caller_root_spec_and_output_parent(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            parent = Path(directory)
            real_root = parent / "real"
            real_root.mkdir()
            linked_root = parent / "linked"
            linked_root.symlink_to(real_root, target_is_directory=True)
            helper = self.make_native_helper(real_root)
            result = subprocess.run(
                [
                    sys.executable,
                    str(SCRIPT),
                    "--artifact-root",
                    str(linked_root),
                    "--spec",
                    str(linked_root / "render-target-spec.json"),
                    "--output",
                    str(linked_root / "ground-truth-preparation.json"),
                    "--native-helper",
                    str(helper),
                ],
                cwd=ROOT,
                check=False,
                capture_output=True,
                text=True,
            )
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("caller-supplied real directory", result.stderr)

        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = self.make_source(root)
            camera_model = {
                "model": "PINHOLE",
                "width": 64,
                "height": 64,
                "parameters": [52.0, 51.0, 31.5, 32.0],
            }
            spec = self.make_spec(
                root,
                source,
                camera_model,
                render_camera(64, 64, 52.0, 51.0, 31.5, 32.0),
            )
            real_spec = root / "real-spec.json"
            real_spec.write_bytes(canonical_bytes(spec))
            linked_spec = root / "render-target-spec.json"
            linked_spec.symlink_to(real_spec)
            result = self.run_helper(root, spec, expect_success=False)
            self.assertIn("symbolic link", result.stderr.lower())

        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = self.make_source(root)
            camera_model = {
                "model": "PINHOLE",
                "width": 64,
                "height": 64,
                "parameters": [52.0, 51.0, 31.5, 32.0],
            }
            spec = self.make_spec(
                root,
                source,
                camera_model,
                render_camera(64, 64, 52.0, 51.0, 31.5, 32.0),
            )
            spec_path = root / "render-target-spec.json"
            spec_path.write_bytes(canonical_bytes(spec))
            alias = root / "output-parent"
            alias.symlink_to(root, target_is_directory=True)
            helper = self.make_native_helper(root)
            result = subprocess.run(
                [
                    sys.executable,
                    str(SCRIPT),
                    "--artifact-root",
                    str(root),
                    "--spec",
                    str(spec_path),
                    "--output",
                    str(alias / "ground-truth-preparation.json"),
                    "--native-helper",
                    str(helper),
                ],
                cwd=ROOT,
                check=False,
                capture_output=True,
                text=True,
            )
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("canonical", result.stderr.lower())

    def test_detects_bound_input_mutation_and_mid_transaction_root_swap(self) -> None:
        for label, statement in (
            (
                "selection",
                "Path(%r).write_text('mutated', encoding='utf-8')",
            ),
            (
                "spec",
                "Path(%r).write_text('mutated', encoding='utf-8')",
            ),
            (
                "source",
                "Path(%r).write_bytes(b'mutated')",
            ),
        ):
            with self.subTest(label=label), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                source = self.make_source(root)
                camera_model = {
                    "model": "PINHOLE",
                    "width": 64,
                    "height": 64,
                    "parameters": [52.0, 51.0, 31.5, 32.0],
                }
                target = {
                    "selection": root / "selection-manifest.json",
                    "spec": root / "render-target-spec.json",
                    "source": source,
                }[label]
                helper = self.mutating_native_helper(root, statement % str(target))
                spec = self.make_spec(
                    root,
                    source,
                    camera_model,
                    render_camera(64, 64, 52.0, 51.0, 31.5, 32.0),
                    native_helper=helper,
                )
                self.run_helper(
                    root,
                    spec,
                    expect_success=False,
                    native_helper=helper,
                )

        with tempfile.TemporaryDirectory() as directory:
            parent = Path(directory)
            root = parent / "artifacts"
            root.mkdir()
            source = self.make_source(root)
            moved = parent / "moved-artifacts"
            outside = parent / "outside"
            outside.mkdir()
            statement = (
                f"os.rename({str(root)!r}, {str(moved)!r}); "
                f"os.symlink({str(outside)!r}, {str(root)!r})"
            )
            helper = self.mutating_native_helper(root, statement)
            camera_model = {
                "model": "PINHOLE",
                "width": 64,
                "height": 64,
                "parameters": [52.0, 51.0, 31.5, 32.0],
            }
            spec = self.make_spec(
                root,
                source,
                camera_model,
                render_camera(64, 64, 52.0, 51.0, 31.5, 32.0),
                native_helper=helper,
            )
            self.run_helper(
                root,
                spec,
                expect_success=False,
                native_helper=helper,
            )
            self.assertFalse((outside / "ground-truth-preparation.json").exists())
            self.assertFalse((outside / "rendering" / "ground-truth").exists())


if __name__ == "__main__":
    unittest.main()
