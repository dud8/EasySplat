from __future__ import annotations

import argparse
import gc
import importlib
import json
import math
import os
import random
import shutil
import sys
import tempfile
from dataclasses import dataclass
from pathlib import Path

import numpy as np
import torch
from PIL import Image

SUPPORTED_RESOLUTION_SETS = (512, 518)
SUPPORTED_CAMERA_TYPES = ("SIMPLE_RADIAL", "SIMPLE_PINHOLE", "PINHOLE", "OPENCV")
TRUTHY_ENV_VALUES = {"1", "true", "yes", "on"}
FALSY_ENV_VALUES = {"0", "false", "no", "off"}


def _env_bool(name: str, default: bool) -> bool:
    raw = os.environ.get(name)
    if raw is None:
        return default
    normalized = raw.strip().lower()
    if not normalized:
        return default
    if normalized in TRUTHY_ENV_VALUES:
        return True
    if normalized in FALSY_ENV_VALUES:
        return False
    raise ValueError(f"{name} must be one of: 1/0, true/false, yes/no, on/off")


def _env_int(name: str, default: int, *, minimum: int | None = None) -> int:
    raw = os.environ.get(name)
    if raw is None:
        value = default
    else:
        normalized = raw.strip()
        if not normalized:
            value = default
        else:
            try:
                value = int(normalized)
            except ValueError as exc:
                raise ValueError(f"{name} must be an integer, got {raw!r}") from exc
    if minimum is not None and value < minimum:
        raise ValueError(f"{name} must be >= {minimum}, got {value}")
    return value


def _env_choice(name: str, default: str, choices: tuple[str, ...]) -> str:
    raw = os.environ.get(name)
    if raw is None:
        return default
    normalized = raw.strip().upper()
    if not normalized:
        return default
    if normalized not in choices:
        allowed = ", ".join(choices)
        raise ValueError(f"{name} must be one of: {allowed}; got {raw!r}")
    return normalized


def _atomic_write_text(path: Path, contents: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile("w", encoding="utf-8", dir=path.parent, delete=False) as handle:
        handle.write(contents)
        temp_path = Path(handle.name)
    temp_path.replace(path)


def _default_models_dir() -> str | None:
    env_path = os.environ.get("EASYSPLAT_MAPANYTHING_MODELS_DIR")
    if env_path and env_path.strip():
        return env_path.strip()

    packaged_models_dir = Path(__file__).resolve().parents[2] / "models"
    if packaged_models_dir.exists():
        return str(packaged_models_dir)
    return None


def _supported_image_exts() -> tuple[str, ...]:
    return (".jpg", ".jpeg", ".png", ".heic", ".heif")


def _list_images(images_dir: Path) -> list[Path]:
    return sorted(
        [
            path
            for path in images_dir.iterdir()
            if path.is_file() and path.suffix.lower() in _supported_image_exts()
        ]
    )


def _select_device(requested: str) -> torch.device:
    request = requested.strip().lower()
    if request == "mps":
        if torch.backends.mps.is_available():
            return torch.device("mps")
        print("MapAnything: requested mps but MPS is unavailable; falling back to cpu", file=sys.stderr)
        return torch.device("cpu")
    if request == "cuda":
        if torch.cuda.is_available():
            return torch.device("cuda")
        print("MapAnything: requested cuda but CUDA is unavailable; falling back to cpu", file=sys.stderr)
        return torch.device("cpu")
    return torch.device(request)


def _maybe_empty_cache(device: torch.device) -> None:
    if device.type == "cuda":
        torch.cuda.empty_cache()
    elif device.type == "mps" and hasattr(torch, "mps") and hasattr(torch.mps, "empty_cache"):
        torch.mps.empty_cache()


def _rotmat_to_quat_wxyz(rot: np.ndarray) -> np.ndarray:
    rot = rot.astype(np.float64)
    trace = float(rot[0, 0] + rot[1, 1] + rot[2, 2])
    if trace > 0.0:
        s = np.sqrt(trace + 1.0) * 2.0
        w = 0.25 * s
        x = (rot[2, 1] - rot[1, 2]) / s
        y = (rot[0, 2] - rot[2, 0]) / s
        z = (rot[1, 0] - rot[0, 1]) / s
    elif rot[0, 0] > rot[1, 1] and rot[0, 0] > rot[2, 2]:
        s = np.sqrt(1.0 + rot[0, 0] - rot[1, 1] - rot[2, 2]) * 2.0
        w = (rot[2, 1] - rot[1, 2]) / s
        x = 0.25 * s
        y = (rot[0, 1] + rot[1, 0]) / s
        z = (rot[0, 2] + rot[2, 0]) / s
    elif rot[1, 1] > rot[2, 2]:
        s = np.sqrt(1.0 + rot[1, 1] - rot[0, 0] - rot[2, 2]) * 2.0
        w = (rot[0, 2] - rot[2, 0]) / s
        x = (rot[0, 1] + rot[1, 0]) / s
        y = 0.25 * s
        z = (rot[1, 2] + rot[2, 1]) / s
    else:
        s = np.sqrt(1.0 + rot[2, 2] - rot[0, 0] - rot[1, 1]) * 2.0
        w = (rot[1, 0] - rot[0, 1]) / s
        x = (rot[0, 2] + rot[2, 0]) / s
        y = (rot[1, 2] + rot[2, 1]) / s
        z = 0.25 * s
    quat = np.array([w, x, y, z], dtype=np.float64)
    norm = np.linalg.norm(quat)
    if norm > 0:
        quat /= norm
    return quat


def _camera_centers_from_extrinsics_w2c(extrinsics_w2c: np.ndarray) -> np.ndarray:
    rotations = extrinsics_w2c[:, :3, :3]
    translations = extrinsics_w2c[:, :3, 3]
    return -(rotations.transpose(0, 2, 1) @ translations[:, :, None])[:, :, 0]


def _average_rotation(rotations: list[np.ndarray]) -> np.ndarray:
    if not rotations:
        return np.eye(3, dtype=np.float64)
    accumulator = np.zeros((3, 3), dtype=np.float64)
    for rotation in rotations:
        accumulator += rotation.astype(np.float64)
    u_mat, _, v_t = np.linalg.svd(accumulator)
    rotation = u_mat @ v_t
    if np.linalg.det(rotation) < 0:
        u_mat[:, -1] *= -1.0
        rotation = u_mat @ v_t
    return rotation


def _estimate_similarity_from_overlap(
    chunk_extrinsics_w2c: np.ndarray,
    global_extrinsics_w2c: np.ndarray,
) -> tuple[float, np.ndarray, np.ndarray]:
    if chunk_extrinsics_w2c.shape[0] != global_extrinsics_w2c.shape[0]:
        raise ValueError("overlap pose count mismatch")

    count = int(chunk_extrinsics_w2c.shape[0])
    if count == 0:
        return 1.0, np.eye(3, dtype=np.float64), np.zeros(3, dtype=np.float64)

    chunk_rotations = chunk_extrinsics_w2c[:, :3, :3].astype(np.float64)
    global_rotations = global_extrinsics_w2c[:, :3, :3].astype(np.float64)
    rotation_candidates = [global_rot.T @ chunk_rot for (global_rot, chunk_rot) in zip(global_rotations, chunk_rotations)]
    rotation_align = _average_rotation(rotation_candidates)

    chunk_centers = _camera_centers_from_extrinsics_w2c(chunk_extrinsics_w2c).astype(np.float64)
    global_centers = _camera_centers_from_extrinsics_w2c(global_extrinsics_w2c).astype(np.float64)
    aligned_chunk = (rotation_align @ chunk_centers.T).T

    chunk_mean = aligned_chunk.mean(axis=0)
    global_mean = global_centers.mean(axis=0)
    chunk_centered = aligned_chunk - chunk_mean
    global_centered = global_centers - global_mean
    denominator = float(np.sum(chunk_centered * chunk_centered))
    if denominator < 1e-12 or count < 2:
        scale = 1.0
    else:
        scale = float(np.sum(global_centered * chunk_centered) / denominator)
        if not np.isfinite(scale) or scale <= 0:
            scale = 1.0
    translation_align = global_mean - scale * chunk_mean
    return scale, rotation_align, translation_align


def _transform_extrinsics_w2c(
    extrinsics_w2c: np.ndarray,
    scale: float,
    rotation_align: np.ndarray,
    translation_align: np.ndarray,
) -> np.ndarray:
    centers = _camera_centers_from_extrinsics_w2c(extrinsics_w2c).astype(np.float64)
    transformed_centers = (scale * (rotation_align @ centers.T)).T + translation_align[None, :]

    chunk_rotations = extrinsics_w2c[:, :3, :3].astype(np.float64)
    rotations = chunk_rotations @ rotation_align.T
    translations = -(rotations @ transformed_centers[:, :, None])[:, :, 0]

    transformed = np.zeros((extrinsics_w2c.shape[0], 4, 4), dtype=np.float64)
    transformed[:, 3, 3] = 1.0
    transformed[:, :3, :3] = rotations
    transformed[:, :3, 3] = translations
    return transformed


def _transform_points_xyz(
    points_xyz: np.ndarray,
    scale: float,
    rotation_align: np.ndarray,
    translation_align: np.ndarray,
) -> np.ndarray:
    flat_points = points_xyz.reshape(-1, 3).astype(np.float64)
    transformed = (scale * (rotation_align @ flat_points.T)).T + translation_align[None, :]
    return transformed.reshape(points_xyz.shape)


def _downsample_paths_uniform(paths: list[Path], target_count: int) -> list[Path]:
    if target_count <= 0 or not paths:
        return []
    if len(paths) <= target_count:
        return list(paths)
    if target_count == 1:
        return [paths[len(paths) // 2]]
    step = float(len(paths) - 1) / float(target_count - 1)
    indices = []
    for index in range(target_count):
        candidate = int(round(index * step))
        candidate = max(0, min(candidate, len(paths) - 1))
        if not indices or indices[-1] != candidate:
            indices.append(candidate)
    if indices[-1] != len(paths) - 1:
        indices[-1] = len(paths) - 1
    return [paths[index] for index in indices]


def _plan_windows(image_count: int, window_size: int, window_overlap: int) -> list[tuple[int, int]]:
    if image_count <= 0:
        return []
    size = max(2, min(window_size, image_count))
    overlap = max(0, min(window_overlap, size - 1))
    stride = max(1, size - overlap)
    if image_count <= size:
        return [(0, image_count)]

    windows: list[tuple[int, int]] = []
    start = 0
    while start < image_count:
        end = min(start + size, image_count)
        if windows and end == windows[-1][1]:
            break
        windows.append((start, end))
        if end == image_count:
            break
        start += stride
    return windows


def _load_original_sizes(image_paths: list[Path]) -> list[tuple[int, int]]:
    sizes: list[tuple[int, int]] = []
    for image_path in image_paths:
        with Image.open(image_path) as image:
            sizes.append(image.size)
    return sizes


def _build_camera_params(
    intrinsics: np.ndarray,
    original_size: tuple[int, int],
    processed_size: tuple[int, int],
    camera_type: str,
) -> list[float]:
    orig_width, orig_height = original_size
    proc_width, proc_height = processed_size
    scale_x = float(orig_width) / float(proc_width)
    scale_y = float(orig_height) / float(proc_height)
    fx = float(intrinsics[0, 0]) * scale_x
    fy = float(intrinsics[1, 1]) * scale_y
    cx = float(orig_width) / 2.0
    cy = float(orig_height) / 2.0

    if camera_type == "PINHOLE":
        return [fx, fy, cx, cy]
    if camera_type == "SIMPLE_PINHOLE":
        focal = (fx + fy) / 2.0
        return [focal, cx, cy]
    if camera_type == "SIMPLE_RADIAL":
        focal = (fx + fy) / 2.0
        return [focal, cx, cy, 0.0]
    if camera_type == "OPENCV":
        return [fx, fy, cx, cy, 0.0, 0.0, 0.0, 0.0]
    raise ValueError(f"Unsupported camera type: {camera_type}")


def _normalize_resolution_set(requested: int) -> int:
    if requested in SUPPORTED_RESOLUTION_SETS:
        return requested
    return min(SUPPORTED_RESOLUTION_SETS, key=lambda candidate: abs(candidate - requested))


def _validate_args(args: argparse.Namespace, *, image_count: int) -> None:
    if image_count < 2:
        raise ValueError("at least 2 supported images are required for reconstruction")
    if args.minibatch_size < 1:
        raise ValueError("--minibatch-size must be >= 1")
    if args.max_points < 1:
        raise ValueError("--max-points must be >= 1")
    if args.camera_type not in SUPPORTED_CAMERA_TYPES:
        allowed = ", ".join(SUPPORTED_CAMERA_TYPES)
        raise ValueError(f"--camera-type must be one of: {allowed}")
    if args.mode == "seed_refine":
        if args.anchor_max_views < 2:
            raise ValueError("--anchor-max-views must be >= 2 in seed_refine mode")
        if args.window_size < 2:
            raise ValueError("--window-size must be >= 2 in seed_refine mode")
        if args.window_overlap < 0:
            raise ValueError("--window-overlap must be >= 0")
        if args.window_overlap >= args.window_size:
            raise ValueError("--window-overlap must be smaller than --window-size in seed_refine mode")


def _remove_path(path: Path) -> None:
    if not path.exists() and not path.is_symlink():
        return
    if path.is_dir() and not path.is_symlink():
        shutil.rmtree(path, ignore_errors=True)
    else:
        path.unlink(missing_ok=True)


def _replace_output_dir_atomically(source_dir: Path, destination_dir: Path) -> None:
    destination_dir.parent.mkdir(parents=True, exist_ok=True)
    _remove_path(destination_dir)
    source_dir.replace(destination_dir)


def _processed_to_original_xy(
    processed_xy: np.ndarray,
    original_size: tuple[int, int],
    processed_size: tuple[int, int],
) -> np.ndarray:
    proc_width, proc_height = processed_size
    orig_width, orig_height = original_size
    if proc_width <= 0 or proc_height <= 0:
        raise ValueError("processed image size must be positive")

    x = (float(processed_xy[0]) + 0.5) * (float(orig_width) / float(proc_width))
    y = (float(processed_xy[1]) + 0.5) * (float(orig_height) / float(proc_height))
    max_x = max(0.0, float(orig_width - 1))
    max_y = max(0.0, float(orig_height - 1))
    return np.array([min(max(x, 0.0), max_x), min(max(y, 0.0), max_y)], dtype=np.float64)


def _write_colmap_text_model(
    out_dir: Path,
    image_paths: list[Path],
    extrinsics_w2c: np.ndarray,
    intrinsics_3x3: np.ndarray,
    original_sizes_wh: list[tuple[int, int]],
    processed_sizes_wh: list[tuple[int, int]],
    camera_type: str,
    shared_camera: bool,
    points_xyz: np.ndarray,
    points_rgb: np.ndarray,
    point_tracks: list[list[tuple[int, np.ndarray]]],
) -> None:
    out_dir.mkdir(parents=True, exist_ok=True)
    if not (
        len(image_paths)
        == len(original_sizes_wh)
        == len(processed_sizes_wh)
        == int(extrinsics_w2c.shape[0])
        == int(intrinsics_3x3.shape[0])
    ):
        raise ValueError("image, pose, or size counts do not match")
    if not (
        int(points_xyz.shape[0])
        == int(points_rgb.shape[0])
        == len(point_tracks)
    ):
        raise ValueError("point, color, or track counts do not match")

    cameras_txt = out_dir / "cameras.txt"
    images_txt = out_dir / "images.txt"
    points_txt = out_dir / "points3D.txt"

    camera_lines: list[str] = []
    shared_params: list[float] | None = None
    shared_size: tuple[int, int] | None = None
    camera_params_by_image = [
        _build_camera_params(intrinsics, original_size, processed_size, camera_type)
        for (intrinsics, original_size, processed_size) in zip(
            intrinsics_3x3,
            original_sizes_wh,
            processed_sizes_wh,
        )
    ]

    if shared_camera:
        unique_sizes = set(original_sizes_wh)
        if len(unique_sizes) != 1:
            print(
                "MapAnything: shared-camera export requested but image sizes differ; "
                "falling back to per-image cameras.",
                file=sys.stderr,
            )
            shared_camera = False
        else:
            shared_size = original_sizes_wh[0]
            shared_params = np.mean(np.asarray(camera_params_by_image, dtype=np.float64), axis=0).tolist()

    image_observations: list[list[tuple[np.ndarray, int]]] = [[] for _ in image_paths]
    point_track_refs: list[list[tuple[int, int]]] = []
    for point_id, observations in enumerate(point_tracks, start=1):
        if not observations:
            raise ValueError(f"point track {point_id} is empty")
        refs_for_point: list[tuple[int, int]] = []
        seen_images: set[int] = set()
        for image_index, processed_xy in observations:
            image_index = int(image_index)
            if image_index < 0 or image_index >= len(image_paths):
                raise ValueError(f"point observation references invalid image index: {image_index}")
            if image_index in seen_images:
                continue
            seen_images.add(image_index)
            original_xy = _processed_to_original_xy(
                processed_xy,
                original_size=original_sizes_wh[image_index],
                processed_size=processed_sizes_wh[image_index],
            )
            point2d_index = len(image_observations[image_index])
            image_observations[image_index].append((original_xy, point_id))
            refs_for_point.append((image_index + 1, point2d_index))
        if not refs_for_point:
            raise ValueError(f"point track {point_id} has no valid observations")
        point_track_refs.append(refs_for_point)

    for index, (image_path, original_size, processed_size) in enumerate(
        zip(image_paths, original_sizes_wh, processed_sizes_wh),
        start=1,
    ):
        if shared_camera:
            camera_id = 1
            params = shared_params or []
            width, height = shared_size or original_size
        else:
            camera_id = index
            params = camera_params_by_image[index - 1]
            width, height = original_size
        params_text = " ".join(f"{value}" for value in params)
        if not shared_camera or index == 1:
            camera_lines.append(f"{camera_id} {camera_type} {width} {height} {params_text}")

    with cameras_txt.open("w", encoding="utf-8") as handle:
        handle.write("# Camera list with one line per camera:\n")
        handle.write("#   CAMERA_ID, MODEL, WIDTH, HEIGHT, PARAMS[]\n")
        handle.write(f"# Number of cameras: {len(camera_lines)}\n")
        for line in camera_lines:
            handle.write(f"{line}\n")

    with images_txt.open("w", encoding="utf-8") as handle:
        handle.write("# Image list with two lines per image:\n")
        handle.write("#   IMAGE_ID, QW, QX, QY, QZ, TX, TY, TZ, CAMERA_ID, NAME\n")
        handle.write("#   POINTS2D[] as (X, Y, POINT3D_ID)\n")
        mean_observations = float(sum(len(observations) for observations in image_observations)) / float(len(image_paths))
        handle.write(f"# Number of images: {len(image_paths)}, mean observations per image: {mean_observations}\n")
        for index, image_path in enumerate(image_paths, start=1):
            camera_id = 1 if shared_camera else index
            rotation = extrinsics_w2c[index - 1, :3, :3]
            translation = extrinsics_w2c[index - 1, :3, 3]
            quat = _rotmat_to_quat_wxyz(rotation)
            handle.write(
                f"{index} {quat[0]} {quat[1]} {quat[2]} {quat[3]} "
                f"{translation[0]} {translation[1]} {translation[2]} {camera_id} {image_path.name}\n"
            )
            points_text = " ".join(
                f"{xy[0]} {xy[1]} {point_id}"
                for (xy, point_id) in image_observations[index - 1]
            )
            handle.write(f"{points_text}\n")

    with points_txt.open("w", encoding="utf-8") as handle:
        handle.write("# 3D point list with one line per point:\n")
        handle.write("#   POINT3D_ID, X, Y, Z, R, G, B, ERROR, TRACK[] as (IMAGE_ID, POINT2D_IDX)\n")
        mean_track_length = (
            float(sum(len(track) for track in point_track_refs)) / float(len(point_track_refs))
            if point_track_refs
            else 0.0
        )
        handle.write(f"# Number of points: {len(points_xyz)}, mean track length: {mean_track_length}\n")
        for index, (xyz, rgb, track_refs) in enumerate(zip(points_xyz, points_rgb, point_track_refs), start=1):
            track_text = " ".join(f"{image_id} {point2d_index}" for (image_id, point2d_index) in track_refs)
            handle.write(
                f"{index} {xyz[0]} {xyz[1]} {xyz[2]} "
                f"{int(rgb[0])} {int(rgb[1])} {int(rgb[2])} 1.0 {track_text}\n"
            )


def _install_offline_dinov2_loader(weights_dir: Path):
    original_loader = torch.hub.load_state_dict_from_url
    original_hub_load = torch.hub.load

    def _offline_loader(url: str, *args, **kwargs):  # type: ignore[override]
        candidate = weights_dir / Path(url).name
        if candidate.exists():
            map_location = kwargs.get("map_location", "cpu")
            print(f"MapAnything: loading local DINOv2 weights from {candidate}")
            return torch.load(candidate, map_location=map_location, weights_only=False)
        return original_loader(url, *args, **kwargs)

    def _offline_hub_load(repo_or_dir, model, *args, **kwargs):  # type: ignore[override]
        normalized_repo = str(repo_or_dir).strip().rstrip("/")
        if normalized_repo == "facebookresearch/dinov2":
            print(f"MapAnything: serving {model} from vendored DINOv2 code")
            backbones = importlib.import_module("mapanything.models.external.dinov2.hub.backbones")
            if not hasattr(backbones, model):
                raise RuntimeError(f"MapAnything: vendored DINOv2 model not found: {model}")
            return getattr(backbones, model)(*args, **kwargs)
        return original_hub_load(repo_or_dir, model, *args, **kwargs)

    torch.hub.load_state_dict_from_url = _offline_loader
    torch.hub.load = _offline_hub_load

    def _restore() -> None:
        torch.hub.load_state_dict_from_url = original_loader
        torch.hub.load = original_hub_load

    return _restore


@dataclass(frozen=True)
class WindowResult:
    extrinsics_w2c: np.ndarray
    intrinsics_3x3: np.ndarray
    processed_sizes_wh: list[tuple[int, int]]
    points_xyz: np.ndarray
    points_rgb: np.ndarray
    point_image_indices: np.ndarray
    point_xys_processed: np.ndarray
    point_confidences: np.ndarray


def _collect_points_from_outputs(
    outputs: list[dict],
    point_budget: int,
) -> tuple[np.ndarray, np.ndarray, np.ndarray, np.ndarray, np.ndarray]:
    points_xyz_accum: list[np.ndarray] = []
    points_rgb_accum: list[np.ndarray] = []
    point_image_indices_accum: list[np.ndarray] = []
    point_xys_processed_accum: list[np.ndarray] = []
    point_confidences_accum: list[np.ndarray] = []
    per_view_budget = max(1, point_budget // max(1, len(outputs)))

    for view_index, prediction in enumerate(outputs):
        pts3d = prediction["pts3d"][0].detach().cpu().numpy()
        depth_z = prediction["depth_z"][0].detach().cpu().numpy().squeeze(-1)
        mask = prediction["mask"][0].detach().cpu().numpy().squeeze(-1).astype(bool)
        rgb = (prediction["img_no_norm"][0].detach().cpu().numpy() * 255.0).clip(0, 255).astype(np.uint8)
        if "conf" in prediction:
            conf = prediction["conf"][0].detach().cpu().numpy()
        else:
            conf = np.ones(mask.shape, dtype=np.float32)

        valid_mask = mask & (depth_z > 0) & np.isfinite(pts3d).all(axis=-1)
        valid_points = pts3d[valid_mask]
        valid_rgb = rgb[valid_mask]
        valid_y, valid_x = np.nonzero(valid_mask)
        valid_xys = np.stack([valid_x.astype(np.float32), valid_y.astype(np.float32)], axis=1)
        valid_conf = conf[valid_mask].astype(np.float32)
        if len(valid_points) == 0:
            continue

        if len(valid_points) > per_view_budget:
            indices = np.linspace(0, len(valid_points) - 1, num=per_view_budget, dtype=int)
            valid_points = valid_points[indices]
            valid_rgb = valid_rgb[indices]
            valid_xys = valid_xys[indices]
            valid_conf = valid_conf[indices]

        points_xyz_accum.append(valid_points.astype(np.float32))
        points_rgb_accum.append(valid_rgb.astype(np.uint8))
        point_image_indices_accum.append(np.full((len(valid_points),), view_index, dtype=np.int32))
        point_xys_processed_accum.append(valid_xys.astype(np.float32))
        point_confidences_accum.append(valid_conf)

    if not points_xyz_accum:
        return (
            np.zeros((0, 3), dtype=np.float32),
            np.zeros((0, 3), dtype=np.uint8),
            np.zeros((0,), dtype=np.int32),
            np.zeros((0, 2), dtype=np.float32),
            np.zeros((0,), dtype=np.float32),
        )
    return (
        np.concatenate(points_xyz_accum, axis=0),
        np.concatenate(points_rgb_accum, axis=0),
        np.concatenate(point_image_indices_accum, axis=0),
        np.concatenate(point_xys_processed_accum, axis=0),
        np.concatenate(point_confidences_accum, axis=0),
    )


def _fuse_point_samples(
    *,
    points_xyz: np.ndarray,
    points_rgb: np.ndarray,
    point_image_indices: np.ndarray,
    point_xys_processed: np.ndarray,
    point_confidences: np.ndarray,
    max_points: int,
) -> tuple[np.ndarray, np.ndarray, list[list[tuple[int, np.ndarray]]]]:
    if len(points_xyz) == 0:
        return np.zeros((0, 3), dtype=np.float32), np.zeros((0, 3), dtype=np.uint8), []

    scene_min = points_xyz.min(axis=0)
    scene_max = points_xyz.max(axis=0)
    scene_diagonal = float(np.linalg.norm(scene_max - scene_min))
    voxel_size = max(scene_diagonal * 0.0025, 1e-3)

    clusters: dict[tuple[int, int, int], dict] = {}
    for xyz, rgb, image_index, processed_xy, confidence in zip(
        points_xyz,
        points_rgb,
        point_image_indices,
        point_xys_processed,
        point_confidences,
    ):
        if not np.isfinite(xyz).all():
            continue
        weight = float(confidence)
        if not np.isfinite(weight) or weight <= 0:
            weight = 1.0
        key = tuple(np.floor((xyz - scene_min) / voxel_size + 0.5).astype(np.int64).tolist())
        cluster = clusters.setdefault(
            key,
            {
                "weight_sum": 0.0,
                "xyz_sum": np.zeros(3, dtype=np.float64),
                "rgb_sum": np.zeros(3, dtype=np.float64),
                "observations": {},
            },
        )
        cluster["weight_sum"] += weight
        cluster["xyz_sum"] += xyz.astype(np.float64) * weight
        cluster["rgb_sum"] += rgb.astype(np.float64) * weight
        image_index = int(image_index)
        existing = cluster["observations"].get(image_index)
        if existing is None or weight > existing["weight"]:
            cluster["observations"][image_index] = {
                "xy": processed_xy.astype(np.float32),
                "weight": weight,
            }

    fused_entries: list[tuple[np.ndarray, np.ndarray, list[tuple[int, np.ndarray]], tuple[int, float]]] = []
    for cluster in clusters.values():
        observations = sorted(cluster["observations"].items())
        if not observations:
            continue
        weight_sum = max(cluster["weight_sum"], 1e-6)
        xyz = (cluster["xyz_sum"] / weight_sum).astype(np.float32)
        rgb = np.clip(cluster["rgb_sum"] / weight_sum, 0.0, 255.0).astype(np.uint8)
        track = [(image_index, obs["xy"]) for image_index, obs in observations]
        track_score = (
            len(track),
            float(sum(float(obs["weight"]) for _, obs in observations)),
        )
        fused_entries.append((xyz, rgb, track, track_score))

    fused_entries.sort(key=lambda entry: entry[3], reverse=True)
    if len(fused_entries) > max_points:
        fused_entries = fused_entries[:max_points]

    fused_points_xyz = np.stack([entry[0] for entry in fused_entries], axis=0) if fused_entries else np.zeros((0, 3), dtype=np.float32)
    fused_points_rgb = np.stack([entry[1] for entry in fused_entries], axis=0) if fused_entries else np.zeros((0, 3), dtype=np.uint8)
    fused_tracks = [entry[2] for entry in fused_entries]
    return fused_points_xyz, fused_points_rgb, fused_tracks


def _run_window(
    *,
    model,
    image_paths: list[Path],
    resolution: int,
    device: torch.device,
    memory_efficient_inference: bool,
    minibatch_size: int,
    use_amp: bool,
    point_budget: int,
) -> WindowResult:
    from mapanything.utils.geometry import closed_form_pose_inverse
    from mapanything.utils.image import load_images

    views = load_images([str(path) for path in image_paths], resolution_set=int(resolution))
    with torch.no_grad():
        outputs = model.infer(
            views,
            memory_efficient_inference=memory_efficient_inference,
            minibatch_size=minibatch_size,
            use_amp=use_amp,
            amp_dtype="bf16",
            apply_mask=True,
            mask_edges=True,
        )

    extrinsics = []
    intrinsics = []
    processed_sizes_wh: list[tuple[int, int]] = []
    for prediction in outputs:
        camera_pose = prediction["camera_poses"][0].detach().cpu().numpy()
        world_to_camera = closed_form_pose_inverse(camera_pose[None])[0]
        extrinsics.append(world_to_camera)
        intrinsics.append(prediction["intrinsics"][0].detach().cpu().numpy())
        processed_height, processed_width = (int(value) for value in prediction["pts3d"][0].shape[:2])
        processed_sizes_wh.append((processed_width, processed_height))

    points_xyz, points_rgb, point_image_indices, point_xys_processed, point_confidences = _collect_points_from_outputs(
        outputs,
        point_budget=point_budget,
    )

    del outputs
    gc.collect()
    _maybe_empty_cache(device)

    if not processed_sizes_wh:
        raise RuntimeError("MapAnything: unable to determine processed image size")

    return WindowResult(
        extrinsics_w2c=np.stack(extrinsics, axis=0),
        intrinsics_3x3=np.stack(intrinsics, axis=0),
        processed_sizes_wh=processed_sizes_wh,
        points_xyz=points_xyz,
        points_rgb=points_rgb,
        point_image_indices=point_image_indices,
        point_xys_processed=point_xys_processed,
        point_confidences=point_confidences,
    )


def _write_manifest(
    manifest_path: Path | None,
    *,
    mode: str,
    requested_device: str,
    selected_device: str,
    resolution: int,
    camera_type: str,
    shared_camera: bool,
    seed: int,
    max_points: int,
    total_images: int,
    anchor_paths: list[Path],
    windows: list[tuple[int, int]],
    requested_window_size: int,
    requested_window_overlap: int,
    window_size: int,
    window_overlap: int,
    window_reduction_count: int,
    raw_point_sample_count: int | None = None,
    fused_sparse_point_count: int | None = None,
    final_observation_count: int | None = None,
    mean_track_length: float | None = None,
    registered_image_count: int | None = None,
) -> None:
    if manifest_path is None:
        return
    payload = {
        "mode": mode,
        "requested_device": requested_device,
        "selected_device": selected_device,
        "resolution": resolution,
        "camera_type": camera_type,
        "shared_camera": shared_camera,
        "seed": seed,
        "max_points": max_points,
        "total_images": total_images,
        "anchor_image_count": len(anchor_paths),
        "requested_window_size": requested_window_size,
        "requested_window_overlap": requested_window_overlap,
        "window_size": window_size,
        "window_overlap": window_overlap,
        "window_reduction_count": window_reduction_count,
        "anchors": [path.name for path in anchor_paths],
        "windows": [
            {
                "start": start,
                "end": end,
                "images": [path.name for path in anchor_paths[start:end]],
            }
            for (start, end) in windows
        ],
    }
    if raw_point_sample_count is not None:
        payload["raw_point_sample_count"] = raw_point_sample_count
    if fused_sparse_point_count is not None:
        payload["fused_sparse_point_count"] = fused_sparse_point_count
    if final_observation_count is not None:
        payload["final_observation_count"] = final_observation_count
    if mean_track_length is not None:
        payload["mean_track_length"] = mean_track_length
    if registered_image_count is not None:
        payload["registered_image_count"] = registered_image_count
    _atomic_write_text(manifest_path, json.dumps(payload, indent=2) + "\n")


def _run_bridge(args: argparse.Namespace) -> int:
    images_dir = Path(args.images)
    out_sparse = Path(args.out_sparse)
    models_dir = Path(args.models_dir)
    checkpoint_dir = models_dir / args.checkpoint_subdir
    dinov2_weights_dir = models_dir / "dinov2"

    if not images_dir.exists():
        print(f"MapAnything: images dir not found: {images_dir}", file=sys.stderr)
        return 2
    if not checkpoint_dir.exists():
        print(f"MapAnything: checkpoint dir not found: {checkpoint_dir}", file=sys.stderr)
        return 2
    if not (checkpoint_dir / "config.json").exists():
        print(f"MapAnything: missing config.json in {checkpoint_dir}", file=sys.stderr)
        return 2
    if not (checkpoint_dir / "model.safetensors").exists():
        print(f"MapAnything: missing model.safetensors in {checkpoint_dir}", file=sys.stderr)
        return 2
    if not (dinov2_weights_dir / "dinov2_vitg14_pretrain.pth").exists():
        print(
            f"MapAnything: missing DINOv2 weights in {dinov2_weights_dir / 'dinov2_vitg14_pretrain.pth'}",
            file=sys.stderr,
        )
        return 2

    image_paths = _list_images(images_dir)
    if not image_paths:
        print(f"MapAnything: no supported images found in {images_dir}", file=sys.stderr)
        return 2
    try:
        _validate_args(args, image_count=len(image_paths))
    except ValueError as exc:
        print(f"MapAnything: {exc}", file=sys.stderr)
        return 2

    np.random.seed(args.seed)
    random.seed(args.seed)
    torch.manual_seed(args.seed)

    normalized_resolution = _normalize_resolution_set(args.resolution)
    if normalized_resolution != int(args.resolution):
        print(
            f"MapAnything: resolution_set={args.resolution} is unsupported; "
            f"using {normalized_resolution} instead.",
            file=sys.stderr,
        )
        args.resolution = normalized_resolution

    device = _select_device(args.device)
    if args.use_amp and device.type != "cuda":
        print("MapAnything: disabling AMP on non-CUDA device for stability.")
        args.use_amp = False

    restore_dinov2_loader = _install_offline_dinov2_loader(dinov2_weights_dir)

    try:
        from mapanything.models import MapAnything
    except Exception as exc:  # noqa: BLE001
        print(f"MapAnything: import failed: {exc}", file=sys.stderr)
        return 3

    print(f"MapAnything: loading model from {checkpoint_dir}")
    model = MapAnything.from_pretrained(str(checkpoint_dir)).to(device)
    model.eval()

    try:
        original_image_paths = list(image_paths)
        if args.mode == "seed_refine":
            anchor_paths = _downsample_paths_uniform(image_paths, target_count=max(2, args.anchor_max_views))
            current_window_size = max(2, args.window_size)
            current_overlap = max(0, args.window_overlap)
            windows = _plan_windows(len(anchor_paths), current_window_size, current_overlap)
        else:
            anchor_paths = image_paths
            current_window_size = len(anchor_paths)
            current_overlap = 0
            windows = [(0, len(anchor_paths))]
        window_reduction_count = 0
        if not windows:
            print("MapAnything: no windows planned for inference", file=sys.stderr)
            return 4

        _write_manifest(
            Path(args.manifest_out) if args.manifest_out else None,
            mode=args.mode,
            requested_device=args.device,
            selected_device=device.type,
            resolution=args.resolution,
            camera_type=args.camera_type,
            shared_camera=args.shared_camera,
            seed=args.seed,
            max_points=args.max_points,
            total_images=len(original_image_paths),
            anchor_paths=anchor_paths,
            windows=windows,
            requested_window_size=args.window_size,
            requested_window_overlap=args.window_overlap,
            window_size=current_window_size,
            window_overlap=current_overlap,
            window_reduction_count=window_reduction_count,
        )

        print(
            f"MapAnything: device={device.type} mode={args.mode} "
            f"images={len(original_image_paths)} anchors={len(anchor_paths)} "
            f"window={current_window_size} overlap={current_overlap}"
        )

        global_extrinsics: list[np.ndarray | None] = [None] * len(anchor_paths)
        global_intrinsics: list[np.ndarray | None] = [None] * len(anchor_paths)
        global_sizes: list[tuple[int, int] | None] = [None] * len(anchor_paths)
        global_processed_sizes: list[tuple[int, int] | None] = [None] * len(anchor_paths)
        points_xyz_accum: list[np.ndarray] = []
        points_rgb_accum: list[np.ndarray] = []
        point_image_indices_accum: list[np.ndarray] = []
        point_xys_processed_accum: list[np.ndarray] = []
        point_confidences_accum: list[np.ndarray] = []

        window_index = 0
        while window_index < len(windows):
            start, end = windows[window_index]
            window_paths = anchor_paths[start:end]
            point_budget = max(1, args.max_points // max(1, len(windows)))
            print(f"MapAnything: window {window_index + 1}/{len(windows)} anchors[{start}:{end}]")
            try:
                result = _run_window(
                    model=model,
                    image_paths=window_paths,
                    resolution=args.resolution,
                    device=device,
                    memory_efficient_inference=args.memory_efficient_inference,
                    minibatch_size=args.minibatch_size,
                    use_amp=args.use_amp,
                    point_budget=point_budget,
                )
            except RuntimeError as exc:
                message = str(exc)
                if args.mode == "seed_refine" and device.type == "mps" and current_window_size > 2 and (
                    "invalid buffer size" in message.lower()
                    or "out of memory" in message.lower()
                    or "mps" in message.lower()
                ):
                    current_window_size = max(2, current_window_size - 1)
                    current_overlap = min(current_overlap, max(0, current_window_size - 1))
                    window_reduction_count += 1
                    windows = _plan_windows(len(anchor_paths), current_window_size, current_overlap)
                    print(
                        "MapAnything: reducing window size due to MPS memory pressure "
                        f"(window={current_window_size}, overlap={current_overlap})",
                        file=sys.stderr,
                    )
                    _write_manifest(
                        Path(args.manifest_out) if args.manifest_out else None,
                        mode=args.mode,
                        requested_device=args.device,
                        selected_device=device.type,
                        resolution=args.resolution,
                        camera_type=args.camera_type,
                        shared_camera=args.shared_camera,
                        seed=args.seed,
                        max_points=args.max_points,
                        total_images=len(original_image_paths),
                        anchor_paths=anchor_paths,
                        windows=windows,
                        requested_window_size=args.window_size,
                        requested_window_overlap=args.window_overlap,
                        window_size=current_window_size,
                        window_overlap=current_overlap,
                        window_reduction_count=window_reduction_count,
                    )
                    global_extrinsics = [None] * len(anchor_paths)
                    global_intrinsics = [None] * len(anchor_paths)
                    global_sizes = [None] * len(anchor_paths)
                    global_processed_sizes = [None] * len(anchor_paths)
                    points_xyz_accum = []
                    points_rgb_accum = []
                    point_image_indices_accum = []
                    point_xys_processed_accum = []
                    point_confidences_accum = []
                    window_index = 0
                    _maybe_empty_cache(device)
                    continue
                raise

            original_sizes = _load_original_sizes(window_paths)
            if start == 0:
                scale = 1.0
                rotation_align = np.eye(3, dtype=np.float64)
                translation_align = np.zeros(3, dtype=np.float64)
            else:
                overlap_start = start
                overlap_end = min(end, start + min(current_overlap, max(0, end - start - 1)))
                overlap_indices = [index for index in range(overlap_start, overlap_end) if global_extrinsics[index] is not None]
                if len(overlap_indices) < 1:
                    fallback = start - 1
                    overlap_indices = [fallback] if fallback >= 0 and global_extrinsics[fallback] is not None else []

                if not overlap_indices:
                    print("MapAnything: warning: missing overlap poses; continuing without alignment", file=sys.stderr)
                    scale = 1.0
                    rotation_align = np.eye(3, dtype=np.float64)
                    translation_align = np.zeros(3, dtype=np.float64)
                else:
                    local_indices = [index - start for index in overlap_indices]
                    chunk_overlap = result.extrinsics_w2c[local_indices]
                    global_overlap = np.stack([global_extrinsics[index] for index in overlap_indices if global_extrinsics[index] is not None], axis=0)
                    scale, rotation_align, translation_align = _estimate_similarity_from_overlap(chunk_overlap, global_overlap)

            transformed_extrinsics = _transform_extrinsics_w2c(
                result.extrinsics_w2c,
                scale=scale,
                rotation_align=rotation_align,
                translation_align=translation_align,
            )
            transformed_points = _transform_points_xyz(
                result.points_xyz,
                scale=scale,
                rotation_align=rotation_align,
                translation_align=translation_align,
            )

            for local_index, global_index in enumerate(range(start, end)):
                if global_extrinsics[global_index] is None:
                    global_extrinsics[global_index] = transformed_extrinsics[local_index]
                if global_intrinsics[global_index] is None:
                    global_intrinsics[global_index] = result.intrinsics_3x3[local_index]
                if global_sizes[global_index] is None:
                    global_sizes[global_index] = original_sizes[local_index]
                if global_processed_sizes[global_index] is None:
                    global_processed_sizes[global_index] = result.processed_sizes_wh[local_index]

            if len(transformed_points) > 0:
                points_xyz_accum.append(transformed_points.astype(np.float32))
                points_rgb_accum.append(result.points_rgb.astype(np.uint8))
                point_image_indices_accum.append((result.point_image_indices + start).astype(np.int32))
                point_xys_processed_accum.append(result.point_xys_processed.astype(np.float32))
                point_confidences_accum.append(result.point_confidences.astype(np.float32))

            window_index += 1

        if (
            any(value is None for value in global_extrinsics)
            or any(value is None for value in global_intrinsics)
            or any(value is None for value in global_sizes)
            or any(value is None for value in global_processed_sizes)
        ):
            print("MapAnything: internal error: incomplete pose coverage", file=sys.stderr)
            return 4

        extrinsic_all = np.stack([value for value in global_extrinsics if value is not None], axis=0)
        intrinsic_all = np.stack([value for value in global_intrinsics if value is not None], axis=0)
        original_sizes_wh = [value for value in global_sizes if value is not None]
        processed_sizes_wh = [value for value in global_processed_sizes if value is not None]

        if points_xyz_accum:
            points_xyz = np.concatenate(points_xyz_accum, axis=0)
            points_rgb = np.concatenate(points_rgb_accum, axis=0)
            point_image_indices = np.concatenate(point_image_indices_accum, axis=0)
            point_xys_processed = np.concatenate(point_xys_processed_accum, axis=0)
            point_confidences = np.concatenate(point_confidences_accum, axis=0)
        else:
            points_xyz = np.zeros((0, 3), dtype=np.float32)
            points_rgb = np.zeros((0, 3), dtype=np.uint8)
            point_image_indices = np.zeros((0,), dtype=np.int32)
            point_xys_processed = np.zeros((0, 2), dtype=np.float32)
            point_confidences = np.zeros((0,), dtype=np.float32)

        if len(points_xyz) == 0:
            print("MapAnything: produced 0 valid points after filtering", file=sys.stderr)
            return 4

        points_xyz, points_rgb, point_tracks = _fuse_point_samples(
            points_xyz=points_xyz,
            points_rgb=points_rgb,
            point_image_indices=point_image_indices,
            point_xys_processed=point_xys_processed,
            point_confidences=point_confidences,
            max_points=args.max_points,
        )

        if len(points_xyz) == 0:
            print("MapAnything: fused point cloud is empty after track generation", file=sys.stderr)
            return 4

        mean_track_length = float(sum(len(track) for track in point_tracks)) / float(len(point_tracks))
        print(
            "MapAnything: fused "
            f"{len(point_image_indices)} samples into {len(point_tracks)} sparse points "
            f"(mean_track_length={mean_track_length:.2f})"
        )

        target_paths = anchor_paths if args.mode == "seed_refine" else original_image_paths
        if args.mode == "direct" and len(target_paths) != len(extrinsic_all):
            print("MapAnything: direct mode pose/image count mismatch", file=sys.stderr)
            return 4

        _write_manifest(
            Path(args.manifest_out) if args.manifest_out else None,
            mode=args.mode,
            requested_device=args.device,
            selected_device=device.type,
            resolution=args.resolution,
            camera_type=args.camera_type,
            shared_camera=args.shared_camera,
            seed=args.seed,
            max_points=args.max_points,
            total_images=len(original_image_paths),
            anchor_paths=anchor_paths,
            windows=windows,
            requested_window_size=args.window_size,
            requested_window_overlap=args.window_overlap,
            window_size=current_window_size,
            window_overlap=current_overlap,
            window_reduction_count=window_reduction_count,
            raw_point_sample_count=int(len(point_image_indices)),
            fused_sparse_point_count=int(len(point_tracks)),
            final_observation_count=int(sum(len(track) for track in point_tracks)),
            mean_track_length=mean_track_length,
            registered_image_count=len(target_paths),
        )

        print(f"MapAnything: writing COLMAP model to {out_sparse} (images={len(target_paths)}, points={len(points_xyz)})")
        out_sparse.parent.mkdir(parents=True, exist_ok=True)
        staging_dir = Path(tempfile.mkdtemp(prefix=f"{out_sparse.name}.tmp-", dir=str(out_sparse.parent)))
        try:
            _write_colmap_text_model(
                out_dir=staging_dir,
                image_paths=target_paths,
                extrinsics_w2c=extrinsic_all,
                intrinsics_3x3=intrinsic_all,
                original_sizes_wh=original_sizes_wh,
                processed_sizes_wh=processed_sizes_wh,
                camera_type=args.camera_type,
                shared_camera=args.shared_camera,
                points_xyz=points_xyz,
                points_rgb=points_rgb,
                point_tracks=point_tracks,
            )
            _replace_output_dir_atomically(staging_dir, out_sparse)
        finally:
            if staging_dir.exists():
                shutil.rmtree(staging_dir, ignore_errors=True)

        print("MapAnything: done")
        return 0
    finally:
        restore_dinov2_loader()
        del model
        gc.collect()
        _maybe_empty_cache(device)


def build_arg_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="EasySplat MapAnything -> COLMAP sparse model bridge")
    default_models_dir = _default_models_dir()
    parser.add_argument("--images", required=True, help="Directory containing input images (selected frames).")
    parser.add_argument("--out-sparse", required=True, help="Output directory for COLMAP sparse model.")
    parser.add_argument(
        "--models-dir",
        default=default_models_dir,
        required=default_models_dir is None,
        help="Directory containing the packaged MapAnything weights.",
    )
    parser.add_argument("--device", default=os.environ.get("EASYSPLAT_MAPANYTHING_DEVICE", "mps"))
    parser.add_argument("--mode", choices=["direct", "seed_refine"], default="direct")
    parser.add_argument("--checkpoint-subdir", default=os.environ.get("EASYSPLAT_MAPANYTHING_CHECKPOINT", "map-anything-apache"))
    parser.add_argument("--resolution", type=int, default=_env_int("EASYSPLAT_MAPANYTHING_RESOLUTION", 518, minimum=1))
    parser.set_defaults(memory_efficient_inference=_env_bool("EASYSPLAT_MAPANYTHING_MEMORY_EFFICIENT", True))
    parser.add_argument(
        "--memory-efficient-inference",
        dest="memory_efficient_inference",
        action="store_true",
        help="Enable MapAnything's memory-efficient inference path.",
    )
    parser.add_argument(
        "--no-memory-efficient-inference",
        dest="memory_efficient_inference",
        action="store_false",
        help="Disable MapAnything's memory-efficient inference path.",
    )
    parser.add_argument("--minibatch-size", type=int, default=_env_int("EASYSPLAT_MAPANYTHING_MINIBATCH_SIZE", 1, minimum=1))
    parser.add_argument("--use-amp", action="store_true", default=_env_bool("EASYSPLAT_MAPANYTHING_USE_AMP", False))
    parser.add_argument("--max-points", type=int, default=_env_int("EASYSPLAT_MAPANYTHING_MAX_POINTS", 120000, minimum=1))
    parser.add_argument("--camera-type", default=_env_choice("EASYSPLAT_MAPANYTHING_CAMERA_TYPE", "SIMPLE_RADIAL", SUPPORTED_CAMERA_TYPES))
    parser.add_argument("--shared-camera", action="store_true", default=_env_bool("EASYSPLAT_MAPANYTHING_SHARED_CAMERA", False))
    parser.add_argument("--anchor-max-views", type=int, default=_env_int("EASYSPLAT_MAPANYTHING_ANCHOR_MAX_VIEWS", 64, minimum=1))
    parser.add_argument("--window-size", type=int, default=_env_int("EASYSPLAT_MAPANYTHING_WINDOW_SIZE", 6, minimum=1))
    parser.add_argument("--window-overlap", type=int, default=_env_int("EASYSPLAT_MAPANYTHING_WINDOW_OVERLAP", 2, minimum=0))
    parser.add_argument(
        "--manifest-out",
        "--coverage-manifest",
        dest="manifest_out",
        default=None,
        help="Optional JSON output describing anchor/window coverage.",
    )
    parser.add_argument("--seed", type=int, default=42)
    return parser


def main(argv: list[str] | None = None) -> int:
    try:
        parser = build_arg_parser()
        args = parser.parse_args(argv)
        return _run_bridge(args)
    except ValueError as exc:
        print(f"MapAnything: {exc}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
