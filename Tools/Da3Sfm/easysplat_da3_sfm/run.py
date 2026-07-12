from __future__ import annotations

import argparse
import gc
import json
import os
import shutil
import sys
from pathlib import Path
from typing import Any

import numpy as np
from PIL import Image, ImageOps

from .alignment import (
    MIN_ALIGNMENT_ANCHORS,
    MIN_ORIENTED_ALIGNMENT_ANCHORS,
    MIN_WINDOW_SIZE,
    align_w2c_poses as _align_w2c_poses,
    build_retrieval_graph as _build_retrieval_graph,
    camera_centers_from_w2c as _camera_centers_from_w2c,
    estimate_sim3 as _estimate_sim3,
    estimate_oriented_sim3 as _estimate_oriented_sim3,
    plan_continuous_batches as _plan_continuous_batches,
    plan_unordered_batches as _plan_unordered_batches,
    select_anchor_indices as _select_anchor_indices,
    validate_common_view_rotations as _validate_common_view_rotations,
)

SUPPORTED_CAMERA_TYPES = ("SIMPLE_RADIAL", "SIMPLE_PINHOLE", "PINHOLE", "OPENCV", "OPENCV_FISHEYE")
IMAGE_EXTENSIONS = (".jpg", ".jpeg", ".png")
OOM_MARKERS = ("out of memory", "mps backend out of memory", "allocation failed")


def _default_models_dir() -> str | None:
    env_path = os.environ.get("EASYSPLAT_DA3_MODELS_DIR")
    if env_path and env_path.strip():
        return env_path.strip()
    packaged_models = Path(__file__).resolve().parents[2] / "models"
    if packaged_models.exists():
        return str(packaged_models)
    return None


def _list_images(images_dir: Path) -> list[Path]:
    return sorted(path for path in images_dir.iterdir() if path.is_file() and path.suffix.lower() in IMAGE_EXTENSIONS)


def _compute_image_descriptors(image_paths: list[Path]) -> np.ndarray:
    descriptors: list[np.ndarray] = []
    for image_path in image_paths:
        with Image.open(image_path) as source:
            image = ImageOps.exif_transpose(source).convert("RGB").resize((16, 16), Image.Resampling.BILINEAR)
            rgb = np.asarray(image, dtype=np.float64) / 255.0
        luminance = rgb @ np.array([0.2126, 0.7152, 0.0722], dtype=np.float64)
        centered = luminance - float(np.mean(luminance))
        centered /= max(float(np.std(centered)), 0.05)
        gradient_x = np.diff(luminance, axis=1, append=luminance[:, -1:])
        gradient_y = np.diff(luminance, axis=0, append=luminance[-1:, :])
        histograms = []
        for channel in range(3):
            histogram, _ = np.histogram(rgb[:, :, channel], bins=8, range=(0.0, 1.0))
            histograms.append(histogram.astype(np.float64) / rgb[:, :, channel].size)
        descriptor = np.concatenate([
            centered.reshape(-1) * 0.5,
            gradient_x.reshape(-1) * 0.25,
            gradient_y.reshape(-1) * 0.25,
            np.concatenate(histograms),
        ])
        norm = float(np.linalg.norm(descriptor))
        if not np.isfinite(norm) or norm <= np.finfo(np.float64).eps:
            raise ValueError(f"could not compute a usable retrieval descriptor for {image_path.name}")
        descriptors.append(descriptor / norm)
    return np.stack(descriptors)


def _select_device(requested: str) -> str:
    normalized = requested.strip().lower()
    if normalized == "mps":
        try:
            import torch

            if torch.backends.mps.is_available():
                return "mps"
            print("DA3: requested mps but MPS is unavailable; falling back to cpu", file=sys.stderr)
            return "cpu"
        except Exception as exc:  # noqa: BLE001
            print(f"DA3: torch MPS probe failed ({exc}); falling back to cpu", file=sys.stderr)
            return "cpu"
    if normalized == "cuda":
        print("DA3: CUDA is not an EasySplat hot-path device on macOS; falling back to cpu", file=sys.stderr)
        return "cpu"
    return normalized or "cpu"


def _model_path(models_dir: Path, subdir: str) -> Path:
    candidate = models_dir / subdir
    if not candidate.is_dir():
        raise FileNotFoundError(f"DA3 model directory missing: {candidate}")
    if not (candidate / "config.json").is_file():
        raise FileNotFoundError(f"DA3 model config missing: {candidate / 'config.json'}")
    if not (candidate / "model.safetensors").is_file():
        raise FileNotFoundError(f"DA3 model weights missing: {candidate / 'model.safetensors'}")
    return candidate


def _is_memory_error(error: BaseException) -> bool:
    text = str(error).lower()
    return any(marker in text for marker in OOM_MARKERS)


def _remove_path(path: Path) -> None:
    if not path.exists() and not path.is_symlink():
        return
    if path.is_dir() and not path.is_symlink():
        shutil.rmtree(path, ignore_errors=True)
    else:
        path.unlink(missing_ok=True)


def _rotmat_to_quat_wxyz(rot: np.ndarray) -> np.ndarray:
    trace = float(rot[0, 0] + rot[1, 1] + rot[2, 2])
    if trace > 0.0:
        scale = np.sqrt(trace + 1.0) * 2.0
        quat = np.array([
            0.25 * scale,
            (rot[2, 1] - rot[1, 2]) / scale,
            (rot[0, 2] - rot[2, 0]) / scale,
            (rot[1, 0] - rot[0, 1]) / scale,
        ])
    elif rot[0, 0] > rot[1, 1] and rot[0, 0] > rot[2, 2]:
        scale = np.sqrt(1.0 + rot[0, 0] - rot[1, 1] - rot[2, 2]) * 2.0
        quat = np.array([
            (rot[2, 1] - rot[1, 2]) / scale,
            0.25 * scale,
            (rot[0, 1] + rot[1, 0]) / scale,
            (rot[0, 2] + rot[2, 0]) / scale,
        ])
    elif rot[1, 1] > rot[2, 2]:
        scale = np.sqrt(1.0 + rot[1, 1] - rot[0, 0] - rot[2, 2]) * 2.0
        quat = np.array([
            (rot[0, 2] - rot[2, 0]) / scale,
            (rot[0, 1] + rot[1, 0]) / scale,
            0.25 * scale,
            (rot[1, 2] + rot[2, 1]) / scale,
        ])
    else:
        scale = np.sqrt(1.0 + rot[2, 2] - rot[0, 0] - rot[1, 1]) * 2.0
        quat = np.array([
            (rot[1, 0] - rot[0, 1]) / scale,
            (rot[0, 2] + rot[2, 0]) / scale,
            (rot[1, 2] + rot[2, 1]) / scale,
            0.25 * scale,
        ])
    norm = np.linalg.norm(quat)
    if norm > 0:
        quat = quat / norm
    return quat


def _validate_pinhole_intrinsics(intrinsics: np.ndarray) -> np.ndarray:
    matrix = np.asarray(intrinsics, dtype=np.float64)
    if matrix.shape != (3, 3) or not np.all(np.isfinite(matrix)):
        raise ValueError("DA3 intrinsics must be a finite 3x3 pinhole matrix")
    if matrix[0, 0] <= 0.0 or matrix[1, 1] <= 0.0:
        raise ValueError("DA3 intrinsics focal lengths must be positive")
    if (
        abs(float(matrix[0, 1])) > 1e-6
        or abs(float(matrix[1, 0])) > 1e-6
        or not np.allclose(matrix[2, :], np.array([0.0, 0.0, 1.0]), atol=1e-6, rtol=0.0)
    ):
        raise ValueError("DA3 intrinsics must use canonical zero-skew pinhole form")
    return matrix


def _camera_params(
    intrinsics: np.ndarray,
    size: tuple[int, int],
    camera_type: str,
    source_size: tuple[int, int] | None = None,
) -> list[float]:
    intrinsics = _validate_pinhole_intrinsics(intrinsics)
    width, height = size
    source_width, source_height = source_size or size
    scale_x = width / max(1.0, float(source_width))
    scale_y = height / max(1.0, float(source_height))
    with np.errstate(over="ignore", invalid="ignore"):
        fx = float(intrinsics[0, 0]) * scale_x
        fy = float(intrinsics[1, 1]) * scale_y
        cx = float(intrinsics[0, 2]) * scale_x
        cy = float(intrinsics[1, 2]) * scale_y
    if camera_type == "PINHOLE":
        params = [fx, fy, cx, cy]
        focal_values = params[:2]
    elif camera_type == "SIMPLE_PINHOLE":
        params = [(fx + fy) / 2.0, cx, cy]
        focal_values = params[:1]
    elif camera_type == "SIMPLE_RADIAL":
        params = [(fx + fy) / 2.0, cx, cy, 0.0]
        focal_values = params[:1]
    elif camera_type in ("OPENCV", "OPENCV_FISHEYE"):
        params = [fx, fy, cx, cy, 0.0, 0.0, 0.0, 0.0]
        focal_values = params[:2]
    else:
        raise ValueError(f"Unsupported camera type: {camera_type}")
    if not np.all(np.isfinite(params)) or any(value <= 0.0 for value in focal_values):
        raise ValueError("DA3 scaled camera parameters must be finite with positive focal length")
    return params


def _prediction_value(prediction: dict[str, Any], *names: str) -> Any | None:
    for name in names:
        if isinstance(prediction, dict) and name in prediction:
            return prediction[name]
        if not isinstance(prediction, dict) and hasattr(prediction, name):
            return getattr(prediction, name)
    return None


def _as_numpy(value: Any) -> np.ndarray:
    if hasattr(value, "detach"):
        value = value.detach().cpu().numpy()
    return np.asarray(value)


def _pad_view_axis(values: np.ndarray, count: int) -> np.ndarray:
    if values.shape[0] >= count:
        return values[:count]
    if values.shape[0] == 0:
        raise ValueError("DA3 prediction returned an empty view axis")
    padding = np.repeat(values[-1:, ...], count - values.shape[0], axis=0)
    return np.concatenate([values, padding], axis=0)


def _require_view_axis(values: np.ndarray, count: int, label: str) -> np.ndarray:
    if values.shape[0] != count:
        raise ValueError(f"DA3 prediction {label} count {values.shape[0]} did not match image count {count}")
    return values


def _extrinsics_w2c(values: Any, count: int) -> np.ndarray:
    if values is None:
        return np.repeat(np.eye(4, dtype=np.float64)[None, ...], count, axis=0)
    extrinsics = _as_numpy(values)
    if extrinsics.ndim != 3:
        return np.repeat(np.eye(4, dtype=np.float64)[None, ...], count, axis=0)
    if extrinsics.shape[1:] == (4, 4):
        return _pad_view_axis(extrinsics.astype(np.float64), count)
    if extrinsics.shape[1:] == (3, 4):
        padded = np.repeat(np.eye(4, dtype=np.float64)[None, ...], extrinsics.shape[0], axis=0)
        padded[:, :3, :] = extrinsics.astype(np.float64)
        return _pad_view_axis(padded, count)
    return np.repeat(np.eye(4, dtype=np.float64)[None, ...], count, axis=0)


def _exact_prediction_geometry(
    prediction: Any,
    count: int,
) -> tuple[np.ndarray, np.ndarray, np.ndarray, np.ndarray, list[tuple[int, int]]]:
    extrinsics_value = _prediction_value(prediction, "extrinsics", "extrinsics_w2c", "poses")
    intrinsics_value = _prediction_value(prediction, "intrinsics", "intrinsics_3x3")
    if extrinsics_value is None:
        raise ValueError("DA3 seed prediction did not include w2c poses")
    if intrinsics_value is None:
        raise ValueError("DA3 seed prediction did not include intrinsics")

    extrinsics = _as_numpy(extrinsics_value).astype(np.float64)
    if extrinsics.ndim != 3:
        raise ValueError("DA3 seed prediction poses had an invalid shape")
    if extrinsics.shape[1:] == (3, 4):
        padded = np.repeat(np.eye(4, dtype=np.float64)[None, ...], extrinsics.shape[0], axis=0)
        padded[:, :3, :] = extrinsics
        extrinsics = padded
    if extrinsics.shape[1:] != (4, 4):
        raise ValueError("DA3 seed prediction poses must be 3x4 or 4x4 matrices")
    extrinsics = _require_view_axis(extrinsics, count, "pose")

    intrinsics = _as_numpy(intrinsics_value).astype(np.float64)
    if intrinsics.ndim != 3 or intrinsics.shape[1:] != (3, 3):
        raise ValueError("DA3 seed prediction intrinsics must have shape Nx3x3")
    intrinsics = _require_view_axis(intrinsics, count, "intrinsics")
    intrinsics = np.stack([_validate_pinhole_intrinsics(matrix) for matrix in intrinsics])
    if not np.all(np.isfinite(extrinsics)):
        raise ValueError("DA3 seed prediction poses must be finite")
    rotations = extrinsics[:, :3, :3]
    determinants = np.linalg.det(rotations)
    gram_matrices = rotations @ np.transpose(rotations, (0, 2, 1))
    identity = np.eye(3, dtype=np.float64)[None, ...]
    rigid_bottom_rows = np.all(np.abs(extrinsics[:, 3, :] - np.array([0.0, 0.0, 0.0, 1.0])) <= 1e-6)
    if (
        np.any(~np.isfinite(determinants))
        or np.any(np.abs(determinants - 1.0) > 1e-3)
        or np.any(np.abs(gram_matrices - identity) > 1e-3)
        or not rigid_bottom_rows
    ):
        raise ValueError("DA3 seed prediction contained a non-rigid camera rotation")

    depth_value = _prediction_value(prediction, "depth")
    confidence_value = _prediction_value(prediction, "conf", "confidence", "depth_conf")
    if depth_value is None:
        raise ValueError("DA3 seed prediction did not include depth")
    if confidence_value is None:
        raise ValueError("DA3 seed prediction did not include depth confidence")
    depth = _require_view_axis(_as_numpy(depth_value), count, "depth")
    confidence = _require_view_axis(_as_numpy(confidence_value), count, "confidence")
    depth_views: list[np.ndarray] = []
    confidence_views: list[np.ndarray] = []
    processed_sizes: list[tuple[int, int]] = []
    for index in range(count):
        depth_view = np.squeeze(depth[index]).astype(np.float64)
        confidence_view = np.squeeze(confidence[index]).astype(np.float64)
        if depth_view.ndim != 2 or depth_view.shape[0] <= 0 or depth_view.shape[1] <= 0:
            raise ValueError("DA3 seed prediction depth had an invalid per-view shape")
        if confidence_view.shape != depth_view.shape:
            raise ValueError("DA3 seed prediction confidence shape did not match depth")
        if not np.any(np.isfinite(depth_view) & (depth_view > 0.0)):
            raise ValueError("DA3 seed prediction depth had no finite positive samples")
        if not np.any(np.isfinite(confidence_view)):
            raise ValueError("DA3 seed prediction confidence had no finite samples")
        depth_views.append(depth_view)
        confidence_views.append(confidence_view)
        processed_sizes.append((int(depth_view.shape[1]), int(depth_view.shape[0])))
    return (
        extrinsics,
        intrinsics,
        np.stack(depth_views),
        np.stack(confidence_views),
        processed_sizes,
    )


def _sample_depth_points(
    image_path: Path,
    depth: np.ndarray,
    confidence: np.ndarray,
    intrinsics: np.ndarray,
    extrinsics_w2c: np.ndarray,
    *,
    maximum_samples: int,
    confidence_percentile: float = 40.0,
) -> tuple[np.ndarray, np.ndarray, np.ndarray]:
    depth_map = np.asarray(depth, dtype=np.float64)
    confidence_map = np.asarray(confidence, dtype=np.float64)
    intrinsic = _validate_pinhole_intrinsics(intrinsics)
    pose = np.asarray(extrinsics_w2c, dtype=np.float64)
    if depth_map.ndim != 2 or confidence_map.shape != depth_map.shape:
        raise ValueError("depth and confidence maps must have the same 2D shape")
    if pose.shape != (4, 4) or not np.all(np.isfinite(pose)):
        raise ValueError("depth sampling requires one finite 4x4 w2c pose")
    if maximum_samples < 1:
        raise ValueError("maximum depth sample count must be positive")
    if not np.isfinite(confidence_percentile) or not 0.0 <= confidence_percentile < 100.0:
        raise ValueError("confidence percentile must be in [0, 100)")

    valid = np.isfinite(depth_map) & (depth_map > 0.0) & np.isfinite(confidence_map)
    if not np.any(valid):
        return (
            np.empty((0, 3), dtype=np.float64),
            np.empty((0, 3), dtype=np.uint8),
            np.empty((0,), dtype=np.float64),
        )
    valid_depth = depth_map[valid]
    if valid_depth.size >= 32:
        near, far = np.quantile(valid_depth, [0.01, 0.99])
        valid &= (depth_map >= near) & (depth_map <= far)
    confidence_floor = float(np.percentile(confidence_map[valid], confidence_percentile))
    valid &= confidence_map >= confidence_floor
    coordinates = np.argwhere(valid)
    if coordinates.shape[0] > maximum_samples:
        selection = np.linspace(0, coordinates.shape[0] - 1, maximum_samples, dtype=np.int64)
        coordinates = coordinates[selection]
    if coordinates.size == 0:
        return (
            np.empty((0, 3), dtype=np.float64),
            np.empty((0, 3), dtype=np.uint8),
            np.empty((0,), dtype=np.float64),
        )

    rows = coordinates[:, 0]
    columns = coordinates[:, 1]
    z = depth_map[rows, columns]
    camera_points = np.column_stack((
        (columns.astype(np.float64) - intrinsic[0, 2]) * z / intrinsic[0, 0],
        (rows.astype(np.float64) - intrinsic[1, 2]) * z / intrinsic[1, 1],
        z,
    ))
    rotation = pose[:3, :3]
    translation = pose[:3, 3]
    world_points = (rotation.T @ (camera_points - translation).T).T

    height, width = depth_map.shape
    with Image.open(image_path) as source:
        rgb = ImageOps.exif_transpose(source).convert("RGB").resize(
            (width, height),
            Image.Resampling.BILINEAR,
        )
        colors = np.asarray(rgb, dtype=np.uint8)[rows, columns]
    return world_points, colors, confidence_map[rows, columns]


def _fuse_depth_points(
    points: np.ndarray,
    colors: np.ndarray,
    confidence: np.ndarray,
    *,
    maximum_points: int,
    voxel_size: float | None = None,
) -> tuple[np.ndarray, np.ndarray]:
    point_array = np.asarray(points, dtype=np.float64)
    color_array = np.asarray(colors, dtype=np.float64)
    weights = np.asarray(confidence, dtype=np.float64)
    if point_array.ndim != 2 or point_array.shape[1:] != (3,):
        raise ValueError("learned point array must have shape Nx3")
    if color_array.shape != point_array.shape or weights.shape != (point_array.shape[0],):
        raise ValueError("learned colors and confidence must align with points")
    if maximum_points < 1:
        raise ValueError("maximum fused point count must be positive")
    valid = (
        np.all(np.isfinite(point_array), axis=1)
        & np.all(np.isfinite(color_array), axis=1)
        & np.isfinite(weights)
        & (weights > 0.0)
    )
    point_array = point_array[valid]
    color_array = color_array[valid]
    weights = weights[valid]
    if point_array.size == 0:
        return np.empty((0, 3), dtype=np.float64), np.empty((0, 3), dtype=np.uint8)

    lower, upper = np.quantile(point_array, [0.01, 0.99], axis=0)
    extent = np.maximum(upper - lower, 0.0)
    maximum_extent = max(float(np.max(extent)), np.finfo(np.float64).eps)
    if voxel_size is None:
        stable_extent = np.maximum(extent, maximum_extent * 0.01)
        volume = float(np.prod(stable_extent))
        voxel_size = max((volume / maximum_points) ** (1.0 / 3.0), maximum_extent / 4096.0)
    if not np.isfinite(voxel_size) or voxel_size <= 0.0:
        raise ValueError("voxel size must be positive and finite")

    origin = np.min(point_array, axis=0)
    keys = np.floor((point_array - origin) / voxel_size).astype(np.int64)
    _, inverse = np.unique(keys, axis=0, return_inverse=True)
    group_count = int(np.max(inverse)) + 1
    weight_sums = np.zeros(group_count, dtype=np.float64)
    point_sums = np.zeros((group_count, 3), dtype=np.float64)
    color_sums = np.zeros((group_count, 3), dtype=np.float64)
    np.add.at(weight_sums, inverse, weights)
    np.add.at(point_sums, inverse, point_array * weights[:, None])
    np.add.at(color_sums, inverse, color_array * weights[:, None])
    fused_points = point_sums / weight_sums[:, None]
    fused_colors = np.clip(np.rint(color_sums / weight_sums[:, None]), 0, 255).astype(np.uint8)

    if fused_points.shape[0] > maximum_points:
        keep = np.argsort(-weight_sums, kind="stable")[:maximum_points]
        fused_points = fused_points[keep]
        fused_colors = fused_colors[keep]
    order = np.lexsort((fused_points[:, 2], fused_points[:, 1], fused_points[:, 0]))
    return fused_points[order], fused_colors[order]


def _write_seed_colmap(
    extrinsics_w2c: np.ndarray,
    intrinsics: np.ndarray,
    image_paths: list[Path],
    out_sparse: Path,
    camera_type: str,
    shared_camera: bool,
    processed_sizes: list[tuple[int, int]] | None = None,
    learned_points: tuple[np.ndarray, np.ndarray] | None = None,
) -> None:
    count = len(image_paths)
    poses = np.asarray(extrinsics_w2c, dtype=np.float64)
    intrinsics_np = np.asarray(intrinsics, dtype=np.float64)
    if poses.ndim != 3 or poses.shape[1:] != (4, 4):
        pose_count = poses.shape[0] if poses.ndim > 0 else 0
        raise ValueError(f"DA3 prediction pose count {pose_count} did not match image count {count}")
    poses = _require_view_axis(poses, count, "pose")
    if intrinsics_np.ndim != 3 or intrinsics_np.shape[1:] != (3, 3):
        intrinsic_count = intrinsics_np.shape[0] if intrinsics_np.ndim > 0 else 0
        raise ValueError(f"DA3 prediction intrinsics count {intrinsic_count} did not match image count {count}")
    intrinsics_np = _require_view_axis(intrinsics_np, count, "intrinsics")
    if not np.all(np.isfinite(poses)) or not np.all(np.isfinite(intrinsics_np)):
        raise ValueError("DA3 seed poses and intrinsics must be finite")
    if len({path.name for path in image_paths}) != count:
        raise ValueError("DA3 seed image names must be unique")
    if processed_sizes is not None and len(processed_sizes) != count:
        raise ValueError("DA3 processed image size count did not match selected images")

    sizes: list[tuple[int, int]] = []
    for image_path in image_paths:
        with Image.open(image_path) as image:
            sizes.append(image.size)
    source_sizes = processed_sizes or sizes

    camera_lines: list[str] = []
    use_shared_camera = shared_camera and len(set(sizes)) == 1
    if use_shared_camera:
        params = np.mean([
            _camera_params(intrinsic, sizes[0], camera_type, source_size=source_size)
            for intrinsic, source_size in zip(intrinsics_np, source_sizes)
        ], axis=0)
        camera_lines.append(
            f"1 {camera_type} {sizes[0][0]} {sizes[0][1]} "
            + " ".join(str(float(value)) for value in params)
        )
    else:
        for camera_id, (intrinsic, size, source_size) in enumerate(
            zip(intrinsics_np, sizes, source_sizes),
            start=1,
        ):
            params = _camera_params(intrinsic, size, camera_type, source_size=source_size)
            camera_lines.append(
                f"{camera_id} {camera_type} {size[0]} {size[1]} "
                + " ".join(str(float(value)) for value in params)
            )

    _remove_path(out_sparse)
    out_sparse.mkdir(parents=True, exist_ok=True)
    (out_sparse / "cameras.txt").write_text(
        "# Camera list with one line per camera:\n"
        "#   CAMERA_ID, MODEL, WIDTH, HEIGHT, PARAMS[]\n"
        f"# Number of cameras: {len(camera_lines)}\n"
        + "\n".join(camera_lines)
        + "\n",
        encoding="utf-8",
    )
    with (out_sparse / "images.txt").open("w", encoding="utf-8") as handle:
        handle.write("# Image list with two lines per image:\n")
        handle.write("#   IMAGE_ID, QW, QX, QY, QZ, TX, TY, TZ, CAMERA_ID, NAME\n")
        handle.write("#   POINTS2D[] as (X, Y, POINT3D_ID)\n")
        handle.write(f"# Number of images: {count}\n")
        for index, (pose, image_path) in enumerate(zip(poses, image_paths), start=1):
            quat = _rotmat_to_quat_wxyz(pose[:3, :3])
            trans = pose[:3, 3]
            camera_id = 1 if use_shared_camera else index
            handle.write(
                f"{index} {quat[0]} {quat[1]} {quat[2]} {quat[3]} "
                f"{trans[0]} {trans[1]} {trans[2]} {camera_id} {image_path.name}\n\n"
            )
    (out_sparse / "points3D.txt").write_text(
        "# 3D point list with one line per point:\n"
        "#   POINT3D_ID, X, Y, Z, R, G, B, ERROR, TRACK[] as (IMAGE_ID, POINT2D_IDX)\n"
        "# Number of points: 0, mean track length: 0\n",
        encoding="utf-8",
    )
    learned_points_path = out_sparse / "learned_points3D.txt"
    _remove_path(learned_points_path)
    if learned_points is not None:
        points, colors = learned_points
        point_array = np.asarray(points, dtype=np.float64)
        color_array = np.asarray(colors)
        if (
            point_array.ndim != 2
            or point_array.shape[1:] != (3,)
            or color_array.shape != point_array.shape
            or not np.all(np.isfinite(point_array))
        ):
            raise ValueError("learned point sidecar must contain finite Nx3 points and colors")
        color_array = np.clip(np.rint(color_array), 0, 255).astype(np.uint8)
        with learned_points_path.open("w", encoding="utf-8") as handle:
            handle.write("# DA3 learned 3D point initializer. Points are intentionally untracked.\n")
            handle.write("# POINT3D_ID X Y Z R G B ERROR\n")
            handle.write(f"# Number of points: {point_array.shape[0]}\n")
            for point_id, (point, color) in enumerate(zip(point_array, color_array), start=1):
                handle.write(
                    f"{point_id} {point[0]} {point[1]} {point[2]} "
                    f"{int(color[0])} {int(color[1])} {int(color[2])} -1.0\n"
                )


def _write_manifest(
    manifest_path: Path,
    *,
    args: argparse.Namespace,
    image_paths: list[Path],
    selected_device: str,
    model_subdir: str,
    registered_image_count: int,
    alignment_evidence: dict[str, Any],
) -> None:
    image_count = len(image_paths)
    size = max(2, min(args.window_size, image_count))
    overlap = max(0, min(args.window_overlap, size - 1))
    windows: list[dict[str, Any]] = []
    for batch in alignment_evidence["batches"]:
        indices = [int(index) for index in batch]
        windows.append({
            "start": min(indices),
            "end": max(indices) + 1,
            "indices": indices,
            "images": [image_paths[index].name for index in indices],
        })
    payload = {
        "mode": "seed_refine",
        "requested_device": args.device,
        "selected_device": selected_device,
        "model_subdir": model_subdir,
        "fallback_model_subdir": args.fallback_model_subdir,
        "process_res": args.process_res,
        "camera_type": args.camera_type,
        "shared_camera": bool(args.shared_camera),
        "max_points": args.max_points,
        "total_images": image_count,
        "window_size": size,
        "window_overlap": overlap,
        "input_ordering": alignment_evidence.get("input_ordering", args.input_ordering),
        "windows": windows,
        "registered_image_count": registered_image_count,
        "native_colmap_export": False,
        "export_strategy": "aligned_pose_depth_seed",
    }
    anchor_indices = [int(index) for index in alignment_evidence.get("anchor_indices", [])]
    payload["anchor_image_names"] = [image_paths[index].name for index in anchor_indices]
    payload["alignment_edge_count"] = int(alignment_evidence["alignment_edge_count"])
    payload["max_alignment_rmse"] = float(alignment_evidence["max_alignment_rmse"])
    payload["alignment_complete"] = bool(alignment_evidence["alignment_complete"])
    payload["raw_point_sample_count"] = int(alignment_evidence["raw_point_sample_count"])
    payload["fused_sparse_point_count"] = int(alignment_evidence["fused_sparse_point_count"])
    manifest_path.parent.mkdir(parents=True, exist_ok=True)
    manifest_path.write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")


def _run_da3_model(
    args: argparse.Namespace,
    image_paths: list[Path],
    model_dir: Path,
    selected_device: str,
    out_sparse: Path,
) -> tuple[int, dict[str, Any]]:
    from depth_anything_3.api import DepthAnything3

    model: Any | None = None
    try:
        try:
            model = DepthAnything3.from_pretrained(str(model_dir), local_files_only=True)
        except TypeError:
            model = DepthAnything3.from_pretrained(str(model_dir))
        if hasattr(model, "to"):
            model = model.to(selected_device)

        return _run_da3_seed_refine(args, model, image_paths, selected_device, out_sparse)
    finally:
        model = None


def _run_da3_seed_refine(
    args: argparse.Namespace,
    model: Any,
    image_paths: list[Path],
    selected_device: str,
    out_sparse: Path,
) -> tuple[int, dict[str, Any]]:
    image_count = len(image_paths)
    window_size = min(image_count, max(MIN_WINDOW_SIZE, args.window_size))
    ordering = args.input_ordering
    if ordering == "automatic":
        ordering = "continuous"
    if ordering not in ("continuous", "unordered"):
        raise ValueError(f"Unsupported DA3 input ordering: {ordering}")

    if image_count <= window_size:
        batches = [list(range(image_count))]
    elif ordering == "continuous":
        batches = _plan_continuous_batches(image_count, window_size, args.window_overlap)
    else:
        descriptors = _compute_image_descriptors(image_paths)
        neighbor_graph = _build_retrieval_graph(
            descriptors,
            max_neighbors=min(8, image_count - 1),
        )
        batches = _plan_unordered_batches(
            image_count,
            window_size,
            neighbor_graph,
            args.window_overlap,
        )
    initial_batch = batches[0]
    global_poses: dict[int, np.ndarray] = {}
    global_intrinsics: dict[int, np.ndarray] = {}
    global_processed_sizes: dict[int, tuple[int, int]] = {}
    sampled_points: list[np.ndarray] = []
    sampled_colors: list[np.ndarray] = []
    sampled_confidence: list[np.ndarray] = []
    alignment_errors: list[float] = []

    total_batch_views = sum(len(batch) for batch in batches)
    raw_point_budget = min(args.max_points * 4, args.max_points + image_count * 128)
    samples_per_batch_view = max(1, int(np.ceil(raw_point_budget / total_batch_views)))

    def infer_batch(
        batch: list[int],
        batch_number: int,
    ) -> tuple[np.ndarray, np.ndarray, np.ndarray, np.ndarray, list[tuple[int, int]]]:
        if len(batch) != len(set(batch)):
            raise ValueError(f"DA3 alignment batch {batch_number} contained duplicate image indices")
        paths = [image_paths[index] for index in batch]
        prediction = _call_da3_inference(
            args,
            model,
            paths,
            selected_device,
        )
        return _exact_prediction_geometry(prediction, len(paths))

    def sample_batch(
        batch: list[int],
        poses: np.ndarray,
        intrinsics: np.ndarray,
        depths: np.ndarray,
        confidence: np.ndarray,
        depth_scale: float,
    ) -> None:
        for local_index, image_index in enumerate(batch):
            points, colors, weights = _sample_depth_points(
                image_paths[image_index],
                depths[local_index] * depth_scale,
                confidence[local_index],
                intrinsics[local_index],
                poses[local_index],
                maximum_samples=samples_per_batch_view,
            )
            if points.size == 0:
                continue
            sampled_points.append(points)
            sampled_colors.append(colors)
            sampled_confidence.append(weights)

    (
        first_poses,
        first_intrinsics,
        first_depths,
        first_confidence,
        first_processed_sizes,
    ) = infer_batch(initial_batch, 0)
    local_anchor_indices = _select_anchor_indices(_camera_centers_from_w2c(first_poses))
    anchor_indices = [initial_batch[index] for index in local_anchor_indices]
    sample_batch(
        initial_batch,
        first_poses,
        first_intrinsics,
        first_depths,
        first_confidence,
        1.0,
    )
    for local_index, image_index in enumerate(initial_batch):
        global_poses[image_index] = first_poses[local_index]
        global_intrinsics[image_index] = first_intrinsics[local_index]
        global_processed_sizes[image_index] = first_processed_sizes[local_index]

    for batch_number, batch in enumerate(batches[1:], start=1):
        (
            local_poses,
            local_intrinsics,
            local_depths,
            local_confidence,
            local_processed_sizes,
        ) = infer_batch(batch, batch_number)
        common = [image_index for image_index in batch if image_index in global_poses]
        if len(common) < MIN_ORIENTED_ALIGNMENT_ANCHORS:
            raise ValueError(
                f"DA3 alignment graph was disconnected at batch {batch_number}: "
                f"found {len(common)} common views, need {MIN_ORIENTED_ALIGNMENT_ANCHORS}"
            )
        local_positions = {image_index: local_index for local_index, image_index in enumerate(batch)}
        source_common_poses = np.stack([local_poses[local_positions[index]] for index in common])
        target_common_poses = np.stack([global_poses[index] for index in common])
        if len(common) >= MIN_ALIGNMENT_ANCHORS:
            source_centers = _camera_centers_from_w2c(source_common_poses)
            target_centers = _camera_centers_from_w2c(target_common_poses)
            try:
                scale, rotation, translation, normalized_rmse = _estimate_sim3(source_centers, target_centers)
            except ValueError as error:
                if "rank deficient" not in str(error):
                    raise
                scale, rotation, translation, normalized_rmse = _estimate_oriented_sim3(
                    source_common_poses,
                    target_common_poses,
                )
        else:
            scale, rotation, translation, normalized_rmse = _estimate_oriented_sim3(
                source_common_poses,
                target_common_poses,
            )
        aligned_poses = _align_w2c_poses(local_poses, scale, rotation, translation)
        _validate_common_view_rotations(
            np.stack([aligned_poses[local_positions[index]] for index in common]),
            np.stack([global_poses[index] for index in common]),
        )
        alignment_errors.append(normalized_rmse)
        sample_batch(
            batch,
            aligned_poses,
            local_intrinsics,
            local_depths,
            local_confidence,
            scale,
        )

        for local_index, image_index in enumerate(batch):
            if image_index in global_poses:
                continue
            global_poses[image_index] = aligned_poses[local_index]
            global_intrinsics[image_index] = local_intrinsics[local_index]
            global_processed_sizes[image_index] = local_processed_sizes[local_index]

    expected_indices = set(range(image_count))
    if set(global_poses) != expected_indices or set(global_intrinsics) != expected_indices:
        missing = sorted(expected_indices - set(global_poses))
        raise ValueError(f"DA3 alignment graph did not cover every selected image; missing indices {missing}")
    if set(global_processed_sizes) != expected_indices:
        missing = sorted(expected_indices - set(global_processed_sizes))
        raise ValueError(f"DA3 prediction omitted processed image sizes for indices {missing}")

    ordered_poses = np.stack([global_poses[index] for index in range(image_count)])
    ordered_intrinsics = np.stack([global_intrinsics[index] for index in range(image_count)])
    ordered_processed_sizes = [global_processed_sizes[index] for index in range(image_count)]
    if not sampled_points:
        raise ValueError("DA3 confidence filtering produced no learned geometry points")
    raw_points = np.concatenate(sampled_points, axis=0)
    raw_colors = np.concatenate(sampled_colors, axis=0)
    raw_confidence = np.concatenate(sampled_confidence, axis=0)
    fused_points, fused_colors = _fuse_depth_points(
        raw_points,
        raw_colors,
        raw_confidence,
        maximum_points=args.max_points,
    )
    if fused_points.shape[0] == 0:
        raise ValueError("DA3 learned geometry fusion produced no points")
    _write_seed_colmap(
        ordered_poses,
        ordered_intrinsics,
        image_paths,
        out_sparse,
        args.camera_type,
        bool(args.shared_camera),
        processed_sizes=ordered_processed_sizes,
        learned_points=(fused_points, fused_colors),
    )
    evidence = {
        "batches": batches,
        "anchor_indices": anchor_indices,
        "alignment_edge_count": len(alignment_errors),
        "max_alignment_rmse": max(alignment_errors, default=0.0),
        "alignment_complete": True,
        "input_ordering": ordering,
        "raw_point_sample_count": int(raw_points.shape[0]),
        "fused_sparse_point_count": int(fused_points.shape[0]),
    }
    return image_count, evidence


def _call_da3_inference(
    args: argparse.Namespace,
    model: Any,
    image_paths: list[Path],
    selected_device: str,
) -> Any:
    kwargs = {
        "image": [str(path) for path in image_paths],
        "process_res": args.process_res,
        "device": selected_device,
    }
    try:
        return model.inference(**kwargs)
    except TypeError as exc:
        if "device" not in str(exc):
            raise
        kwargs.pop("device", None)
        return model.inference(**kwargs)


def build_arg_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Build an aligned Depth Anything 3 pose seed for EasySplat.")
    parser.add_argument("--images", required=True, type=Path)
    parser.add_argument("--out-sparse", required=True, type=Path)
    parser.add_argument("--models-dir", type=Path, default=None)
    parser.add_argument("--device", default="mps")
    parser.add_argument("--input-ordering", choices=("automatic", "continuous", "unordered"), default="automatic")
    parser.add_argument("--model-subdir", default="DA3-BASE")
    parser.add_argument("--fallback-model-subdir", default="DA3-SMALL")
    parser.add_argument("--process-res", type=int, default=504)
    parser.add_argument("--max-points", type=int, default=120_000)
    parser.add_argument("--camera-type", choices=SUPPORTED_CAMERA_TYPES, default="PINHOLE")
    parser.add_argument("--shared-camera", action="store_true")
    parser.add_argument("--window-size", type=int, default=6)
    parser.add_argument("--window-overlap", type=int, default=2)
    parser.add_argument("--manifest-out", type=Path)
    return parser


def _release_accelerator_memory() -> None:
    gc.collect()
    try:
        import torch

        if hasattr(torch, "mps") and hasattr(torch.mps, "empty_cache"):
            torch.mps.empty_cache()
    except Exception:  # noqa: BLE001
        pass


def _run_da3_attempt(
    args: argparse.Namespace,
    image_paths: list[Path],
    model_dir: Path,
    selected_device: str,
    out_sparse: Path,
) -> tuple[tuple[int, dict[str, Any]] | None, str | None]:
    try:
        return _run_da3_model(args, image_paths, model_dir, selected_device, out_sparse), None
    except Exception as exc:  # noqa: BLE001
        if not _is_memory_error(exc):
            raise
        message = str(exc)
        # A traceback retains every inference frame, including the model. Clear
        # it before returning so SMALL loads outside the failed BASE lifetime.
        exc.__traceback__ = None
        del exc
        _release_accelerator_memory()
        return None, message


def main(argv: list[str] | None = None) -> int:
    args = build_arg_parser().parse_args(argv)
    models_dir = args.models_dir or _default_models_dir()
    if models_dir is None:
        raise SystemExit("DA3 models dir was not provided and no packaged models dir was found")
    models_dir = Path(models_dir)
    image_paths = _list_images(args.images)
    if len(image_paths) < MIN_WINDOW_SIZE:
        raise SystemExit(f"DA3 aligned seed requires at least {MIN_WINDOW_SIZE} images")
    if args.max_points < 1:
        raise SystemExit("--max-points must be >= 1")
    if args.window_size < MIN_WINDOW_SIZE:
        raise SystemExit(f"--window-size must be >= {MIN_WINDOW_SIZE}")
    if args.window_overlap < 0 or args.window_overlap >= args.window_size:
        raise SystemExit("--window-overlap must be >= 0 and smaller than --window-size")

    selected_device = _select_device(args.device)
    primary_model = _model_path(models_dir, args.model_subdir)
    fallback_model = _model_path(models_dir, args.fallback_model_subdir)
    os.environ["HF_HUB_OFFLINE"] = "1"
    os.environ["TRANSFORMERS_OFFLINE"] = "1"
    os.environ["HF_HUB_DISABLE_TELEMETRY"] = "1"
    os.environ["DO_NOT_TRACK"] = "1"
    os.environ["PYTORCH_ENABLE_MPS_FALLBACK"] = os.environ.get("PYTORCH_ENABLE_MPS_FALLBACK", "1")

    _remove_path(args.out_sparse)
    if args.manifest_out:
        _remove_path(args.manifest_out)
    primary_result, primary_memory_failure = _run_da3_attempt(
        args,
        image_paths,
        primary_model,
        selected_device,
        args.out_sparse,
    )
    if primary_result is not None:
        registered_count, alignment_evidence = primary_result
        model_subdir = args.model_subdir
    else:
        assert primary_memory_failure is not None
        print(f"DA3: {args.model_subdir} ran out of memory; retrying with {args.fallback_model_subdir}", file=sys.stderr)
        _remove_path(args.out_sparse)
        if args.manifest_out:
            _remove_path(args.manifest_out)
        fallback_result, fallback_memory_failure = _run_da3_attempt(
            args,
            image_paths,
            fallback_model,
            selected_device,
            args.out_sparse,
        )
        if fallback_result is None:
            raise RuntimeError(
                f"DA3 {args.fallback_model_subdir} also ran out of memory: {fallback_memory_failure}"
            )
        registered_count, alignment_evidence = fallback_result
        model_subdir = args.fallback_model_subdir

    if args.manifest_out:
        _write_manifest(
            args.manifest_out,
            args=args,
            image_paths=image_paths,
            selected_device=selected_device,
            model_subdir=model_subdir,
            registered_image_count=registered_count,
            alignment_evidence=alignment_evidence,
        )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
