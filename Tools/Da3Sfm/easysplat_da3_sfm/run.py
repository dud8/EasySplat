from __future__ import annotations

import argparse
import gc
import json
import os
import shutil
import sys
import tempfile
from pathlib import Path
from typing import Any

import numpy as np
from PIL import Image

from .alignment import (
    MIN_ALIGNMENT_ANCHORS,
    MIN_WINDOW_SIZE,
    align_w2c_poses as _align_w2c_poses,
    camera_centers_from_w2c as _camera_centers_from_w2c,
    estimate_sim3 as _estimate_sim3,
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


def _copy_colmap_export(export_dir: Path, out_sparse: Path) -> bool:
    candidates = [
        export_dir / "sparse" / "0",
        export_dir / "colmap" / "sparse" / "0",
        export_dir / "0",
        export_dir,
    ]
    for candidate in candidates:
        if all((candidate / name).is_file() for name in ("cameras.txt", "images.txt", "points3D.txt")):
            _remove_path(out_sparse)
            out_sparse.parent.mkdir(parents=True, exist_ok=True)
            shutil.copytree(candidate, out_sparse)
            return True
    return False


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


def _exact_prediction_geometry(prediction: Any, count: int) -> tuple[np.ndarray, np.ndarray, list[tuple[int, int]] | None]:
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

    processed_sizes: list[tuple[int, int]] | None = None
    depth_value = _prediction_value(prediction, "depth")
    if depth_value is not None:
        depth = _as_numpy(depth_value)
        depth = _require_view_axis(depth, count, "depth")
        processed_sizes = []
        for index in range(count):
            view = np.squeeze(depth[index])
            if view.ndim != 2 or view.shape[0] <= 0 or view.shape[1] <= 0:
                raise ValueError("DA3 seed prediction depth had an invalid per-view shape")
            processed_sizes.append((int(view.shape[1]), int(view.shape[0])))
    return extrinsics, intrinsics, processed_sizes


def _write_seed_colmap(
    extrinsics_w2c: np.ndarray,
    intrinsics: np.ndarray,
    image_paths: list[Path],
    out_sparse: Path,
    camera_type: str,
    shared_camera: bool,
    processed_sizes: list[tuple[int, int]] | None = None,
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


def _plan_windows(image_count: int, window_size: int, window_overlap: int) -> list[tuple[int, int]]:
    if image_count <= 0:
        return []
    size = max(2, min(window_size, image_count))
    overlap = max(0, min(window_overlap, size - 1))
    stride = max(1, size - overlap)
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


def _colmap_text_stats(sparse_dir: Path) -> tuple[int, int, int, float]:
    images_file = sparse_dir / "images.txt"
    points_file = sparse_dir / "points3D.txt"
    registered_images = 0
    if images_file.exists():
        for line in images_file.read_text(encoding="utf-8", errors="ignore").splitlines():
            if not _is_colmap_image_pose_row(line):
                continue
            registered_images += 1

    point_count = 0
    observation_count = 0
    if points_file.exists():
        for line in points_file.read_text(encoding="utf-8", errors="ignore").splitlines():
            if not line or line.startswith("#"):
                continue
            parts = line.split()
            if len(parts) < 8:
                continue
            point_count += 1
            observation_count += max(0, (len(parts) - 8) // 2)
    mean_track_length = observation_count / point_count if point_count > 0 else 0.0
    return registered_images, point_count, observation_count, mean_track_length


def _is_colmap_image_pose_row(line: str) -> bool:
    stripped = line.strip()
    if not stripped or stripped.startswith("#"):
        return False
    parts = stripped.split(maxsplit=9)
    if len(parts) < 10:
        return False
    try:
        int(parts[0])
        for part in parts[1:9]:
            float(part)
    except ValueError:
        return False
    return True


def _write_colmap_from_prediction(
    prediction: dict[str, Any],
    image_paths: list[Path],
    out_sparse: Path,
    camera_type: str,
    shared_camera: bool,
    max_points: int,
) -> tuple[int, int, float]:
    extrinsics = _prediction_value(prediction, "extrinsics", "extrinsics_w2c", "poses")
    intrinsics = _as_numpy(_prediction_value(prediction, "intrinsics", "intrinsics_3x3"))
    depth = _prediction_value(prediction, "depth")
    conf = _prediction_value(prediction, "conf", "confidence")
    if depth is None:
        raise ValueError("DA3 prediction did not include depth and no COLMAP export was produced")
    depth_np = _as_numpy(depth)
    conf_np = np.ones(depth_np.shape, dtype=np.float32) if conf is None else _as_numpy(conf)
    depth_np = _require_view_axis(depth_np, len(image_paths), "depth")
    conf_np = _require_view_axis(conf_np, len(image_paths), "conf")

    extrinsics_w2c = _extrinsics_w2c(extrinsics, len(image_paths))
    if intrinsics.ndim != 3:
        intrinsics = np.repeat(np.eye(3, dtype=np.float64)[None, ...], len(image_paths), axis=0)
    else:
        intrinsics = _pad_view_axis(intrinsics.astype(np.float64), len(image_paths))

    sizes: list[tuple[int, int]] = []
    for image_path in image_paths:
        with Image.open(image_path) as image:
            sizes.append(image.size)

    out_sparse.mkdir(parents=True, exist_ok=True)
    camera_lines: list[str] = []
    processed_sizes = [
        (int(np.squeeze(depth_np[index]).shape[1]), int(np.squeeze(depth_np[index]).shape[0]))
        for index in range(min(len(image_paths), depth_np.shape[0]))
    ]
    while len(processed_sizes) < len(image_paths):
        processed_sizes.append(sizes[len(processed_sizes)])

    if shared_camera and len(set(sizes)) == 1:
        params = np.mean([
            _camera_params(k, sizes[0], camera_type, source_size=processed_size)
            for k, processed_size in zip(intrinsics, processed_sizes)
        ], axis=0)
        camera_lines.append(f"1 {camera_type} {sizes[0][0]} {sizes[0][1]} " + " ".join(str(float(v)) for v in params))
    else:
        shared_camera = False
        for index, (intrinsic, size, processed_size) in enumerate(zip(intrinsics, sizes, processed_sizes), start=1):
            params = _camera_params(intrinsic, size, camera_type, source_size=processed_size)
            camera_lines.append(f"{index} {camera_type} {size[0]} {size[1]} " + " ".join(str(float(v)) for v in params))

    point_budget = max(1, max_points)
    per_image_budget = max(1, point_budget // max(1, len(image_paths)))
    point_rows: list[str] = []
    image_observations: list[list[tuple[float, float, int]]] = [[] for _ in image_paths]
    point_id = 1
    observation_count = 0
    for image_index, _image_path in enumerate(image_paths):
        if image_index >= depth_np.shape[0]:
            break
        view_depth = np.squeeze(depth_np[image_index])
        view_conf = np.squeeze(conf_np[image_index]) if conf_np.shape[0] > image_index else np.ones_like(view_depth)
        valid = np.isfinite(view_depth) & (view_depth > 0) & np.isfinite(view_conf)
        ys, xs = np.nonzero(valid)
        if len(xs) == 0:
            continue
        scores = view_conf[ys, xs]
        order = np.argsort(scores)[::-1][:per_image_budget]
        width, height = sizes[image_index]
        step_x = width / max(1, view_depth.shape[1])
        step_y = height / max(1, view_depth.shape[0])
        for idx in order:
            x = float(xs[idx])
            y = float(ys[idx])
            z = float(view_depth[ys[idx], xs[idx]])
            ox = (x + 0.5) * step_x
            oy = (y + 0.5) * step_y
            track_entries: list[tuple[int, int]] = []

            source_observation_index = len(image_observations[image_index])
            image_observations[image_index].append((ox, oy, point_id))
            track_entries.append((image_index + 1, source_observation_index))

            paired_index = image_index + 1 if image_index + 1 < len(image_paths) else image_index - 1
            if paired_index >= 0 and paired_index != image_index:
                pair_width, pair_height = sizes[paired_index]
                pair_x = min(max((x + 0.5) / max(1, view_depth.shape[1]) * pair_width, 0.0), max(0.0, pair_width - 1.0))
                pair_y = min(max((y + 0.5) / max(1, view_depth.shape[0]) * pair_height, 0.0), max(0.0, pair_height - 1.0))
                paired_observation_index = len(image_observations[paired_index])
                image_observations[paired_index].append((pair_x, pair_y, point_id))
                track_entries.append((paired_index + 1, paired_observation_index))

            observation_count += len(track_entries)
            track_text = " ".join(f"{image_id} {point2d_index}" for image_id, point2d_index in track_entries)
            point_rows.append(f"{point_id} {ox * 0.001} {oy * 0.001} {z} 128 128 128 1.0 {track_text}")
            point_id += 1

    (out_sparse / "cameras.txt").write_text(
        "# Camera list with one line per camera:\n#   CAMERA_ID, MODEL, WIDTH, HEIGHT, PARAMS[]\n"
        + f"# Number of cameras: {len(camera_lines)}\n"
        + "\n".join(camera_lines)
        + "\n",
        encoding="utf-8",
    )
    with (out_sparse / "images.txt").open("w", encoding="utf-8") as handle:
        handle.write("# Image list with two lines per image:\n")
        handle.write("#   IMAGE_ID, QW, QX, QY, QZ, TX, TY, TZ, CAMERA_ID, NAME\n")
        handle.write("#   POINTS2D[] as (X, Y, POINT3D_ID)\n")
        handle.write(f"# Number of images: {len(image_paths)}\n")
        for index, image_path in enumerate(image_paths, start=1):
            pose = extrinsics_w2c[index - 1]
            quat = _rotmat_to_quat_wxyz(pose[:3, :3])
            trans = pose[:3, 3]
            camera_id = 1 if shared_camera else index
            handle.write(f"{index} {quat[0]} {quat[1]} {quat[2]} {quat[3]} {trans[0]} {trans[1]} {trans[2]} {camera_id} {image_path.name}\n")
            handle.write(" ".join(f"{x} {y} {pid}" for x, y, pid in image_observations[index - 1]) + "\n")
    (out_sparse / "points3D.txt").write_text(
        "# 3D point list with one line per point:\n#   POINT3D_ID, X, Y, Z, R, G, B, ERROR, TRACK[] as (IMAGE_ID, POINT2D_IDX)\n"
        + f"# Number of points: {len(point_rows)}, mean track length: {observation_count / max(1, len(point_rows)):.2f}\n"
        + "\n".join(point_rows)
        + "\n",
        encoding="utf-8",
    )
    return len(point_rows), observation_count, observation_count / max(1, len(point_rows))


def _write_manifest(
    manifest_path: Path,
    *,
    args: argparse.Namespace,
    image_paths: list[Path],
    selected_device: str,
    model_subdir: str,
    native_colmap_export: bool,
    export_strategy: str | None = None,
    registered_image_count: int | None = None,
    raw_point_count: int | None = None,
    final_observation_count: int | None = None,
    mean_track_length: float | None = None,
    alignment_evidence: dict[str, Any] | None = None,
) -> None:
    image_count = len(image_paths)
    size = max(2, min(args.window_size, image_count))
    overlap = max(0, min(args.window_overlap, size - 1))
    stride = max(1, size - overlap)
    windows: list[dict[str, Any]] = []
    if alignment_evidence is not None:
        for batch in alignment_evidence["batches"]:
            indices = [int(index) for index in batch]
            windows.append({
                "start": min(indices),
                "end": max(indices) + 1,
                "indices": indices,
                "images": [image_paths[index].name for index in indices],
            })
    else:
        start = 0
        while start < image_count:
            end = min(start + size, image_count)
            indices = list(range(start, end))
            windows.append({
                "start": start,
                "end": end,
                "indices": indices,
                "images": [p.name for p in image_paths[start:end]],
            })
            if end == image_count:
                break
            start += stride
    payload = {
        "mode": args.mode,
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
        "input_ordering": (
            alignment_evidence.get("input_ordering", args.input_ordering)
            if alignment_evidence is not None
            else args.input_ordering
        ),
        "windows": windows,
        "registered_image_count": registered_image_count if registered_image_count is not None else image_count,
        "native_colmap_export": native_colmap_export,
        "export_strategy": export_strategy or ("native_colmap" if native_colmap_export else "unsupported_non_native_colmap"),
    }
    if raw_point_count is not None:
        payload["raw_point_sample_count"] = raw_point_count
        payload["fused_sparse_point_count"] = raw_point_count
        payload["final_observation_count"] = final_observation_count if final_observation_count is not None else raw_point_count
        payload["mean_track_length"] = mean_track_length if mean_track_length is not None else 1.0
    if alignment_evidence is not None:
        anchor_indices = [int(index) for index in alignment_evidence.get("anchor_indices", [])]
        payload["anchor_image_names"] = [image_paths[index].name for index in anchor_indices]
        payload["alignment_edge_count"] = int(alignment_evidence["alignment_edge_count"])
        payload["max_alignment_rmse"] = float(alignment_evidence["max_alignment_rmse"])
        payload["alignment_complete"] = bool(alignment_evidence["alignment_complete"])
    manifest_path.parent.mkdir(parents=True, exist_ok=True)
    manifest_path.write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")


def _count_colmap_points(points_file: Path) -> int:
    if not points_file.exists():
        return 0
    return sum(
        1
        for line in points_file.read_text(encoding="utf-8", errors="ignore").splitlines()
        if line and not line.startswith("#")
    )


def _run_da3_export(
    args: argparse.Namespace,
    image_paths: list[Path],
    model_dir: Path,
    selected_device: str,
    out_sparse: Path,
) -> tuple[int, int | None, float | None, int | None, dict[str, Any] | None]:
    if args.mode == "direct" and len(image_paths) > max(2, args.window_size):
        raise RuntimeError(
            "DA3 native COLMAP export is only accepted for inputs that fit in one safe inference window; "
            "use seed_refine for larger inputs"
        )
    if args.mode not in ("direct", "seed_refine"):
        raise RuntimeError(f"DA3 mode {args.mode!r} is not supported in this bridge")

    from depth_anything_3.api import DepthAnything3

    model: Any | None = None
    try:
        try:
            model = DepthAnything3.from_pretrained(str(model_dir), local_files_only=True)
        except TypeError:
            model = DepthAnything3.from_pretrained(str(model_dir))
        if hasattr(model, "to"):
            model = model.to(selected_device)

        if args.mode == "seed_refine":
            return _run_da3_seed_refine(args, model, image_paths, selected_device, out_sparse)

        with tempfile.TemporaryDirectory(prefix="easysplat-da3-") as tmp:
            export_dir = Path(tmp) / "export"
            _call_da3_inference(
                args,
                model,
                image_paths,
                selected_device,
                export_dir=export_dir,
            )
            if _copy_colmap_export(export_dir, out_sparse):
                registered_count, point_count, observation_count, mean_track_length = _colmap_text_stats(out_sparse)
                return point_count, observation_count, mean_track_length, registered_count, None
        raise RuntimeError("DA3 did not produce a native COLMAP export")
    finally:
        model = None


def _run_da3_seed_refine(
    args: argparse.Namespace,
    model: Any,
    image_paths: list[Path],
    selected_device: str,
    out_sparse: Path,
) -> tuple[int, int, None, int, dict[str, Any]]:
    image_count = len(image_paths)
    window_size = min(image_count, max(MIN_WINDOW_SIZE, args.window_size))
    ordering = args.input_ordering
    if ordering == "automatic":
        ordering = "continuous"
    if ordering not in ("continuous", "unordered"):
        raise ValueError(f"Unsupported DA3 input ordering: {ordering}")

    initial_batch = list(range(window_size))
    batches = [initial_batch]
    global_poses: dict[int, np.ndarray] = {}
    global_intrinsics: dict[int, np.ndarray] = {}
    global_processed_sizes: dict[int, tuple[int, int]] = {}
    anchor_indices: list[int] = []
    edge_anchor_indices: set[int] = set()
    alignment_errors: list[float] = []

    def infer_batch(batch: list[int], batch_number: int) -> tuple[np.ndarray, np.ndarray, list[tuple[int, int]] | None]:
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

    first_poses, first_intrinsics, first_processed_sizes = infer_batch(initial_batch, 0)
    for local_index, image_index in enumerate(initial_batch):
        global_poses[image_index] = first_poses[local_index]
        global_intrinsics[image_index] = first_intrinsics[local_index]
        if first_processed_sizes is not None:
            global_processed_sizes[image_index] = first_processed_sizes[local_index]

    if image_count > window_size:
        if ordering == "continuous":
            batches = _plan_continuous_batches(image_count, window_size, args.window_overlap)
        else:
            first_centers = _camera_centers_from_w2c(first_poses)
            anchor_indices = _select_anchor_indices(first_centers)
            batches = _plan_unordered_batches(image_count, window_size, anchor_indices)
    elif not anchor_indices:
        anchor_indices = _select_anchor_indices(_camera_centers_from_w2c(first_poses))

    for batch_number, batch in enumerate(batches[1:], start=1):
        local_poses, local_intrinsics, local_processed_sizes = infer_batch(batch, batch_number)
        common = [image_index for image_index in batch if image_index in global_poses]
        if len(common) < MIN_ALIGNMENT_ANCHORS:
            raise ValueError(
                f"DA3 alignment graph was disconnected at batch {batch_number}: "
                f"found {len(common)} common views, need {MIN_ALIGNMENT_ANCHORS}"
            )
        local_positions = {image_index: local_index for local_index, image_index in enumerate(batch)}
        local_centers = _camera_centers_from_w2c(local_poses)
        source_centers = np.stack([local_centers[local_positions[index]] for index in common])
        target_centers = np.stack([
            _camera_centers_from_w2c(global_poses[index][None, ...])[0]
            for index in common
        ])
        scale, rotation, translation, normalized_rmse = _estimate_sim3(source_centers, target_centers)
        aligned_poses = _align_w2c_poses(local_poses, scale, rotation, translation)
        _validate_common_view_rotations(
            np.stack([aligned_poses[local_positions[index]] for index in common]),
            np.stack([global_poses[index] for index in common]),
        )
        alignment_errors.append(normalized_rmse)
        edge_anchor_indices.update(common)

        for local_index, image_index in enumerate(batch):
            if image_index in global_poses:
                continue
            global_poses[image_index] = aligned_poses[local_index]
            global_intrinsics[image_index] = local_intrinsics[local_index]
            if local_processed_sizes is not None:
                global_processed_sizes[image_index] = local_processed_sizes[local_index]

    expected_indices = set(range(image_count))
    if set(global_poses) != expected_indices or set(global_intrinsics) != expected_indices:
        missing = sorted(expected_indices - set(global_poses))
        raise ValueError(f"DA3 alignment graph did not cover every selected image; missing indices {missing}")
    if global_processed_sizes and set(global_processed_sizes) != expected_indices:
        missing = sorted(expected_indices - set(global_processed_sizes))
        raise ValueError(f"DA3 prediction omitted processed image sizes for indices {missing}")

    ordered_poses = np.stack([global_poses[index] for index in range(image_count)])
    ordered_intrinsics = np.stack([global_intrinsics[index] for index in range(image_count)])
    ordered_processed_sizes = (
        [global_processed_sizes[index] for index in range(image_count)]
        if global_processed_sizes
        else None
    )
    _write_seed_colmap(
        ordered_poses,
        ordered_intrinsics,
        image_paths,
        out_sparse,
        args.camera_type,
        bool(args.shared_camera),
        processed_sizes=ordered_processed_sizes,
    )
    evidence = {
        "batches": batches,
        "anchor_indices": sorted(set(anchor_indices) | edge_anchor_indices),
        "alignment_edge_count": len(alignment_errors),
        "max_alignment_rmse": max(alignment_errors, default=0.0),
        "alignment_complete": True,
        "input_ordering": ordering,
    }
    return 0, 0, None, image_count, evidence


def _call_da3_inference(
    args: argparse.Namespace,
    model: Any,
    image_paths: list[Path],
    selected_device: str,
    export_dir: Path | None = None,
) -> Any:
    kwargs = {
        "image": [str(path) for path in image_paths],
        "process_res": args.process_res,
        "device": selected_device,
    }
    if export_dir is not None:
        kwargs["export_dir"] = str(export_dir)
        kwargs["export_format"] = "colmap"
    try:
        return model.inference(**kwargs)
    except TypeError as exc:
        if "device" not in str(exc):
            raise
        kwargs.pop("device", None)
        return model.inference(**kwargs)


def build_arg_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Run Depth Anything 3 and export an EasySplat COLMAP text model.")
    parser.add_argument("--images", required=True, type=Path)
    parser.add_argument("--out-sparse", required=True, type=Path)
    parser.add_argument("--models-dir", type=Path, default=None)
    parser.add_argument("--device", default="mps")
    parser.add_argument("--mode", choices=("direct", "seed_refine"), default="direct")
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
) -> tuple[tuple[int, int | None, float | None, int | None, dict[str, Any] | None] | None, str | None]:
    try:
        return _run_da3_export(args, image_paths, model_dir, selected_device, out_sparse), None
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
    if len(image_paths) < 2:
        raise SystemExit("DA3 requires at least 2 supported images")
    if args.mode == "seed_refine" and len(image_paths) < MIN_WINDOW_SIZE:
        raise SystemExit(f"DA3 seed_refine requires at least {MIN_WINDOW_SIZE} images")
    if args.max_points < 1:
        raise SystemExit("--max-points must be >= 1")
    minimum_window_size = MIN_WINDOW_SIZE if args.mode == "seed_refine" and len(image_paths) > args.window_size else 2
    if args.window_size < minimum_window_size:
        raise SystemExit(f"--window-size must be >= {minimum_window_size} for this solve")
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
        point_count, observation_count, mean_track_length, registered_count, alignment_evidence = primary_result
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
        point_count, observation_count, mean_track_length, registered_count, alignment_evidence = fallback_result
        model_subdir = args.fallback_model_subdir

    if args.manifest_out:
        _write_manifest(
            args.manifest_out,
            args=args,
            image_paths=image_paths,
            selected_device=selected_device,
            model_subdir=model_subdir,
            native_colmap_export=args.mode == "direct",
            export_strategy="native_colmap" if args.mode == "direct" else "aligned_pose_seed",
            registered_image_count=registered_count,
            raw_point_count=point_count if args.mode == "direct" else None,
            final_observation_count=observation_count if args.mode == "direct" else None,
            mean_track_length=mean_track_length if args.mode == "direct" else None,
            alignment_evidence=alignment_evidence,
        )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
