from __future__ import annotations

import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path, PurePosixPath
from unittest import mock

from PIL import Image


ROOT = Path(__file__).resolve().parents[3]
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))

from scripts.benchmark import evidence_protocol as evidence  # noqa: E402


HOLDOUTS = [4, 9]
VARIANTS = [
    "accurate_reference",
    "paired_baseline",
    "candidate_balanced",
    "candidate_fast",
]
RENDERER_SHA256 = "sha256:" + "e" * 64
RENDERER_CLOSURE_SHA256 = "sha256:" + "f" * 64


def camera(index: int) -> dict[str, object]:
    return {
        "width": 64,
        "height": 64,
        "projection_matrix_column_major": [
            1.0, 0.0, 0.0, 0.0,
            0.0, 1.0, 0.0, 0.0,
            0.0, 0.0, 1.0, 0.0,
            0.0, 0.0, 0.0, 1.0,
        ],
        "world_to_camera_matrix_column_major": [
            1.0, 0.0, 0.0, 0.0,
            0.0, 1.0, 0.0, 0.0,
            0.0, 0.0, 1.0, 0.0,
            float(index), 0.0, 0.0, 1.0,
        ],
    }


def write_png(path: Path, value: int) -> str:
    path.parent.mkdir(parents=True, exist_ok=True)
    Image.new("RGB", (64, 64), (value, value, value)).save(path, format="PNG")
    return evidence.sha256_file(path)


def request() -> dict[str, object]:
    return {
        "binding": {
            "scene_id": "orbit-01",
            "scale": 12,
            "input_digest": "sha256:" + "1" * 64,
        },
        "holdout_indices": HOLDOUTS,
        "rendering_driver_identity": {
            "sha256": RENDERER_CLOSURE_SHA256,
        },
    }


def commands() -> list[dict[str, object]]:
    specs = [
        ("baseline-run", "ordinary", "baseline", "a"),
        ("candidate-run", "ordinary", "candidate", "b"),
        ("reference-run", "fast_profile", "accurate_reference", "c"),
        ("fast-run", "fast_profile", "fast_candidate", "d"),
    ]
    return [
        {
            "run_id": run_id,
            "phase": phase,
            "variant": variant,
            "output_sha256": "sha256:" + character * 64,
            "checkout_commit": character * 40,
            "toolchain_identity": "sha256:" + character * 64,
            "executable_sha256": "sha256:" + character * 64,
            "published_output": run_id == "candidate-run",
        }
        for run_id, phase, variant, character in specs
    ]


def write_render_closure(root: Path) -> tuple[dict[str, object], Path]:
    req = request()
    request_digest = evidence.sha256_bytes(evidence.canonical_json_bytes(req) + b"\n")
    command_by_variant = {
        "paired_baseline": commands()[0],
        "candidate_balanced": commands()[1],
        "accurate_reference": commands()[2],
        "candidate_fast": commands()[3],
    }
    reference_views = []
    manifest_views = []
    render_operations = []
    for view_offset, holdout_index in enumerate(HOLDOUTS):
        camera_record = camera(holdout_index)
        camera_digest = evidence.sha256_bytes(evidence.canonical_json_bytes(camera_record))
        ground_truth_path = Path("rendering") / "ground-truth" / f"{holdout_index:06d}.png"
        ground_truth_sha = write_png(root / ground_truth_path, 64 + view_offset)
        reference_views.append(
            {
                "holdout_index": holdout_index,
                "camera": camera_record,
                "camera_digest": camera_digest,
                "ground_truth_sha256": ground_truth_sha,
            }
        )
        rendered = []
        for variant_offset, variant in enumerate(VARIANTS):
            path = Path("rendering") / variant / f"{holdout_index:06d}.png"
            digest = write_png(root / path, 64 + view_offset + variant_offset)
            receipt = command_by_variant[variant]
            operation_id = f"render-{holdout_index:06d}-{variant}"
            rendered.append(
                {
                    "variant": variant,
                    "path": path.as_posix(),
                    "sha256": digest,
                    "camera_digest": camera_digest,
                    "source_run_id": receipt["run_id"],
                    "ply_sha256": receipt["output_sha256"],
                    "renderer": "MetalSplatter",
                    "renderer_executable_sha256": RENDERER_SHA256,
                    "render_operation_id": operation_id,
                }
            )
            render_operations.append(
                {
                    "operation_id": operation_id,
                    "holdout_index": holdout_index,
                    "variant": variant,
                    "renderer_executable_sha256": RENDERER_SHA256,
                    "source_run_id": receipt["run_id"],
                    "source_checkout_commit": receipt["checkout_commit"],
                    "source_toolchain_identity": receipt["toolchain_identity"],
                    "source_executable_sha256": receipt["executable_sha256"],
                    "input_ply_sha256": receipt["output_sha256"],
                    "camera_digest": camera_digest,
                    "output_sha256": digest,
                    "started_monotonic_seconds": float(len(render_operations)),
                    "ended_monotonic_seconds": float(len(render_operations) + 1),
                    "status": "completed",
                }
            )
        manifest_views.append(
            {
                "holdout_index": holdout_index,
                "camera": camera_record,
                "camera_digest": camera_digest,
                "ground_truth": {
                    "path": ground_truth_path.as_posix(),
                    "sha256": ground_truth_sha,
                    "input_digest": req["binding"]["input_digest"],
                },
                "renders": rendered,
            }
        )
    reference = {
        "schema_version": 1,
        "views": reference_views,
    }
    reference_path = root / "accurate-rendering-reference.json"
    reference_path.write_bytes(evidence.canonical_json_bytes(reference) + b"\n")
    operations_by_key = {
        (item["variant"], item["holdout_index"]): item
        for item in render_operations
    }
    render_operations = [
        operations_by_key[(variant, holdout)]
        for variant in VARIANTS
        for holdout in HOLDOUTS
    ]
    for index, operation in enumerate(render_operations):
        operation["started_monotonic_seconds"] = float(index)
        operation["ended_monotonic_seconds"] = float(index + 1)
    manifest = {
        "schema_version": 1,
        "scene_id": req["binding"]["scene_id"],
        "scale": req["binding"]["scale"],
        "request_digest": request_digest,
        "input_digest": req["binding"]["input_digest"],
        "holdout_indices": HOLDOUTS,
        "training_view_indices": [index for index in range(12) if index not in HOLDOUTS],
        "color_space": "srgb",
        "pixel_format": "png_rgb8",
        "renderer_closure_sha256": RENDERER_CLOSURE_SHA256,
        "renderer_executable_sha256": RENDERER_SHA256,
        "render_operations": render_operations,
        "views": manifest_views,
    }
    manifest_path = root / "rendering-manifest.json"
    manifest_path.write_bytes(evidence.canonical_json_bytes(manifest) + b"\n")
    return req, reference_path


class RenderEvidenceTests(unittest.TestCase):
    def score(
        self,
        root: Path,
        req: dict[str, object],
        reference_path: Path,
        renderer_sha256: str = RENDERER_SHA256,
    ):
        return evidence.validate_and_score_rendering(
            artifact_root=root,
            manifest_path=root / "rendering-manifest.json",
            reference_path=reference_path,
            request=req,
            commands=commands(),
            renderer_executable_sha256=renderer_sha256,
            lpips_distance=lambda first, second: float(abs(first.mean() - second.mean())),
        )

    def test_scores_pixels_and_returns_signed_artifact_descriptors(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            req, reference_path = write_render_closure(root)

            result = self.score(root, req, reference_path)

            self.assertEqual([sample["holdout_index"] for sample in result.samples], HOLDOUTS)
            self.assertEqual(len(result.artifacts), len(HOLDOUTS) * 5 + 1)
            self.assertTrue(all(sample["candidate_psnr"] < 100 for sample in result.samples))

    def test_scores_the_ground_truth_bytes_that_were_hashed(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            req, reference_path = write_render_closure(root)
            target = root / "rendering" / "ground-truth" / f"{HOLDOUTS[0]:06d}.png"
            original_open = Image.open
            open_count = 0

            def replace_before_decode(file, *args, **kwargs):
                nonlocal open_count
                open_count += 1
                if open_count == 1:
                    write_png(target, 255)
                return original_open(file, *args, **kwargs)

            with mock.patch.object(Image, "open", side_effect=replace_before_decode):
                result = self.score(root, req, reference_path)

            self.assertEqual(result.balanced[0]["reference_psnr"], 100.0)

    def test_scores_the_render_bytes_that_were_hashed(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            req, reference_path = write_render_closure(root)
            target = root / "rendering" / "accurate_reference" / f"{HOLDOUTS[0]:06d}.png"
            original_open = Image.open
            open_count = 0

            def replace_before_decode(file, *args, **kwargs):
                nonlocal open_count
                open_count += 1
                if open_count == 2:
                    write_png(target, 255)
                return original_open(file, *args, **kwargs)

            with mock.patch.object(Image, "open", side_effect=replace_before_decode):
                result = self.score(root, req, reference_path)

            self.assertEqual(result.balanced[0]["reference_psnr"], 100.0)

    def test_rejects_wrong_dimensions_before_decoding_pixels(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            image_path = root / "image.png"
            digest = write_png(image_path, 64)

            class OversizedImage:
                format = "PNG"
                mode = "RGB"
                size = (100_000, 100_000)

                def __enter__(self):
                    return self

                def __exit__(self, *_):
                    return False

                def load(self):
                    raise AssertionError("pixel decoding ran before the signed size check")

            with (
                mock.patch.object(Image, "open", return_value=OversizedImage()),
                self.assertRaisesRegex(evidence.EvidenceError, "dimensions"),
            ):
                evidence._load_render_image(
                    artifact_root=root,
                    relative_path=PurePosixPath("image.png"),
                    expected_sha256=digest,
                    expected_width=64,
                    expected_height=64,
                    label="oversized image",
                )

    def test_maps_pillow_decompression_bombs_to_evidence_errors(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            image_path = root / "image.png"
            digest = write_png(image_path, 64)
            with (
                mock.patch.object(
                    Image,
                    "open",
                    side_effect=Image.DecompressionBombError("bomb"),
                ),
                self.assertRaisesRegex(evidence.EvidenceError, "readable PNG"),
            ):
                evidence._load_render_image(
                    artifact_root=root,
                    relative_path=PurePosixPath("image.png"),
                    expected_sha256=digest,
                    expected_width=64,
                    expected_height=64,
                    label="bomb image",
                )

    def test_scores_canonical_source_major_render_operations(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            req, reference_path = write_render_closure(root)
            manifest_path = root / "rendering-manifest.json"
            manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
            operations = {
                (item["variant"], item["holdout_index"]): item
                for item in manifest["render_operations"]
            }
            manifest["render_operations"] = [
                operations[(variant, holdout)]
                for variant in VARIANTS
                for holdout in HOLDOUTS
            ]
            for index, operation in enumerate(manifest["render_operations"]):
                operation["started_monotonic_seconds"] = float(index)
                operation["ended_monotonic_seconds"] = float(index + 1)
            manifest_path.write_bytes(evidence.canonical_json_bytes(manifest) + b"\n")

            result = self.score(root, req, reference_path)

            self.assertEqual([sample["holdout_index"] for sample in result.samples], HOLDOUTS)

    def test_rejects_nonpublished_candidate_source_even_when_receipt_is_valid(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            req, reference_path = write_render_closure(root)
            manifest_path = root / "rendering-manifest.json"
            manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
            alternate = {
                **commands()[1],
                "run_id": "candidate-earlier-run",
                "output_sha256": "sha256:" + "9" * 64,
                "published_output": False,
            }
            for view in manifest["views"]:
                render = view["renders"][2]
                render["source_run_id"] = alternate["run_id"]
                render["ply_sha256"] = alternate["output_sha256"]
            for operation in manifest["render_operations"]:
                if operation["variant"] == "candidate_balanced":
                    operation["source_run_id"] = alternate["run_id"]
                    operation["input_ply_sha256"] = alternate["output_sha256"]
            manifest_path.write_bytes(evidence.canonical_json_bytes(manifest) + b"\n")

            with self.assertRaisesRegex(evidence.EvidenceError, "published output"):
                evidence.validate_and_score_rendering(
                    artifact_root=root,
                    manifest_path=manifest_path,
                    reference_path=reference_path,
                    request=req,
                    commands=[*commands(), alternate],
                    renderer_executable_sha256=RENDERER_SHA256,
                    lpips_distance=lambda first, second: float(abs(first.mean() - second.mean())),
                )

    def test_rejects_mixed_source_run_across_holdouts(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            req, reference_path = write_render_closure(root)
            manifest_path = root / "rendering-manifest.json"
            manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
            alternate = {
                **commands()[0],
                "run_id": "baseline-earlier-run",
                "output_sha256": "sha256:" + "9" * 64,
                "published_output": False,
            }
            render = manifest["views"][1]["renders"][1]
            render["source_run_id"] = alternate["run_id"]
            render["ply_sha256"] = alternate["output_sha256"]
            operation = next(
                item
                for item in manifest["render_operations"]
                if item["holdout_index"] == HOLDOUTS[1]
                and item["variant"] == "paired_baseline"
            )
            operation["source_run_id"] = alternate["run_id"]
            operation["input_ply_sha256"] = alternate["output_sha256"]
            manifest_path.write_bytes(evidence.canonical_json_bytes(manifest) + b"\n")

            with self.assertRaisesRegex(evidence.EvidenceError, "one source execution"):
                evidence.validate_and_score_rendering(
                    artifact_root=root,
                    manifest_path=manifest_path,
                    reference_path=reference_path,
                    request=req,
                    commands=[alternate, *commands()],
                    renderer_executable_sha256=RENDERER_SHA256,
                    lpips_distance=lambda first, second: float(abs(first.mean() - second.mean())),
                )

    def test_rejects_missing_duplicate_misordered_or_altered_images(self) -> None:
        mutations = {
            "missing": lambda root, manifest: (root / manifest["views"][0]["renders"][0]["path"]).unlink(),
            "duplicate": lambda root, manifest: manifest["views"][0]["renders"].__setitem__(
                1, dict(manifest["views"][0]["renders"][0])
            ),
            "misordered": lambda root, manifest: manifest["views"].reverse(),
            "altered": lambda root, manifest: write_png(
                root / manifest["views"][0]["renders"][0]["path"], 255
            ),
        }
        for label, mutate in mutations.items():
            with self.subTest(label=label), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                req, reference_path = write_render_closure(root)
                manifest_path = root / "rendering-manifest.json"
                manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
                mutate(root, manifest)
                manifest_path.write_bytes(evidence.canonical_json_bytes(manifest) + b"\n")

                with self.assertRaises(evidence.EvidenceError):
                    self.score(root, req, reference_path)

    def test_rejects_holdout_training_overlap_camera_changes_and_wrong_ply(self) -> None:
        mutations = {
            "holdout overlap": lambda manifest: manifest["training_view_indices"].append(HOLDOUTS[0]),
            "camera": lambda manifest: manifest["views"][0]["camera"].update({"width": 63}),
            "ply": lambda manifest: manifest["views"][0]["renders"][0].update(
                {"ply_sha256": "sha256:" + "f" * 64}
            ),
        }
        for label, mutate in mutations.items():
            with self.subTest(label=label), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                req, reference_path = write_render_closure(root)
                manifest_path = root / "rendering-manifest.json"
                manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
                mutate(manifest)
                manifest_path.write_bytes(evidence.canonical_json_bytes(manifest) + b"\n")

                with self.assertRaises(evidence.EvidenceError):
                    self.score(root, req, reference_path)

    def test_rejects_unapproved_renderer_or_incomplete_render_operations(self) -> None:
        mutations = {
            "renderer": lambda manifest: manifest.update(
                {"renderer_executable_sha256": "sha256:" + "f" * 64}
            ),
            "missing operation": lambda manifest: manifest["render_operations"].pop(),
            "duplicate operation": lambda manifest: manifest["render_operations"].__setitem__(
                1, dict(manifest["render_operations"][0])
            ),
            "source build": lambda manifest: manifest["render_operations"][0].update(
                {"source_executable_sha256": "sha256:" + "f" * 64}
            ),
            "pseudo command": lambda manifest: manifest["render_operations"][0].update(
                {"argv": ["fabricated://command"], "exit_code": 0}
            ),
        }
        for label, mutate in mutations.items():
            with self.subTest(label=label), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                req, reference_path = write_render_closure(root)
                manifest_path = root / "rendering-manifest.json"
                manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
                mutate(manifest)
                manifest_path.write_bytes(evidence.canonical_json_bytes(manifest) + b"\n")

                with self.assertRaises(evidence.EvidenceError):
                    self.score(root, req, reference_path)

    def test_rejects_renderer_binary_substitution(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            req, reference_path = write_render_closure(root)

            with self.assertRaisesRegex(evidence.EvidenceError, "bound request"):
                self.score(
                    root,
                    req,
                    reference_path,
                    renderer_sha256="sha256:" + "f" * 64,
                )

    def test_rejects_render_target_above_pixel_budget(self) -> None:
        oversized = camera(HOLDOUTS[0])
        oversized.update({"width": 4096, "height": 2048})

        with self.assertRaisesRegex(evidence.EvidenceError, "4,194,304-pixel"):
            evidence._render_camera(oversized, "oversized camera")

    def test_lpips_calibration_fails_closed(self) -> None:
        calibration = {
            f"lin{index}.model.1.weight": f"weight-{index}"
            for index in range(7)
        }
        evidence._verify_lpips_calibration(
            calibration,
            dict(calibration),
            tensors_equal=lambda left, right: left == right,
        )

        shifted = {
            key.replace("model.1", "model.0"): value
            for key, value in calibration.items()
        }
        with self.assertRaisesRegex(evidence.EvidenceError, "linear heads"):
            evidence._verify_lpips_calibration(
                shifted,
                calibration,
                tensors_equal=lambda left, right: left == right,
            )

        corrupted = dict(calibration)
        corrupted["lin3.model.1.weight"] = "different"
        with self.assertRaisesRegex(evidence.EvidenceError, "calibration weights"):
            evidence._verify_lpips_calibration(
                corrupted,
                calibration,
                tensors_equal=lambda left, right: left == right,
            )

    def test_lpips_is_cross_process_deterministic_and_matches_mps(self) -> None:
        if not os.environ.get("EASYSPLAT_BENCHMARK_LPIPS_BACKBONE"):
            self.skipTest("pinned LPIPS backbone is not configured")
        try:
            import lpips  # noqa: F401
            import torch
        except ImportError:
            self.skipTest("render-scoring dependencies are not installed")

        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            candidate_path = root / "candidate.png"
            target_path = root / "target.png"
            candidate_pixels = [
                (
                    (column * 3 + row * 5) % 256,
                    (column * 7 + row * 11) % 256,
                    (column * 13 + row * 17) % 256,
                )
                for row in range(64)
                for column in range(64)
            ]
            target_pixels = [
                (
                    min(255, red + (index % 5)),
                    max(0, green - (index % 3)),
                    min(255, blue + (index % 7)),
                )
                for index, (red, green, blue) in enumerate(candidate_pixels)
            ]
            candidate = Image.new("RGB", (64, 64))
            candidate.putdata(candidate_pixels)
            candidate.save(candidate_path, format="PNG")
            target = Image.new("RGB", (64, 64))
            target.putdata(target_pixels)
            target.save(target_path, format="PNG")

            program = """
import sys
from pathlib import Path, PurePosixPath
from scripts.benchmark import evidence_protocol as evidence
evidence.LPIPS_DEVICE_OVERRIDE = sys.argv[3]
candidate_path = Path(sys.argv[1])
target_path = Path(sys.argv[2])
candidate, _ = evidence._load_render_image(
    artifact_root=candidate_path.parent,
    relative_path=PurePosixPath(candidate_path.name),
    expected_sha256=evidence.sha256_file(candidate_path),
    expected_width=64,
    expected_height=64,
    label='candidate',
)
target, _ = evidence._load_render_image(
    artifact_root=target_path.parent,
    relative_path=PurePosixPath(target_path.name),
    expected_sha256=evidence.sha256_file(target_path),
    expected_width=64,
    expected_height=64,
    label='target',
)
print(f'{evidence._lpips_distance(candidate, target):.17g}')
"""

            def score(device: str) -> float:
                completed = subprocess.run(
                    [
                        sys.executable,
                        "-c",
                        program,
                        str(candidate_path),
                        str(target_path),
                        device,
                    ],
                    cwd=ROOT,
                    env=os.environ.copy(),
                    check=True,
                    capture_output=True,
                    text=True,
                )
                return float(completed.stdout.strip())

            cpu_first = score("cpu")
            cpu_second = score("cpu")
            self.assertEqual(cpu_first, cpu_second)
            self.assertGreaterEqual(cpu_first, 0.0)
            if torch.backends.mps.is_available():
                self.assertAlmostEqual(score("mps"), cpu_first, delta=1e-6)


if __name__ == "__main__":
    unittest.main()
