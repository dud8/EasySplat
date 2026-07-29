#!/usr/bin/env python3
"""Mip-NeRF 360 evaluation helpers.

`cameras` turns a COLMAP sparse reconstruction into a render request, using the same
held-out split the native trainer applies -- filename-sorted, every Nth camera starting
at index 0 -- and the same intrinsic rescaling it performs when the image on disk differs
from `cameras.bin`. `metrics` scores rendered views against ground truth.

This lives in the repository rather than beside the datasets because the split rule here
has to agree with `stage_sparse_views.py` and with the trainer, and nothing was checking
that. It also has to agree with itself across runs: the render request is the only place
the camera set is written down, so a changed near plane or a changed rescale would present
as a quality delta rather than as a protocol change.

Two perceptual backbones are reported. VGG is what the published leaderboards use, so it
is the one a cross-method comparison needs. SqueezeNet is what
`contracts/research-quality-v1.json` gates on, deliberately: a candidate tuned against the
metric it is judged by is not evidence, and the trainer's loss has no SqueezeNet in it.
Both are cheap once the images are loaded, so both are always written.
"""

from __future__ import annotations

import argparse
import json
import struct
from pathlib import Path

import numpy as np

CAMERA_PARAM_COUNT = {0: 3, 1: 4, 2: 4, 3: 5, 4: 8}
CAMERA_MODEL_NAME = {0: "SIMPLE_PINHOLE", 1: "PINHOLE", 2: "SIMPLE_RADIAL", 3: "RADIAL", 4: "OPENCV"}

# The renderer draws an undistorted pinhole camera and has no lens model. Anything else has
# to be undistorted first, and silently treating it as a pinhole would put a real warp into
# the ground-truth comparison.
UNDISTORTED_MODELS = ("PINHOLE", "SIMPLE_PINHOLE")

SSIM_WINDOW = 11
SSIM_SIGMA = 1.5


def read_cameras_bin(path: Path) -> dict[int, dict]:
    cameras: dict[int, dict] = {}
    with open(path, "rb") as handle:
        count = struct.unpack("<Q", handle.read(8))[0]
        for _ in range(count):
            camera_id, model = struct.unpack("<ii", handle.read(8))
            width, height = struct.unpack("<QQ", handle.read(16))
            params = struct.unpack(f"<{CAMERA_PARAM_COUNT[model]}d",
                                   handle.read(8 * CAMERA_PARAM_COUNT[model]))
            cameras[camera_id] = {
                "model": CAMERA_MODEL_NAME[model],
                "width": int(width),
                "height": int(height),
                "params": list(params),
            }
    return cameras


def read_images_bin(path: Path) -> list[dict]:
    images: list[dict] = []
    with open(path, "rb") as handle:
        count = struct.unpack("<Q", handle.read(8))[0]
        for _ in range(count):
            struct.unpack("<I", handle.read(4))  # image id
            quaternion = struct.unpack("<4d", handle.read(32))  # w, x, y, z
            translation = struct.unpack("<3d", handle.read(24))
            camera_id = struct.unpack("<I", handle.read(4))[0]
            name = b""
            while True:
                char = handle.read(1)
                if char == b"\x00":
                    break
                name += char
            point_count = struct.unpack("<Q", handle.read(8))[0]
            handle.seek(point_count * 24, 1)
            images.append({
                "name": name.decode("utf-8"),
                "quaternion": quaternion,
                "translation": translation,
                "camera_id": camera_id,
            })
    return images


def rotation_from_quaternion(q) -> np.ndarray:
    w, x, y, z = np.array(q, dtype=np.float64) / np.linalg.norm(q)
    return np.array([
        [1 - 2 * (y * y + z * z), 2 * (x * y - w * z), 2 * (x * z + w * y)],
        [2 * (x * y + w * z), 1 - 2 * (x * x + z * z), 2 * (y * z - w * x)],
        [2 * (x * z - w * y), 2 * (y * z + w * x), 1 - 2 * (x * x + y * y)],
    ])


def pinhole_intrinsics(camera: dict) -> tuple[float, float, float, float]:
    params = camera["params"]
    if camera["model"] == "PINHOLE":
        return params[0], params[1], params[2], params[3]
    if camera["model"] in ("SIMPLE_PINHOLE", "SIMPLE_RADIAL", "RADIAL"):
        return params[0], params[0], params[1], params[2]
    if camera["model"] == "OPENCV":
        return params[0], params[1], params[2], params[3]
    raise SystemExit(f"unsupported camera model {camera['model']}")


def held_out_names(names: list[str], holdout_every: int) -> list[str]:
    """The test split, as names. Filename-sorted, every Nth starting at index 0.

    Sorted here rather than assumed sorted: the trainer sorts before splitting, and a caller
    passing COLMAP's own order would otherwise select a different set.
    """
    return [name for index, name in enumerate(sorted(names)) if index % holdout_every == 0]


def view_matrices(
    quaternion,
    translation,
    intrinsics: tuple[float, float, float, float],
    camera_size: tuple[int, int],
    image_size: tuple[int, int],
    near: float,
    far: float,
) -> tuple[np.ndarray, np.ndarray]:
    """The projection and world-to-camera matrices for one held-out view.

    Split out from `build_cameras` so the two things that would silently corrupt every score
    can be tested without a dataset: the rescale that happens when `cameras.bin` describes a
    different resolution than the image on disk, and the axis flip between COLMAP's
    convention and the renderer's.
    """
    fx, fy, cx, cy = intrinsics
    image_width, image_height = image_size
    scale_x = image_width / camera_size[0]
    scale_y = image_height / camera_size[1]
    fx, fy, cx, cy = fx * scale_x, fy * scale_y, cx * scale_x, cy * scale_y

    zs = far / (near - far)
    projection = np.zeros((4, 4))
    projection[0, 0] = 2.0 * fx / image_width
    projection[1, 1] = 2.0 * fy / image_height
    projection[0, 2] = 1.0 - 2.0 * cx / image_width
    projection[1, 2] = 2.0 * cy / image_height - 1.0
    projection[2, 2] = zs
    projection[3, 2] = -1.0
    projection[2, 3] = zs * near

    world_to_camera = np.eye(4)
    world_to_camera[:3, :3] = rotation_from_quaternion(quaternion)
    world_to_camera[:3, 3] = translation
    # COLMAP looks down +Z with +Y down; the renderer is right-handed with -Z forward and
    # +Y up, so flip the camera-space Y and Z axes.
    world_to_camera = np.diag([1.0, -1.0, -1.0, 1.0]) @ world_to_camera
    return projection, world_to_camera


def build_cameras(arguments: argparse.Namespace) -> int:
    from PIL import Image

    sparse = Path(arguments.dataset) / "sparse" / "0"
    image_dir = Path(arguments.dataset) / "images"
    cameras = read_cameras_bin(sparse / "cameras.bin")
    images = sorted(read_images_bin(sparse / "images.bin"), key=lambda entry: entry["name"])

    for entry in images:
        camera = cameras[entry["camera_id"]]
        if camera["model"] not in UNDISTORTED_MODELS:
            raise SystemExit(
                f"{arguments.dataset}: camera model {camera['model']} carries distortion; "
                "the renderer expects an undistorted pinhole camera"
            )

    centers = []
    for entry in images:
        rotation = rotation_from_quaternion(entry["quaternion"])
        centers.append(-rotation.T @ np.array(entry["translation"]))
    centers = np.array(centers)
    radius = float(np.max(np.linalg.norm(centers - centers.mean(axis=0), axis=1)))
    near = arguments.near_fraction * radius
    far = arguments.far_multiple * radius

    held_out = set(held_out_names([entry["name"] for entry in images], arguments.holdout_every))
    views = []
    for entry in images:
        if entry["name"] not in held_out:
            continue
        camera = cameras[entry["camera_id"]]
        with Image.open(image_dir / entry["name"]) as handle:
            image_size = handle.size
        projection, world_to_camera = view_matrices(
            entry["quaternion"],
            entry["translation"],
            pinhole_intrinsics(camera),
            (camera["width"], camera["height"]),
            image_size,
            near,
            far,
        )
        views.append({
            "name": entry["name"],
            "width": image_size[0],
            "height": image_size[1],
            "projection_matrix_column_major": projection.T.flatten().tolist(),
            "world_to_camera_matrix_column_major": world_to_camera.T.flatten().tolist(),
        })

    request = {
        "ply": str(Path(arguments.ply).resolve()),
        "output_dir": str(Path(arguments.output_dir).resolve()),
        "views": views,
    }
    Path(arguments.output).write_text(json.dumps(request, indent=2) + "\n", encoding="utf-8")
    print(f"{len(images)} cameras, {len(views)} held out, radius {radius:.3f}, "
          f"near {near:.4f}, far {far:.1f}")
    return 0


def load_rgb(path: Path) -> np.ndarray:
    from PIL import Image

    with Image.open(path) as handle:
        return np.asarray(handle.convert("RGB"), dtype=np.float32) / 255.0


def score(arguments: argparse.Namespace) -> int:
    import torch
    import lpips

    manifest = json.loads(Path(arguments.manifest).read_text(encoding="utf-8"))
    ground_truth_dir = Path(arguments.ground_truth)
    device = torch.device("mps" if arguments.device == "mps" and torch.backends.mps.is_available()
                          else "cpu")
    backbones = {
        "lpips_vgg": lpips.LPIPS(net="vgg").to(device),
        "lpips_squeeze": lpips.LPIPS(net="squeeze").to(device),
    }

    def ssim(a: torch.Tensor, b: torch.Tensor) -> float:
        # 11x11 gaussian window, sigma 1.5, the 3DGS reference formulation.
        coords = torch.arange(SSIM_WINDOW, dtype=torch.float32, device=a.device) - SSIM_WINDOW // 2
        gaussian = torch.exp(-(coords ** 2) / (2 * SSIM_SIGMA ** 2))
        gaussian = gaussian / gaussian.sum()
        kernel = (gaussian[:, None] @ gaussian[None, :]).expand(3, 1, SSIM_WINDOW, SSIM_WINDOW)

        def filt(x: torch.Tensor) -> torch.Tensor:
            return torch.nn.functional.conv2d(x, kernel, padding=SSIM_WINDOW // 2, groups=3)

        mu_a, mu_b = filt(a), filt(b)
        mu_a2, mu_b2, mu_ab = mu_a * mu_a, mu_b * mu_b, mu_a * mu_b
        sigma_a2 = filt(a * a) - mu_a2
        sigma_b2 = filt(b * b) - mu_b2
        sigma_ab = filt(a * b) - mu_ab
        c1, c2 = 0.01 ** 2, 0.03 ** 2
        numerator = (2 * mu_ab + c1) * (2 * sigma_ab + c2)
        denominator = (mu_a2 + mu_b2 + c1) * (sigma_a2 + sigma_b2 + c2)
        return float((numerator / denominator).mean())

    rows = []
    for view in manifest["views"]:
        rendered = load_rgb(Path(view["path"]))
        truth = load_rgb(ground_truth_dir / view["name"])
        if rendered.shape != truth.shape:
            raise SystemExit(
                f"{view['name']}: rendered {rendered.shape} does not match "
                f"ground truth {truth.shape}"
            )
        mse = float(np.mean((rendered - truth) ** 2))
        psnr = float("inf") if mse == 0 else 10.0 * float(np.log10(1.0 / mse))

        a = torch.from_numpy(rendered).permute(2, 0, 1)[None].to(device)
        b = torch.from_numpy(truth).permute(2, 0, 1)[None].to(device)
        with torch.no_grad():
            structural = ssim(a, b)
            perceptual = {
                name: float(metric(a * 2 - 1, b * 2 - 1).item())
                for name, metric in backbones.items()
            }
        rows.append({
            "name": view["name"],
            "psnr": psnr,
            "ssim": structural,
            "render_seconds": view["render_seconds"],
            **perceptual,
        })
        print(f"  {view['name']:<20s} psnr {psnr:6.3f}  ssim {structural:.4f}  "
              f"lpips {perceptual['lpips_vgg']:.4f}/{perceptual['lpips_squeeze']:.4f}")

    def mean(key: str) -> float:
        return float(np.mean([row[key] for row in rows]))

    summary = {
        "view_count": len(rows),
        "psnr": mean("psnr"),
        "ssim": mean("ssim"),
        "lpips_vgg": mean("lpips_vgg"),
        "lpips_squeeze": mean("lpips_squeeze"),
        "render_seconds_mean": mean("render_seconds"),
        "splat_count": manifest["splat_count"],
        "peak_metal_allocated_bytes": manifest["peak_metal_allocated_bytes"],
        "ply_load_seconds": manifest["load_seconds"],
        # What these numbers mean, recorded beside them. A comparison across two runs whose
        # protocol blocks differ is not a comparison, and there is otherwise nothing in the
        # file that would say so.
        "protocol": {
            "psnr": "float32 rgb in [0,1]",
            "ssim": f"gaussian window {SSIM_WINDOW}, sigma {SSIM_SIGMA}, k1 0.01, k2 0.03",
            "lpips_vgg": "lpips package, vgg backbone, calibration v0.1",
            "lpips_squeeze": "lpips package, squeezenet backbone, calibration v0.1",
            "gating_backbone": "lpips_squeeze",
        },
        "renderer": manifest.get("provenance", {}),
        "views": rows,
    }
    Path(arguments.output).write_text(json.dumps(summary, indent=2) + "\n", encoding="utf-8")
    print(f"mean psnr {summary['psnr']:.3f}  ssim {summary['ssim']:.4f}  "
          f"lpips(vgg) {summary['lpips_vgg']:.4f}  lpips(squeeze) {summary['lpips_squeeze']:.4f}")
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="command", required=True)

    cameras = subparsers.add_parser("cameras")
    cameras.add_argument("--dataset", required=True)
    cameras.add_argument("--ply", required=True)
    cameras.add_argument("--output-dir", required=True)
    cameras.add_argument("--output", required=True)
    cameras.add_argument("--holdout-every", type=int, default=8)
    cameras.add_argument("--near-fraction", type=float, default=0.02)
    cameras.add_argument("--far-multiple", type=float, default=100.0)
    cameras.set_defaults(func=build_cameras)

    metrics = subparsers.add_parser("metrics")
    metrics.add_argument("--manifest", required=True)
    metrics.add_argument("--ground-truth", required=True)
    metrics.add_argument("--output", required=True)
    metrics.add_argument("--device", default="cpu")
    metrics.set_defaults(func=score)

    arguments = parser.parse_args()
    return arguments.func(arguments)


if __name__ == "__main__":
    raise SystemExit(main())
