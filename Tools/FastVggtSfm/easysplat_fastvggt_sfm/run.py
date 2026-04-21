from __future__ import annotations

import argparse
import json
import math
import os
import re
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Any

import numpy as np
from PIL import Image

# Ensure project root is in sys.path for absolute imports like `vggt.*`
ROOT_DIR = os.path.abspath(os.path.join(os.path.dirname(__file__), os.pardir))
if ROOT_DIR not in os.sys.path:
    os.sys.path.insert(0, ROOT_DIR)

try:
    import torch
    import torch.nn.functional as F

    from vggt.models.vggt import VGGT
    from vggt.utils.device import maybe_autocast, resolve_device, resolve_dtype, sync_device, warn_if_mps_fallback_disabled
    from vggt.utils.geometry import unproject_depth_map_to_point_map
    from vggt.utils.helper import create_pixel_coordinate_grid, randomly_limit_trues
    from vggt.utils.pose_enc import pose_encoding_to_extri_intri

    _IMPORT_ERROR: Exception | None = None
except Exception as exc:  # noqa: BLE001
    torch = None  # type: ignore[assignment]
    F = None  # type: ignore[assignment]
    VGGT = Any  # type: ignore[assignment]
    maybe_autocast = None  # type: ignore[assignment]
    resolve_device = None  # type: ignore[assignment]
    resolve_dtype = None  # type: ignore[assignment]
    sync_device = None  # type: ignore[assignment]
    warn_if_mps_fallback_disabled = None  # type: ignore[assignment]
    unproject_depth_map_to_point_map = None  # type: ignore[assignment]
    create_pixel_coordinate_grid = None  # type: ignore[assignment]
    randomly_limit_trues = None  # type: ignore[assignment]
    pose_encoding_to_extri_intri = None  # type: ignore[assignment]
    _IMPORT_ERROR = exc


_FRAME_NUM_RE = re.compile(r"(\d+)(?!.*\d)")


@dataclass
class WindowInferenceResult:
    image_paths: list[Path]
    extrinsics: np.ndarray
    intrinsics: np.ndarray
    points3d: np.ndarray
    points_xyf: np.ndarray
    points_rgb: np.ndarray
    img_size: int


@dataclass
class CoverageState:
    image_paths: list[Path]
    registered_mask: np.ndarray
    statuses: list[str]
    attempts: np.ndarray
    extrinsics: np.ndarray
    intrinsics: np.ndarray
    camera_votes: np.ndarray
    points3d_chunks: list[np.ndarray]
    points_xyf_chunks: list[np.ndarray]
    points_rgb_chunks: list[np.ndarray]
    relative_edges: list[tuple[int, int, np.ndarray]]


def _require_runtime_deps() -> None:
    if _IMPORT_ERROR is not None:
        raise RuntimeError(
            "FASTVGGT runtime dependencies are unavailable. "
            f"Original import error: {_IMPORT_ERROR}"
        )


def _supported_image_exts() -> tuple[str, ...]:
    return (".jpg", ".jpeg", ".png")


def _list_images(images_dir: Path) -> list[Path]:
    exts = _supported_image_exts()
    return sorted([p for p in images_dir.iterdir() if p.is_file() and p.suffix.lower() in exts])


def _env_int(name: str, default: int) -> int:
    try:
        return int(os.environ.get(name, default))
    except (TypeError, ValueError):
        return default


def _estimate_tokens_per_frame(image_path: Path, target_width: int) -> int:
    img = Image.open(image_path).convert("RGB")
    width, height = img.size
    new_width = int(target_width)
    new_height = round(height * (new_width / width) / 14) * 14
    final_height = new_width if new_height > new_width else new_height
    patch_width = new_width // 14
    patch_height = final_height // 14
    return patch_width * patch_height + 5


def _maybe_autolimit_mps(image_paths: list[Path], device: torch.device, target_width: int) -> list[Path]:
    if device.type != "mps":
        return image_paths
    max_tokens = _env_int("EASYSPLAT_FASTVGGT_MPS_MAX_TOKENS", _env_int("FASTVGGT_MPS_MAX_TOKENS", 25000))
    if max_tokens <= 0 or len(image_paths) == 0:
        return image_paths
    try:
        tokens_per_frame = _estimate_tokens_per_frame(image_paths[0], target_width)
    except Exception as exc:  # noqa: BLE001
        print(f"FASTVGGT: mps auto-limit skipped (failed to read first image): {exc}")
        return image_paths
    if tokens_per_frame <= 0:
        return image_paths
    max_images_auto = max(3, max_tokens // tokens_per_frame)
    if len(image_paths) > max_images_auto:
        auto_stride = math.ceil(len(image_paths) / max_images_auto)
        image_paths = image_paths[::auto_stride]
        print(
            "FASTVGGT: mps auto-limit enabled: "
            f"FASTVGGT_MPS_MAX_TOKENS={max_tokens}, "
            f"tokens/frame≈{tokens_per_frame}, auto_stride={auto_stride}, images={len(image_paths)}"
        )
    return image_paths


def _load_images_with_paths(image_paths: list[Path]) -> tuple[list[Path], list[np.ndarray]]:
    loaded_paths: list[Path] = []
    images: list[np.ndarray] = []
    for image_path in image_paths:
        try:
            img = Image.open(image_path).convert("RGB")
        except Exception:
            continue
        loaded_paths.append(image_path)
        images.append(np.array(img))
    return loaded_paths, images


def _get_vgg_input_imgs(images: np.ndarray, target_width: int):
    vgg_input_images = []
    final_width = None
    final_height = None

    for image in images:
        img = Image.fromarray(image, mode="RGB")
        width, height = img.size
        new_width = int(target_width)
        new_height = round(height * (new_width / width) / 14) * 14
        img = img.resize((new_width, new_height), Image.Resampling.BICUBIC)
        img = torch.from_numpy(np.asarray(img, dtype=np.float32) / 255.0).permute(2, 0, 1)

        if new_height > new_width:
            start_y = (new_height - new_width) // 2
            img = img[:, start_y : start_y + new_width, :]
            final_height = new_width
        else:
            final_height = new_height

        final_width = new_width
        vgg_input_images.append(img)

    vgg_input_images = torch.stack(vgg_input_images)

    patch_width = final_width // 14
    patch_height = final_height // 14

    return vgg_input_images, patch_width, patch_height


def _compute_original_coords(image_path_list: list[Path], target_width: int):
    if len(image_path_list) == 0:
        raise ValueError("At least 1 image is required")

    original_coords = []
    for image_path in image_path_list:
        img = Image.open(image_path).convert("RGB")
        width, height = img.size
        resized_width = int(target_width)
        resized_height = round(height * (resized_width / width) / 14) * 14
        crop_x = 0.0
        crop_y = 0.0
        if resized_height > resized_width:
            crop_y = float((resized_height - resized_width) // 2)

        scale_x = float(width) / float(resized_width)
        scale_y = float(height) / float(resized_height)

        original_coords.append(np.array([crop_x, crop_y, scale_x, scale_y, width, height], dtype=np.float32))

    return np.stack(original_coords, axis=0).astype(np.float32)


def _build_colmap_intri(fidx, intrinsics, camera_type):
    if camera_type == "PINHOLE":
        return np.array([
            intrinsics[fidx][0, 0],
            intrinsics[fidx][1, 1],
            intrinsics[fidx][0, 2],
            intrinsics[fidx][1, 2],
        ])
    if camera_type == "SIMPLE_PINHOLE":
        focal = (intrinsics[fidx][0, 0] + intrinsics[fidx][1, 1]) / 2
        return np.array([focal, intrinsics[fidx][0, 2], intrinsics[fidx][1, 2]])
    raise ValueError(f"Camera type {camera_type} is not supported yet")


def _rotation_matrix_to_quaternion(rot):
    trace = rot[0, 0] + rot[1, 1] + rot[2, 2]
    if trace > 0.0:
        s = 0.5 / math.sqrt(trace + 1.0)
        qw = 0.25 / s
        qx = (rot[2, 1] - rot[1, 2]) * s
        qy = (rot[0, 2] - rot[2, 0]) * s
        qz = (rot[1, 0] - rot[0, 1]) * s
    else:
        if rot[0, 0] > rot[1, 1] and rot[0, 0] > rot[2, 2]:
            s = 2.0 * math.sqrt(1.0 + rot[0, 0] - rot[1, 1] - rot[2, 2])
            qw = (rot[2, 1] - rot[1, 2]) / s
            qx = 0.25 * s
            qy = (rot[0, 1] + rot[1, 0]) / s
            qz = (rot[0, 2] + rot[2, 0]) / s
        elif rot[1, 1] > rot[2, 2]:
            s = 2.0 * math.sqrt(1.0 + rot[1, 1] - rot[0, 0] - rot[2, 2])
            qw = (rot[0, 2] - rot[2, 0]) / s
            qx = (rot[0, 1] + rot[1, 0]) / s
            qy = 0.25 * s
            qz = (rot[1, 2] + rot[2, 1]) / s
        else:
            s = 2.0 * math.sqrt(1.0 + rot[2, 2] - rot[0, 0] - rot[1, 1])
            qw = (rot[1, 0] - rot[0, 1]) / s
            qx = (rot[0, 2] + rot[2, 0]) / s
            qy = (rot[1, 2] + rot[2, 1]) / s
            qz = 0.25 * s
    return qw, qx, qy, qz


def _write_colmap_text_model(
    out_sparse,
    points3d,
    points_xyf,
    points_rgb,
    extrinsics,
    intrinsics,
    image_paths,
    original_coords,
    img_size,
    shared_camera=False,
    camera_type="SIMPLE_PINHOLE",
):
    out_sparse = Path(out_sparse)
    out_sparse.mkdir(parents=True, exist_ok=True)

    num_frames = len(extrinsics)
    image_points2d = [[] for _ in range(num_frames)]
    point_tracks = [[] for _ in range(len(points3d))]

    scale_factors = []
    crop_offsets = []
    for fidx in range(num_frames):
        real_image_size = original_coords[fidx, -2:]
        scale_factors.append(original_coords[fidx, 2:4])
        crop_offsets.append(original_coords[fidx, :2])

    for point_idx in range(len(points3d)):
        fidx = int(points_xyf[point_idx, 2])
        if fidx < 0 or fidx >= num_frames:
            continue
        xy = points_xyf[point_idx, :2]
        xy = (xy + crop_offsets[fidx]) * scale_factors[fidx]
        real_image_size = original_coords[fidx, -2:]
        xy = np.array(
            [
                np.clip(xy[0], 0.0, max(0.0, float(real_image_size[0] - 1))),
                np.clip(xy[1], 0.0, max(0.0, float(real_image_size[1] - 1))),
            ],
            dtype=np.float32,
        )
        point_id = point_idx + 1
        point2d_idx = len(image_points2d[fidx])
        image_points2d[fidx].append((xy, point_id))
        point_tracks[point_idx].append((fidx + 1, point2d_idx))

    cameras = []
    for fidx in range(num_frames):
        colmap_intri = _build_colmap_intri(fidx, intrinsics, camera_type)
        real_image_size = original_coords[fidx, -2:]
        scale_x, scale_y = scale_factors[fidx]
        if camera_type == "PINHOLE":
            colmap_intri[0] *= scale_x
            colmap_intri[1] *= scale_y
        else:
            colmap_intri[0] *= (float(scale_x) + float(scale_y)) / 2.0
        real_pp = real_image_size / 2
        colmap_intri[-2:] = real_pp
        cameras.append((fidx + 1, camera_type, int(real_image_size[0]), int(real_image_size[1]), colmap_intri))
        if shared_camera:
            break

    with open(out_sparse / "cameras.txt", "w", encoding="utf-8") as handle:
        handle.write(
            "# Camera list with one line of data per camera:\n"
            "#   CAMERA_ID, MODEL, WIDTH, HEIGHT, PARAMS[]\n"
            f"# Number of cameras: {len(cameras)}\n"
        )
        for camera_id, model, width, height, params in cameras:
            params_text = " ".join(f"{float(p):.6f}" for p in params)
            handle.write(f"{camera_id} {model} {width} {height} {params_text}\n")

    with open(out_sparse / "images.txt", "w", encoding="utf-8") as handle:
        handle.write(
            "# Image list with two lines of data per image:\n"
            "#   IMAGE_ID, QW, QX, QY, QZ, TX, TY, TZ, CAMERA_ID, IMAGE_NAME\n"
            "#   POINTS2D[] as (X, Y, POINT3D_ID)\n"
            f"# Number of images: {num_frames}\n"
        )
        for fidx in range(num_frames):
            rot = extrinsics[fidx][:3, :3]
            tvec = extrinsics[fidx][:3, 3]
            qw, qx, qy, qz = _rotation_matrix_to_quaternion(rot)
            camera_id = 1 if shared_camera else fidx + 1
            image_id = fidx + 1
            image_name = image_paths[fidx].name
            handle.write(
                f"{image_id} {qw:.8f} {qx:.8f} {qy:.8f} {qz:.8f} "
                f"{float(tvec[0]):.6f} {float(tvec[1]):.6f} {float(tvec[2]):.6f} "
                f"{camera_id} {image_name}\n"
            )
            points2d = image_points2d[fidx]
            if points2d:
                pts_text = " ".join(
                    f"{float(xy[0]):.6f} {float(xy[1]):.6f} {point_id}"
                    for xy, point_id in points2d
                )
                handle.write(f"{pts_text}\n")
            else:
                handle.write("\n")

    with open(out_sparse / "points3D.txt", "w", encoding="utf-8") as handle:
        handle.write(
            "# 3D point list with one line of data per point:\n"
            "#   POINT3D_ID, X, Y, Z, R, G, B, ERROR, TRACK[] as (IMAGE_ID, POINT2D_IDX)\n"
            f"# Number of points: {len(points3d)}\n"
        )
        for point_idx, point in enumerate(points3d):
            point_id = point_idx + 1
            color = points_rgb[point_idx]
            track = point_tracks[point_idx]
            track_text = " ".join(f"{image_id} {point2d_idx}" for image_id, point2d_idx in track)
            handle.write(
                f"{point_id} {float(point[0]):.6f} {float(point[1]):.6f} {float(point[2]):.6f} "
                f"{int(color[0])} {int(color[1])} {int(color[2])} 0.0 {track_text}\n"
            )


def _frame_index_from_name(path: Path) -> int | None:
    match = _FRAME_NUM_RE.search(path.stem)
    if not match:
        return None
    try:
        return int(match.group(1))
    except ValueError:
        return None


def _ordered_sequence_confidence(image_paths: list[Path]) -> float:
    if len(image_paths) < 3:
        return 0.0

    indices: list[int | None] = [_frame_index_from_name(path) for path in image_paths]
    valid = [value for value in indices if value is not None]
    if len(valid) < max(3, int(0.6 * len(image_paths))):
        return 0.0

    valid_ratio = len(valid) / max(1, len(indices))
    monotonic_hits = 0
    monotonic_total = 0
    contiguous_hits = 0
    contiguous_total = 0

    for left, right in zip(indices, indices[1:]):
        if left is None or right is None:
            continue
        monotonic_total += 1
        contiguous_total += 1
        if right > left:
            monotonic_hits += 1
        if 0 < (right - left) <= 3:
            contiguous_hits += 1

    if monotonic_total == 0:
        return 0.0

    monotonic_score = monotonic_hits / monotonic_total
    contiguous_score = contiguous_hits / max(1, contiguous_total)
    return 0.5 * valid_ratio + 0.3 * monotonic_score + 0.2 * contiguous_score


def _appearance_embeddings(image_paths: list[Path]) -> np.ndarray:
    features: list[np.ndarray] = []
    for path in image_paths:
        img = Image.open(path).convert("RGB")
        img = img.resize((32, 32), Image.Resampling.BILINEAR)
        arr = np.asarray(img, dtype=np.float32) / 255.0
        pooled = arr.reshape(8, 4, 8, 4, 3).mean(axis=(1, 3))
        feature = pooled.reshape(-1)
        norm = np.linalg.norm(feature)
        if norm > 0:
            feature = feature / norm
        features.append(feature)
    return np.stack(features, axis=0)


def _build_appearance_order(image_paths: list[Path]) -> list[int]:
    if len(image_paths) <= 3:
        return list(range(len(image_paths)))

    try:
        embeddings = _appearance_embeddings(image_paths)
    except Exception as exc:  # noqa: BLE001
        print(f"FASTVGGT: appearance planner fallback to temporal order ({exc})")
        return list(range(len(image_paths)))

    n = embeddings.shape[0]
    remaining = set(range(n))
    current = 0
    order = [current]
    remaining.remove(current)

    while remaining:
        current_vec = embeddings[current]
        best_idx = None
        best_dist = None
        for candidate in remaining:
            dist = float(np.linalg.norm(current_vec - embeddings[candidate]))
            if best_dist is None or dist < best_dist or (dist == best_dist and candidate < (best_idx or candidate)):
                best_dist = dist
                best_idx = candidate
        if best_idx is None:
            best_idx = min(remaining)
        order.append(best_idx)
        remaining.remove(best_idx)
        current = best_idx

    return order


def _resolve_planner_mode(image_paths: list[Path], requested: str) -> tuple[str, float]:
    requested = requested.lower()
    if requested in {"temporal", "appearance"}:
        return requested, 1.0
    confidence = _ordered_sequence_confidence(image_paths)
    return ("temporal", confidence) if confidence >= 0.65 else ("appearance", confidence)


def _normalize_resolution(value: int) -> int:
    adjusted = max(14, (int(value) // 14) * 14)
    return adjusted


def _build_resolution_ladder(base_resolution: int) -> list[int]:
    candidates = [_normalize_resolution(base_resolution), _normalize_resolution(448), _normalize_resolution(378)]
    ladder: list[int] = []
    seen: set[int] = set()
    for candidate in candidates:
        if candidate < 14 or candidate in seen:
            continue
        ladder.append(candidate)
        seen.add(candidate)
    return ladder


def _plan_windows_from_order(order: list[int], window_size: int, overlap: float) -> list[list[int]]:
    if len(order) <= window_size:
        return [order.copy()]

    overlap = max(0.0, min(0.9, overlap))
    step = max(1, int(round(window_size * (1.0 - overlap))))
    windows: list[list[int]] = []
    start = 0
    while start < len(order):
        window = order[start : start + window_size]
        if len(window) >= 3:
            windows.append(window)
        if start + window_size >= len(order):
            break
        start += step

    tail = order[-window_size:]
    if len(tail) >= 3 and (not windows or windows[-1] != tail):
        windows.append(tail)
    return windows


def _build_rescue_windows(
    unresolved: list[int],
    ordered_index_list: list[int],
    window_size: int,
    registered_mask: np.ndarray,
) -> list[list[int]]:
    if not unresolved:
        return []

    position = {index: offset for offset, index in enumerate(ordered_index_list)}
    windows: list[list[int]] = []
    seen: set[tuple[int, ...]] = set()

    for unresolved_idx in unresolved:
        center_pos = position.get(unresolved_idx, unresolved_idx)
        candidates = sorted(ordered_index_list, key=lambda idx: (abs(position[idx] - center_pos), idx))

        chosen = [unresolved_idx]
        for idx in candidates:
            if idx == unresolved_idx:
                continue
            if registered_mask[idx]:
                chosen.append(idx)
            if len(chosen) >= max(3, window_size // 2):
                break

        for idx in candidates:
            if idx in chosen:
                continue
            chosen.append(idx)
            if len(chosen) >= window_size:
                break

        if len(chosen) < 3:
            continue

        chosen = sorted(chosen, key=lambda idx: position.get(idx, idx))
        key = tuple(chosen)
        if key in seen:
            continue
        seen.add(key)
        windows.append(chosen)

    return windows


def _camera_center_from_extrinsic(extrinsic: np.ndarray) -> np.ndarray:
    rot = extrinsic[:3, :3]
    tvec = extrinsic[:3, 3]
    return -rot.T @ tvec


def _estimate_sim3(src: np.ndarray, dst: np.ndarray) -> tuple[float, np.ndarray, np.ndarray]:
    if src.shape[0] < 2 or dst.shape[0] < 2:
        return 1.0, np.eye(3, dtype=np.float32), np.zeros(3, dtype=np.float32)

    src_mean = src.mean(axis=0)
    dst_mean = dst.mean(axis=0)
    src_centered = src - src_mean
    dst_centered = dst - dst_mean

    cov = (dst_centered.T @ src_centered) / max(1, src.shape[0])
    u_mat, singular_values, v_t = np.linalg.svd(cov)
    rot = u_mat @ v_t
    if np.linalg.det(rot) < 0:
        v_t[-1, :] *= -1
        rot = u_mat @ v_t

    src_var = np.mean(np.sum(src_centered * src_centered, axis=1))
    if src_var <= 1e-9:
        scale = 1.0
    else:
        scale = float(np.sum(singular_values) / src_var)

    trans = dst_mean - scale * (rot @ src_mean)
    return scale, rot.astype(np.float32), trans.astype(np.float32)


def _transform_extrinsic(extrinsic_local: np.ndarray, scale: float, rot_sim: np.ndarray, trans_sim: np.ndarray) -> np.ndarray:
    center_local = _camera_center_from_extrinsic(extrinsic_local)
    center_global = scale * (rot_sim @ center_local) + trans_sim

    rot_local = extrinsic_local[:3, :3]
    rot_global = rot_local @ rot_sim.T
    tvec_global = -rot_global @ center_global

    transformed = np.eye(4, dtype=np.float32)
    transformed[:3, :3] = rot_global
    transformed[:3, 3] = tvec_global
    return transformed


def _transform_points(points3d_local: np.ndarray, scale: float, rot_sim: np.ndarray, trans_sim: np.ndarray) -> np.ndarray:
    if len(points3d_local) == 0:
        return points3d_local
    transformed = (scale * (rot_sim @ points3d_local.T)).T + trans_sim
    return transformed.astype(np.float32)


def _run_window_inference(
    model: VGGT,
    device: torch.device,
    dtype: torch.dtype,
    window_paths: list[Path],
    target_resolution: int,
    conf_threshold: float,
    max_points: int,
) -> WindowInferenceResult | None:
    _require_runtime_deps()
    loaded_paths, images = _load_images_with_paths(window_paths)
    if len(loaded_paths) < 3 or len(images) < 3:
        return None

    image_stack = np.stack(images)
    vgg_input, patch_width, patch_height = _get_vgg_input_imgs(image_stack, target_width=target_resolution)
    model.update_patch_dimensions(patch_width, patch_height)

    original_coords = _compute_original_coords(loaded_paths, target_width=target_resolution)

    sync_device(device)
    start = time.time()
    with torch.no_grad():
        with maybe_autocast(device, dtype):
            vgg_input_device = vgg_input.to(device=device, dtype=dtype)
            predictions = model(vgg_input_device, image_paths=[path.name for path in loaded_paths])
    sync_device(device)
    elapsed_ms = (time.time() - start) * 1000.0
    print(
        "FASTVGGT: window inference done "
        f"({len(loaded_paths)} imgs, resolution={target_resolution}) in {elapsed_ms:.1f} ms"
    )

    extrinsic, intrinsic = pose_encoding_to_extri_intri(
        predictions["pose_enc"],
        (vgg_input.shape[2], vgg_input.shape[3]),
    )

    depth_tensor = predictions["depth"]
    depth_conf = predictions["depth_conf"]
    depth_np = depth_tensor[0].detach().float().cpu().numpy()
    depth_conf_np = depth_conf[0].detach().float().cpu().numpy()

    extrinsic_np = extrinsic[0].detach().float().cpu().numpy()
    intrinsic_np = intrinsic[0].detach().float().cpu().numpy()

    depth_filtered = depth_np.copy()
    depth_filtered[depth_conf_np < float(conf_threshold)] = np.nan
    points_3d = unproject_depth_map_to_point_map(depth_filtered, extrinsic_np, intrinsic_np)

    _, _, grid_h, grid_w = vgg_input.shape
    points_rgb = F.interpolate(vgg_input, size=(grid_h, grid_w), mode="bilinear", align_corners=False)
    points_rgb = (points_rgb.detach().cpu().numpy() * 255).astype(np.uint8)
    points_rgb = points_rgb.transpose(0, 2, 3, 1)

    num_frames, height, width, _ = points_3d.shape
    points_xyf = create_pixel_coordinate_grid(num_frames, height, width)

    conf_mask = depth_conf_np >= float(conf_threshold)
    conf_mask = randomly_limit_trues(conf_mask, int(max_points))

    points_3d = points_3d[conf_mask]
    points_xyf = points_xyf[conf_mask]
    points_rgb = points_rgb[conf_mask]

    return WindowInferenceResult(
        image_paths=loaded_paths,
        extrinsics=extrinsic_np.astype(np.float32),
        intrinsics=intrinsic_np.astype(np.float32),
        points3d=points_3d.astype(np.float32),
        points_xyf=points_xyf.astype(np.float32),
        points_rgb=points_rgb.astype(np.uint8),
        img_size=int(grid_w),
    )


def _merge_window_result(
    state: CoverageState,
    window_result: WindowInferenceResult,
    image_to_index: dict[Path, int],
) -> tuple[bool, list[int]]:
    global_indices: list[int] = []
    local_extrinsics = window_result.extrinsics

    for path in window_result.image_paths:
        if path not in image_to_index:
            continue
        global_indices.append(image_to_index[path])

    if len(global_indices) < 3:
        return False, []

    anchors_local: list[int] = []
    anchors_global: list[int] = []
    for local_idx, global_idx in enumerate(global_indices):
        if state.registered_mask[global_idx]:
            anchors_local.append(local_idx)
            anchors_global.append(global_idx)

    scale = 1.0
    rot_sim = np.eye(3, dtype=np.float32)
    trans_sim = np.zeros(3, dtype=np.float32)

    if state.registered_mask.any() and len(anchors_local) == 0:
        return False, []

    if len(anchors_local) >= 2:
        local_centers = np.stack([_camera_center_from_extrinsic(local_extrinsics[idx]) for idx in anchors_local], axis=0)
        global_centers = np.stack([_camera_center_from_extrinsic(state.extrinsics[idx]) for idx in anchors_global], axis=0)
        scale, rot_sim, trans_sim = _estimate_sim3(local_centers, global_centers)
    elif len(anchors_local) == 1:
        local_center = _camera_center_from_extrinsic(local_extrinsics[anchors_local[0]])
        global_center = _camera_center_from_extrinsic(state.extrinsics[anchors_global[0]])
        trans_sim = global_center - local_center

    transformed_extrinsics = np.stack(
        [_transform_extrinsic(extrinsic, scale, rot_sim, trans_sim) for extrinsic in local_extrinsics],
        axis=0,
    )

    for local_idx, global_idx in enumerate(global_indices):
        if not state.registered_mask[global_idx]:
            state.extrinsics[global_idx] = transformed_extrinsics[local_idx]
            state.intrinsics[global_idx] = window_result.intrinsics[local_idx]
            state.camera_votes[global_idx] = 1
            state.registered_mask[global_idx] = True
            state.statuses[global_idx] = "registered"
            continue

        # Blend camera centers only when multiple windows vote for the same frame.
        old_extrinsic = state.extrinsics[global_idx]
        new_extrinsic = transformed_extrinsics[local_idx]
        old_center = _camera_center_from_extrinsic(old_extrinsic)
        new_center = _camera_center_from_extrinsic(new_extrinsic)
        votes = max(1, int(state.camera_votes[global_idx]))
        blended_center = (old_center * votes + new_center) / float(votes + 1)

        rot = old_extrinsic[:3, :3]
        blended = old_extrinsic.copy()
        blended[:3, 3] = -rot @ blended_center
        state.extrinsics[global_idx] = blended
        state.intrinsics[global_idx] = window_result.intrinsics[local_idx]
        state.camera_votes[global_idx] = votes + 1

    transformed_points = _transform_points(window_result.points3d, scale, rot_sim, trans_sim)
    if len(transformed_points) > 0 and len(window_result.points_xyf) > 0 and len(window_result.points_rgb) > 0:
        points_xyf = window_result.points_xyf.copy()
        frame_ids = points_xyf[:, 2].astype(np.int32)
        remapped = np.array(
            [global_indices[idx] if 0 <= idx < len(global_indices) else -1 for idx in frame_ids],
            dtype=np.float32,
        )
        valid_mask = remapped >= 0
        if valid_mask.any():
            points_xyf = points_xyf[valid_mask]
            points_xyf[:, 2] = remapped[valid_mask]
            state.points3d_chunks.append(transformed_points[valid_mask])
            state.points_xyf_chunks.append(points_xyf.astype(np.float32))
            state.points_rgb_chunks.append(window_result.points_rgb[valid_mask])

    for local_idx in range(len(global_indices) - 1):
        idx_a = global_indices[local_idx]
        idx_b = global_indices[local_idx + 1]
        center_a = _camera_center_from_extrinsic(transformed_extrinsics[local_idx])
        center_b = _camera_center_from_extrinsic(transformed_extrinsics[local_idx + 1])
        delta = (center_b - center_a).astype(np.float32)
        state.relative_edges.append((idx_a, idx_b, delta))

    return True, global_indices


def _run_gpu_ba_lite(
    state: CoverageState,
    planner_mode: str,
    planner_order: list[int],
    device: torch.device,
    max_steps: int = 80,
) -> None:
    _require_runtime_deps()
    registered_indices = np.where(state.registered_mask)[0].tolist()
    if len(registered_indices) < 3 or len(state.relative_edges) < 2:
        return

    local_index = {global_idx: idx for idx, global_idx in enumerate(registered_indices)}

    centers0 = []
    rotations = []
    for global_idx in registered_indices:
        extrinsic = state.extrinsics[global_idx]
        centers0.append(_camera_center_from_extrinsic(extrinsic))
        rotations.append(extrinsic[:3, :3].astype(np.float32))

    edge_i = []
    edge_j = []
    edge_delta = []
    for idx_a, idx_b, delta in state.relative_edges:
        if idx_a not in local_index or idx_b not in local_index:
            continue
        edge_i.append(local_index[idx_a])
        edge_j.append(local_index[idx_b])
        edge_delta.append(delta)

    if len(edge_i) < 2:
        return

    torch_device = torch.device(device.type)
    centers0_tensor = torch.tensor(np.stack(centers0, axis=0), dtype=torch.float32, device=torch_device)
    centers = torch.nn.Parameter(centers0_tensor.clone())
    edge_i_tensor = torch.tensor(edge_i, dtype=torch.long, device=torch_device)
    edge_j_tensor = torch.tensor(edge_j, dtype=torch.long, device=torch_device)
    edge_delta_tensor = torch.tensor(np.stack(edge_delta, axis=0), dtype=torch.float32, device=torch_device)

    optimizer = torch.optim.Adam([centers], lr=0.03)

    temporal_triplets: list[tuple[int, int, int]] = []
    if planner_mode == "temporal":
        ordered_registered = [idx for idx in planner_order if idx in local_index]
        for i in range(1, len(ordered_registered) - 1):
            temporal_triplets.append(
                (
                    local_index[ordered_registered[i - 1]],
                    local_index[ordered_registered[i]],
                    local_index[ordered_registered[i + 1]],
                )
            )

    for _ in range(max_steps):
        optimizer.zero_grad(set_to_none=True)

        pred_delta = centers[edge_j_tensor] - centers[edge_i_tensor]
        loss_rel = torch.mean((pred_delta - edge_delta_tensor) ** 2)
        loss_anchor = torch.mean((centers - centers0_tensor) ** 2)

        loss = loss_rel + 0.02 * loss_anchor

        if temporal_triplets:
            idx_prev = torch.tensor([triplet[0] for triplet in temporal_triplets], dtype=torch.long, device=torch_device)
            idx_mid = torch.tensor([triplet[1] for triplet in temporal_triplets], dtype=torch.long, device=torch_device)
            idx_next = torch.tensor([triplet[2] for triplet in temporal_triplets], dtype=torch.long, device=torch_device)
            second_diff = centers[idx_prev] - 2.0 * centers[idx_mid] + centers[idx_next]
            loss = loss + 0.01 * torch.mean(second_diff**2)

        loss.backward()
        optimizer.step()

    optimized_centers = centers.detach().cpu().numpy()

    for idx, global_idx in enumerate(registered_indices):
        rotation = rotations[idx]
        center = optimized_centers[idx]
        state.extrinsics[global_idx, :3, :3] = rotation
        state.extrinsics[global_idx, :3, 3] = -rotation @ center


def _coverage_manifest_payload(
    image_paths: list[Path],
    statuses: list[str],
    rounds_used: int,
    planner_mode: str,
    planner_confidence: float,
    window_size: int,
    unresolved: list[int],
) -> dict:
    total = len(image_paths)
    registered = sum(1 for status in statuses if status == "registered")
    return {
        "total_frames": total,
        "registered_frames": registered,
        "coverage_ratio": float(registered) / float(max(1, total)),
        "rounds_used": rounds_used,
        "planner_mode": planner_mode,
        "planner_confidence": planner_confidence,
        "window_size": window_size,
        "unresolved_frames": [image_paths[idx].name for idx in unresolved],
        "per_frame": [
            {
                "index": index,
                "name": image_paths[index].name,
                "status": statuses[index],
            }
            for index in range(total)
        ],
    }


def _write_manifest(manifest_path: Path, payload: dict) -> None:
    manifest_path.parent.mkdir(parents=True, exist_ok=True)
    with open(manifest_path, "w", encoding="utf-8") as handle:
        json.dump(payload, handle, indent=2)


def _coverage_exit_code(require_full_coverage: bool, unresolved_count: int) -> int:
    if require_full_coverage and unresolved_count > 0:
        return 2
    return 0


def _default_intrinsics_for_image(width: float, height: float) -> np.ndarray:
    focal = max(width, height)
    intrinsics = np.eye(3, dtype=np.float32)
    intrinsics[0, 0] = focal
    intrinsics[1, 1] = focal
    intrinsics[0, 2] = width / 2.0
    intrinsics[1, 2] = height / 2.0
    return intrinsics


def _fill_unresolved_intrinsics(state: CoverageState, image_paths: list[Path]) -> None:
    for idx, path in enumerate(image_paths):
        if state.camera_votes[idx] > 0:
            continue
        try:
            with Image.open(path).convert("RGB") as img:
                width, height = img.size
        except Exception as exc:  # noqa: BLE001
            if state.statuses[idx] != "registered":
                state.statuses[idx] = "unreadable"
            print(
                "FASTVGGT: warning: skipping unreadable frame while finalizing intrinsics "
                f"({path.name}): {exc}"
            )
            continue
        state.intrinsics[idx] = _default_intrinsics_for_image(float(width), float(height))


def _build_registered_export_subset(
    image_paths: list[Path],
    registered_indices: list[int],
    extrinsics: np.ndarray,
    intrinsics: np.ndarray,
    points3d: np.ndarray,
    points_xyf: np.ndarray,
    points_rgb: np.ndarray,
    original_coords: np.ndarray,
) -> tuple[list[Path], np.ndarray, np.ndarray, np.ndarray, np.ndarray, np.ndarray, np.ndarray]:
    if len(registered_indices) == 0:
        raise ValueError("No registered frames available for export")

    index_map = {original_idx: export_idx for export_idx, original_idx in enumerate(registered_indices)}
    export_paths = [image_paths[idx] for idx in registered_indices]
    export_extrinsics = extrinsics[registered_indices]
    export_intrinsics = intrinsics[registered_indices]
    export_original_coords = original_coords[registered_indices]

    if len(points_xyf) == 0 or len(points3d) == 0 or len(points_rgb) == 0:
        empty_points3d = np.zeros((0, 3), dtype=np.float32)
        empty_points_xyf = np.zeros((0, 3), dtype=np.float32)
        empty_points_rgb = np.zeros((0, 3), dtype=np.uint8)
        return (
            export_paths,
            export_extrinsics,
            export_intrinsics,
            empty_points3d,
            empty_points_xyf,
            empty_points_rgb,
            export_original_coords,
        )

    frame_ids = points_xyf[:, 2].astype(np.int32)
    remapped = np.array([index_map.get(int(frame_id), -1) for frame_id in frame_ids], dtype=np.int32)
    valid_mask = remapped >= 0

    if not valid_mask.any():
        empty_points3d = np.zeros((0, 3), dtype=np.float32)
        empty_points_xyf = np.zeros((0, 3), dtype=np.float32)
        empty_points_rgb = np.zeros((0, 3), dtype=np.uint8)
        return (
            export_paths,
            export_extrinsics,
            export_intrinsics,
            empty_points3d,
            empty_points_xyf,
            empty_points_rgb,
            export_original_coords,
        )

    export_points3d = points3d[valid_mask]
    export_points_xyf = points_xyf[valid_mask].copy()
    export_points_xyf[:, 2] = remapped[valid_mask].astype(np.float32)
    export_points_rgb = points_rgb[valid_mask]
    return (
        export_paths,
        export_extrinsics,
        export_intrinsics,
        export_points3d,
        export_points_xyf,
        export_points_rgb,
        export_original_coords,
    )


def _run_fastvggt_strict_coverage(
    args,
    model: VGGT,
    device: torch.device,
    dtype: torch.dtype,
    image_paths: list[Path],
    camera_type: str,
) -> int:
    if args.gpu_only and device.type not in {"mps", "cuda"}:
        print(
            "FASTVGGT: --gpu-only was set but no GPU backend is active "
            f"(resolved device={device.type})",
            file=os.sys.stderr,
        )
        return 1

    planner_mode, planner_confidence = _resolve_planner_mode(image_paths, args.coverage_planner)
    planner_order = list(range(len(image_paths))) if planner_mode == "temporal" else _build_appearance_order(image_paths)

    token_budget = max(1000, int(args.coverage_window_tokens))
    try:
        tokens_per_frame = _estimate_tokens_per_frame(image_paths[0], int(args.vggt_resolution))
    except Exception as exc:  # noqa: BLE001
        print(f"FASTVGGT: token estimate failed ({exc}), defaulting to 1200 tokens/frame")
        tokens_per_frame = 1200

    window_size = max(3, min(len(image_paths), token_budget // max(1, tokens_per_frame)))
    overlap = max(0.0, min(0.9, float(args.coverage_overlap)))

    print(
        "FASTVGGT: strict coverage enabled "
        f"(planner={planner_mode}, confidence={planner_confidence:.3f}, "
        f"window_size={window_size}, overlap={overlap:.2f}, max_rounds={args.coverage_max_rounds})"
    )

    state = CoverageState(
        image_paths=image_paths,
        registered_mask=np.zeros(len(image_paths), dtype=bool),
        statuses=["unseen" for _ in image_paths],
        attempts=np.zeros(len(image_paths), dtype=np.int32),
        extrinsics=np.stack([np.eye(4, dtype=np.float32) for _ in image_paths], axis=0),
        intrinsics=np.stack([np.eye(3, dtype=np.float32) for _ in image_paths], axis=0),
        camera_votes=np.zeros(len(image_paths), dtype=np.int32),
        points3d_chunks=[],
        points_xyf_chunks=[],
        points_rgb_chunks=[],
        relative_edges=[],
    )

    image_to_index = {path: idx for idx, path in enumerate(image_paths)}
    ladder = _build_resolution_ladder(int(args.vggt_resolution)) if device.type == "mps" else [_normalize_resolution(args.vggt_resolution)]

    rounds_used = 0
    for round_index in range(1, int(args.coverage_max_rounds) + 1):
        unresolved_indices = [idx for idx, ok in enumerate(state.registered_mask.tolist()) if not ok]
        if not unresolved_indices:
            break

        rounds_used = round_index
        if round_index == 1:
            windows = _plan_windows_from_order(planner_order, window_size=window_size, overlap=overlap)
        else:
            windows = _build_rescue_windows(
                unresolved=unresolved_indices,
                ordered_index_list=planner_order,
                window_size=window_size,
                registered_mask=state.registered_mask,
            )

        if not windows:
            break

        print(
            "FASTVGGT: coverage round "
            f"{round_index}/{args.coverage_max_rounds}, unresolved={len(unresolved_indices)}, windows={len(windows)}"
        )

        for window_idx, window in enumerate(windows, start=1):
            for global_idx in window:
                state.attempts[global_idx] += 1
                if state.statuses[global_idx] == "unseen":
                    state.statuses[global_idx] = "processed_unregistered"

            window_paths = [image_paths[idx] for idx in window]
            result = None
            for resolution in ladder:
                try:
                    result = _run_window_inference(
                        model=model,
                        device=device,
                        dtype=dtype,
                        window_paths=window_paths,
                        target_resolution=resolution,
                        conf_threshold=float(args.conf_thres),
                        max_points=int(args.max_points),
                    )
                except Exception as exc:  # noqa: BLE001
                    print(
                        "FASTVGGT: window failed "
                        f"(round={round_index}, window={window_idx}/{len(windows)}, resolution={resolution}): {exc}"
                    )
                    result = None

                if result is not None:
                    break

            if result is None:
                continue

            merged, merged_indices = _merge_window_result(
                state=state,
                window_result=result,
                image_to_index=image_to_index,
            )
            if not merged:
                continue

            for global_idx in merged_indices:
                state.statuses[global_idx] = "registered"

        unresolved_indices = [idx for idx, ok in enumerate(state.registered_mask.tolist()) if not ok]
        print(
            "FASTVGGT: end round "
            f"{round_index}, registered={int(state.registered_mask.sum())}/{len(image_paths)}, unresolved={len(unresolved_indices)}"
        )
        if not unresolved_indices:
            break

    if args.postprocess == "gpu_ba_lite":
        print("FASTVGGT: running GPU BA-lite postprocess...")
        _run_gpu_ba_lite(
            state=state,
            planner_mode=planner_mode,
            planner_order=planner_order,
            device=device,
        )

    unresolved_indices = [idx for idx, ok in enumerate(state.registered_mask.tolist()) if not ok]
    _fill_unresolved_intrinsics(state=state, image_paths=image_paths)

    if state.points3d_chunks:
        points3d = np.concatenate(state.points3d_chunks, axis=0)
        points_xyf = np.concatenate(state.points_xyf_chunks, axis=0)
        points_rgb = np.concatenate(state.points_rgb_chunks, axis=0)
    else:
        points3d = np.zeros((0, 3), dtype=np.float32)
        points_xyf = np.zeros((0, 3), dtype=np.float32)
        points_rgb = np.zeros((0, 3), dtype=np.uint8)

    manifest_path = Path(args.coverage_manifest) if args.coverage_manifest else Path(args.out_sparse) / "coverage_manifest.json"
    payload = _coverage_manifest_payload(
        image_paths=image_paths,
        statuses=state.statuses,
        rounds_used=rounds_used,
        planner_mode=planner_mode,
        planner_confidence=planner_confidence,
        window_size=window_size,
        unresolved=unresolved_indices,
    )
    _write_manifest(manifest_path, payload)
    print(f"FASTVGGT: wrote coverage manifest to {manifest_path}")

    exit_code = _coverage_exit_code(bool(args.require_full_coverage), len(unresolved_indices))
    if exit_code == 2:
        print(
            "FASTVGGT: strict full coverage failed "
            f"({len(unresolved_indices)} unresolved of {len(image_paths)}).",
            file=os.sys.stderr,
        )
        return exit_code

    out_sparse = Path(args.out_sparse)
    out_sparse.mkdir(parents=True, exist_ok=True)

    registered_indices = [idx for idx, ok in enumerate(state.registered_mask.tolist()) if ok]
    if len(registered_indices) == 0:
        print(
            "FASTVGGT: strict coverage produced no registered frames; cannot export sparse model.",
            file=os.sys.stderr,
        )
        return 1

    original_coords = _compute_original_coords(image_paths, target_width=int(args.vggt_resolution))
    (
        export_paths,
        export_extrinsics,
        export_intrinsics,
        export_points3d,
        export_points_xyf,
        export_points_rgb,
        export_original_coords,
    ) = _build_registered_export_subset(
        image_paths=image_paths,
        registered_indices=registered_indices,
        extrinsics=state.extrinsics,
        intrinsics=state.intrinsics,
        points3d=points3d,
        points_xyf=points_xyf,
        points_rgb=points_rgb,
        original_coords=original_coords,
    )

    if len(export_paths) < len(image_paths):
        print(
            "FASTVGGT: exporting registered subset "
            f"{len(export_paths)}/{len(image_paths)} frames; unresolved frames were omitted."
        )

    print("FASTVGGT: converting to COLMAP format (strict merged model)...")
    _write_colmap_text_model(
        out_sparse,
        export_points3d,
        export_points_xyf,
        export_points_rgb,
        export_extrinsics,
        export_intrinsics,
        export_paths,
        export_original_coords,
        img_size=int(args.vggt_resolution),
        shared_camera=bool(args.shared_camera),
        camera_type=camera_type,
    )

    print("FASTVGGT: strict coverage model ready")
    return 0


def parse_args():
    parser = argparse.ArgumentParser(description="EasySplat FastVGGT -> COLMAP sparse model bridge")
    parser.add_argument("--images", required=True, help="Directory containing images")
    parser.add_argument("--out-sparse", required=True, help="Output sparse model directory")
    parser.add_argument("--models-dir", required=True, help="Models directory")
    parser.add_argument("--device", default="auto")
    parser.add_argument("--dtype", default="auto")
    parser.add_argument("--vggt-resolution", type=int, default=518)
    parser.add_argument("--conf-thres", type=float, default=3.0)
    parser.add_argument("--max-points", type=int, default=100000)
    parser.add_argument("--merging", type=int, default=0)
    parser.add_argument("--merge-ratio", type=float, default=0.9)
    parser.add_argument("--camera-type", type=str, default="SIMPLE_PINHOLE")
    parser.add_argument("--shared-camera", action="store_true", default=False)

    parser.add_argument("--require-full-coverage", action="store_true", default=False)
    parser.add_argument("--coverage-planner", choices=["auto", "temporal", "appearance"], default="auto")
    parser.add_argument("--coverage-window-tokens", type=int, default=25000)
    parser.add_argument("--coverage-overlap", type=float, default=0.35)
    parser.add_argument("--coverage-max-rounds", type=int, default=4)
    parser.add_argument("--coverage-manifest", type=str, default="")
    parser.add_argument("--gpu-only", action="store_true", default=False)
    parser.add_argument("--postprocess", choices=["gpu_ba_lite", "none"], default="gpu_ba_lite")
    return parser.parse_args()


def main():
    try:
        _require_runtime_deps()
    except RuntimeError as exc:
        print(str(exc), file=os.sys.stderr)
        return 1
    args = parse_args()

    device = resolve_device(args.device)
    dtype = resolve_dtype(device, args.dtype)
    warn_if_mps_fallback_disabled(device)

    vggt_resolution = int(args.vggt_resolution)
    if vggt_resolution % 14 != 0:
        adjusted = _normalize_resolution(vggt_resolution)
        if adjusted != vggt_resolution:
            print(
                "FASTVGGT: vggt-resolution must be multiple of 14; "
                f"using {adjusted} instead of {vggt_resolution}"
            )
            vggt_resolution = adjusted
            args.vggt_resolution = adjusted

    images_dir = Path(args.images)
    if not images_dir.exists():
        print(f"FASTVGGT: images dir not found: {images_dir}", file=os.sys.stderr)
        return 1

    image_paths = _list_images(images_dir)
    if len(image_paths) == 0:
        print(f"FASTVGGT: no supported images found in {images_dir}", file=os.sys.stderr)
        return 1

    if not bool(args.require_full_coverage):
        image_paths = _maybe_autolimit_mps(image_paths, device=device, target_width=vggt_resolution)

    if len(image_paths) < 3:
        print("FASTVGGT: need at least 3 images", file=os.sys.stderr)
        return 1

    camera_type = str(args.camera_type)
    if camera_type not in {"PINHOLE", "SIMPLE_PINHOLE"}:
        print(f"FASTVGGT: unsupported camera type: {camera_type}", file=os.sys.stderr)
        return 1

    print(f"FASTVGGT: device={device}, dtype={dtype}")
    print(f"FASTVGGT: images={len(image_paths)}")
    print("FASTVGGT: loading model weights...")

    models_dir = Path(args.models_dir)
    model_path = models_dir / "fastvggt_model.pt"
    if not model_path.exists():
        print(f"FASTVGGT: model weights not found: {model_path}", file=os.sys.stderr)
        return 1

    model = VGGT(
        merging=int(args.merging),
        merge_ratio=float(args.merge_ratio),
        vis_attn_map=False,
        enable_track=False,
    )
    ckpt = torch.load(model_path, map_location="cpu")
    if isinstance(ckpt, dict) and "state_dict" in ckpt:
        ckpt = ckpt["state_dict"]
    model.load_state_dict(ckpt, strict=False)
    model = model.to(device=device, dtype=dtype).eval()

    if bool(args.require_full_coverage):
        return _run_fastvggt_strict_coverage(
            args=args,
            model=model,
            device=device,
            dtype=dtype,
            image_paths=image_paths,
            camera_type=camera_type,
        )

    loaded_paths, images = _load_images_with_paths(image_paths)
    if not images or len(images) < 3:
        print("FASTVGGT: not enough valid images", file=os.sys.stderr)
        return 1
    image_stack = np.stack(images)

    vgg_input, patch_width, patch_height = _get_vgg_input_imgs(image_stack, target_width=vggt_resolution)
    model.update_patch_dimensions(patch_width, patch_height)
    original_coords = _compute_original_coords(loaded_paths, target_width=vggt_resolution)

    print("FASTVGGT: running FastVGGT inference...")
    sync_device(device)
    start = time.time()
    with torch.no_grad():
        with maybe_autocast(device, dtype):
            vgg_input_device = vgg_input.to(device=device, dtype=dtype)
            predictions = model(vgg_input_device, image_paths=[p.name for p in loaded_paths])
    sync_device(device)
    elapsed_ms = (time.time() - start) * 1000.0
    print(f"FASTVGGT: inference done in {elapsed_ms:.1f} ms for {len(loaded_paths)} images")

    extrinsic, intrinsic = pose_encoding_to_extri_intri(predictions["pose_enc"], (vgg_input.shape[2], vgg_input.shape[3]))

    depth_tensor = predictions["depth"]
    depth_conf = predictions["depth_conf"]
    depth_np = depth_tensor[0].detach().float().cpu().numpy()
    depth_conf_np = depth_conf[0].detach().float().cpu().numpy()

    extrinsic_np = extrinsic[0].detach().float().cpu().numpy()
    intrinsic_np = intrinsic[0].detach().float().cpu().numpy()

    depth_filtered = depth_np.copy()
    depth_filtered[depth_conf_np < float(args.conf_thres)] = np.nan
    points_3d = unproject_depth_map_to_point_map(depth_filtered, extrinsic_np, intrinsic_np)

    _, _, grid_h, grid_w = vgg_input.shape
    points_rgb = F.interpolate(vgg_input, size=(grid_h, grid_w), mode="bilinear", align_corners=False)
    points_rgb = (points_rgb.detach().cpu().numpy() * 255).astype(np.uint8)
    points_rgb = points_rgb.transpose(0, 2, 3, 1)

    num_frames, height, width, _ = points_3d.shape
    points_xyf = create_pixel_coordinate_grid(num_frames, height, width)

    conf_mask = depth_conf_np >= float(args.conf_thres)
    conf_mask = randomly_limit_trues(conf_mask, int(args.max_points))

    points_3d = points_3d[conf_mask]
    points_xyf = points_xyf[conf_mask]
    points_rgb = points_rgb[conf_mask]

    out_sparse = Path(args.out_sparse)
    out_sparse.mkdir(parents=True, exist_ok=True)
    print("FASTVGGT: converting to COLMAP format (feed-forward)...")
    _write_colmap_text_model(
        out_sparse,
        points_3d,
        points_xyf,
        points_rgb,
        extrinsic_np,
        intrinsic_np,
        loaded_paths,
        original_coords,
        img_size=int(grid_w),
        shared_camera=bool(args.shared_camera),
        camera_type=camera_type,
    )

    print("FASTVGGT: export seed model ready")
    print("FASTVGGT: done")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
