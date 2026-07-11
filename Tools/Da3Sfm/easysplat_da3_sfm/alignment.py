from __future__ import annotations

from itertools import combinations

import numpy as np

MIN_ALIGNMENT_ANCHORS = 3
MIN_WINDOW_SIZE = 4
MIN_SIM3_SCALE = 0.05
MAX_SIM3_SCALE = 20.0
MAX_NORMALIZED_ALIGNMENT_RMSE = 0.05


def plan_continuous_batches(image_count: int, window_size: int, overlap: int) -> list[list[int]]:
    if image_count <= 0:
        return []
    size = min(image_count, window_size)
    if image_count > size and size < MIN_WINDOW_SIZE:
        raise ValueError(f"multi-window alignment requires window size >= {MIN_WINDOW_SIZE}")
    if image_count <= size:
        return [list(range(image_count))]

    effective_overlap = max(MIN_ALIGNMENT_ANCHORS, overlap)
    if effective_overlap >= size:
        raise ValueError("multi-window alignment requires window size larger than its three-image overlap")
    stride = size - effective_overlap
    batches: list[list[int]] = []
    start = 0
    while start < image_count:
        end = min(start + size, image_count)
        batch = list(range(start, end))
        if batches and len(set(batches[-1]) & set(batch)) < MIN_ALIGNMENT_ANCHORS:
            raise ValueError("continuous alignment graph was disconnected")
        batches.append(batch)
        if end == image_count:
            break
        start += stride
    return batches


def plan_unordered_batches(
    image_count: int,
    window_size: int,
    anchor_indices: list[int],
) -> list[list[int]]:
    if image_count <= 0:
        return []
    size = min(image_count, window_size)
    if image_count > size and size < MIN_WINDOW_SIZE:
        raise ValueError(f"multi-window alignment requires window size >= {MIN_WINDOW_SIZE}")
    if image_count <= size:
        return [list(range(image_count))]
    if len(anchor_indices) != MIN_ALIGNMENT_ANCHORS or len(set(anchor_indices)) != MIN_ALIGNMENT_ANCHORS:
        raise ValueError("unordered alignment requires exactly three distinct anchors")
    if any(index < 0 or index >= size for index in anchor_indices):
        raise ValueError("unordered alignment anchors must come from the first window")

    batches = [list(range(size))]
    unseen = [index for index in range(size, image_count)]
    capacity = size - MIN_ALIGNMENT_ANCHORS
    for start in range(0, len(unseen), capacity):
        batches.append(anchor_indices + unseen[start:start + capacity])
    return batches


def camera_centers_from_w2c(poses: np.ndarray) -> np.ndarray:
    checked = _validated_w2c(poses)
    return np.stack([-pose[:3, :3].T @ pose[:3, 3] for pose in checked])


def select_anchor_indices(camera_centers: np.ndarray) -> list[int]:
    centers = np.asarray(camera_centers, dtype=np.float64)
    if centers.ndim != 2 or centers.shape[1] != 3 or centers.shape[0] < MIN_ALIGNMENT_ANCHORS:
        raise ValueError("anchor selection requires at least three camera centers")
    if not np.all(np.isfinite(centers)):
        raise ValueError("anchor camera centers must be finite")

    spread = float(np.max(np.linalg.norm(centers - np.mean(centers, axis=0), axis=1)))
    minimum_area = max(1e-12, spread * spread * 1e-8)
    best: tuple[int, int, int] | None = None
    best_area = -1.0
    for candidate in combinations(range(centers.shape[0]), MIN_ALIGNMENT_ANCHORS):
        a, b, c = (centers[index] for index in candidate)
        area = float(np.linalg.norm(np.cross(b - a, c - a)) * 0.5)
        if area > best_area:
            best = candidate
            best_area = area
    if best is None or best_area <= minimum_area:
        raise ValueError("could not choose three non-collinear anchor cameras")
    return list(best)


def estimate_sim3(
    source_centers: np.ndarray,
    target_centers: np.ndarray,
    *,
    maximum_normalized_rmse: float = MAX_NORMALIZED_ALIGNMENT_RMSE,
) -> tuple[float, np.ndarray, np.ndarray, float]:
    """Estimate target = scale * rotation * source + translation.

    Three camera centers are necessarily planar after centering, so rank two is
    the minimum valid geometry. Reflections are rejected when the anchors span
    all three dimensions; the rank-two null axis is chosen to keep rotation
    proper.
    """

    source = np.asarray(source_centers, dtype=np.float64)
    target = np.asarray(target_centers, dtype=np.float64)
    if source.shape != target.shape or source.ndim != 2 or source.shape[1] != 3 or source.shape[0] < 3:
        raise ValueError("Sim(3) alignment requires matching Nx3 anchors with N >= 3")
    if not np.all(np.isfinite(source)) or not np.all(np.isfinite(target)):
        raise ValueError("Sim(3) anchors must be finite")

    source_mean = np.mean(source, axis=0)
    target_mean = np.mean(target, axis=0)
    source_centered = source - source_mean
    target_centered = target - target_mean
    source_rank = int(np.linalg.matrix_rank(source_centered))
    target_rank = int(np.linalg.matrix_rank(target_centered))
    if source_rank < 2 or target_rank < 2:
        raise ValueError("Sim(3) anchors were rank deficient")

    covariance = target_centered.T @ source_centered / source.shape[0]
    u, singular_values, vt = np.linalg.svd(covariance)
    raw_determinant = float(np.linalg.det(u @ vt))
    if min(source_rank, target_rank) == 3 and raw_determinant < 0.0:
        raise ValueError("Sim(3) correspondence requires a reflection")

    correction = np.eye(3, dtype=np.float64)
    correction[-1, -1] = 1.0 if raw_determinant >= 0.0 else -1.0
    rotation = u @ correction @ vt
    if not np.all(np.isfinite(rotation)) or float(np.linalg.det(rotation)) <= 0.0:
        raise ValueError("Sim(3) produced a non-proper rotation or reflection")

    source_variance = float(np.sum(source_centered * source_centered) / source.shape[0])
    if not np.isfinite(source_variance) or source_variance <= np.finfo(np.float64).eps:
        raise ValueError("Sim(3) anchors had zero variance")
    scale = float(np.sum(singular_values * np.diag(correction)) / source_variance)
    if not np.isfinite(scale) or scale < MIN_SIM3_SCALE or scale > MAX_SIM3_SCALE:
        raise ValueError(f"Sim(3) scale {scale} was non-positive or implausible")

    translation = target_mean - scale * (rotation @ source_mean)
    transformed = (scale * (rotation @ source.T)).T + translation
    residual = transformed - target
    rmse = float(np.sqrt(np.mean(np.sum(residual * residual, axis=1))))
    target_spread = float(np.sqrt(np.mean(np.sum(target_centered * target_centered, axis=1))))
    normalized_rmse = rmse / max(target_spread, np.finfo(np.float64).eps)
    if not np.isfinite(normalized_rmse) or normalized_rmse > maximum_normalized_rmse:
        raise ValueError(
            f"Sim(3) normalized alignment RMSE {normalized_rmse:.6f} exceeded {maximum_normalized_rmse:.6f}"
        )
    return scale, rotation, translation, normalized_rmse


def align_w2c_poses(
    local_w2c: np.ndarray,
    scale: float,
    local_to_global_rotation: np.ndarray,
    local_to_global_translation: np.ndarray,
) -> np.ndarray:
    poses = _validated_w2c(local_w2c)
    rotation = np.asarray(local_to_global_rotation, dtype=np.float64)
    translation = np.asarray(local_to_global_translation, dtype=np.float64)
    if rotation.shape != (3, 3) or translation.shape != (3,):
        raise ValueError("Sim(3) transform had an invalid shape")
    if not np.isfinite(scale) or not np.all(np.isfinite(rotation)) or not np.all(np.isfinite(translation)):
        raise ValueError("Sim(3) transform must be finite")

    local_centers = camera_centers_from_w2c(poses)
    global_centers = (scale * (rotation @ local_centers.T)).T + translation
    aligned = np.repeat(np.eye(4, dtype=np.float64)[None, ...], poses.shape[0], axis=0)
    for index, (pose, center) in enumerate(zip(poses, global_centers)):
        global_w2c_rotation = pose[:3, :3] @ rotation.T
        aligned[index, :3, :3] = global_w2c_rotation
        aligned[index, :3, 3] = -global_w2c_rotation @ center
    return aligned


def _validated_w2c(values: np.ndarray) -> np.ndarray:
    poses = np.asarray(values, dtype=np.float64)
    if poses.ndim != 3 or poses.shape[1:] != (4, 4):
        raise ValueError("w2c poses must have shape Nx4x4")
    if not np.all(np.isfinite(poses)):
        raise ValueError("w2c poses must be finite")
    return poses
