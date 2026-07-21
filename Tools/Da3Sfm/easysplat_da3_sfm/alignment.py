from __future__ import annotations

from itertools import combinations

import numpy as np

MIN_ALIGNMENT_ANCHORS = 3
MIN_ORIENTED_ALIGNMENT_ANCHORS = 2
MIN_WINDOW_SIZE = 4
MIN_SIM3_SCALE = 0.05
MAX_SIM3_SCALE = 20.0
MAX_NORMALIZED_ALIGNMENT_RMSE = 0.05
MAX_COMMON_ROTATION_ERROR_DEGREES = 15.0


def minimum_alignment_overlap(window_size: int) -> int:
    if window_size < MIN_WINDOW_SIZE:
        raise ValueError(f"multi-window alignment requires window size >= {MIN_WINDOW_SIZE}")
    return MIN_ORIENTED_ALIGNMENT_ANCHORS if window_size == MIN_WINDOW_SIZE else MIN_ALIGNMENT_ANCHORS


def plan_continuous_batches(image_count: int, window_size: int, overlap: int) -> list[list[int]]:
    if image_count <= 0:
        return []
    size = min(image_count, window_size)
    if image_count > size and size < MIN_WINDOW_SIZE:
        raise ValueError(f"multi-window alignment requires window size >= {MIN_WINDOW_SIZE}")
    if image_count <= size:
        return [list(range(image_count))]

    effective_overlap = min(
        max(minimum_alignment_overlap(size), overlap),
        size - MIN_ORIENTED_ALIGNMENT_ANCHORS,
    )
    stride = size - effective_overlap
    batches: list[list[int]] = []
    start = 0
    while start < image_count:
        end = min(start + size, image_count)
        batch = list(range(start, end))
        if batches and len(set(batches[-1]) & set(batch)) < effective_overlap:
            raise ValueError("continuous alignment graph was disconnected")
        batches.append(batch)
        if end == image_count:
            break
        start += stride
    return batches


def plan_unordered_batches(
    image_count: int,
    window_size: int,
    neighbor_graph: dict[int, list[int]],
    overlap: int,
) -> list[list[int]]:
    if image_count <= 0:
        return []
    size = min(image_count, window_size)
    if image_count > size and size < MIN_WINDOW_SIZE:
        raise ValueError(f"multi-window alignment requires window size >= {MIN_WINDOW_SIZE}")
    if image_count <= size:
        return [list(range(image_count))]
    nodes = set(range(image_count))
    normalized_graph = {
        index: sorted({neighbor for neighbor in neighbor_graph.get(index, []) if neighbor in nodes and neighbor != index})
        for index in range(image_count)
    }
    reachable = {0}
    frontier = [0]
    while frontier:
        current = frontier.pop(0)
        for neighbor in normalized_graph[current]:
            if neighbor not in reachable:
                reachable.add(neighbor)
                frontier.append(neighbor)
    if reachable != nodes:
        missing = sorted(nodes - reachable)
        raise ValueError(f"unordered retrieval graph was disconnected; unreachable image indices {missing}")

    effective_overlap = max(minimum_alignment_overlap(size), overlap)
    if effective_overlap > size - MIN_ORIENTED_ALIGNMENT_ANCHORS:
        effective_overlap = size - MIN_ORIENTED_ALIGNMENT_ANCHORS
    capacity = size - effective_overlap

    initial: list[int] = [0]
    while len(initial) < size:
        candidates = sorted(
            nodes - set(initial),
            key=lambda candidate: (
                -len(set(normalized_graph[candidate]) & set(initial)),
                candidate,
            ),
        )
        connected = [candidate for candidate in candidates if set(normalized_graph[candidate]) & set(initial)]
        if not connected:
            raise ValueError("unordered retrieval graph was disconnected while selecting the first batch")
        initial.append(connected[0])

    batches = [initial]
    visited = set(initial)
    visited_order = list(initial)
    while visited != nodes:
        selected: list[int] = []
        while len(selected) < capacity and visited.union(selected) != nodes:
            active = visited.union(selected)
            candidates = [
                candidate
                for candidate in nodes - active
                if set(normalized_graph[candidate]) & active
            ]
            if not candidates:
                missing = sorted(nodes - active)
                raise ValueError(f"unordered retrieval graph was disconnected; unreachable image indices {missing}")
            candidate = min(
                candidates,
                key=lambda value: (
                    -len(set(normalized_graph[value]) & active),
                    value,
                ),
            )
            selected.append(candidate)

        selected_set = set(selected)
        previous_batch = set(batches[-1])
        anchors = sorted(
            visited,
            key=lambda candidate: (
                -len(set(normalized_graph[candidate]) & selected_set),
                0 if candidate in previous_batch else 1,
                -visited_order.index(candidate),
                candidate,
            ),
        )[:effective_overlap]
        if len(anchors) < effective_overlap:
            raise ValueError("unordered retrieval graph did not provide enough accepted alignment anchors")
        batch = sorted(anchors) + selected
        if len(batch) > size or len(batch) != len(set(batch)):
            raise ValueError("unordered retrieval planner produced an invalid bounded batch")
        batches.append(batch)
        visited.update(selected)
        visited_order.extend(selected)
    return batches


def build_retrieval_graph(
    descriptors: np.ndarray,
    *,
    max_neighbors: int = 8,
    minimum_similarity: float = 0.55,
) -> dict[int, list[int]]:
    values = np.asarray(descriptors, dtype=np.float64)
    if values.ndim != 2 or values.shape[0] == 0 or values.shape[1] == 0:
        raise ValueError("retrieval descriptors must have shape NxD")
    if not np.all(np.isfinite(values)):
        raise ValueError("retrieval descriptors must be finite")
    if max_neighbors < 1:
        raise ValueError("retrieval max_neighbors must be positive")
    if not np.isfinite(minimum_similarity) or minimum_similarity < -1.0 or minimum_similarity > 1.0:
        raise ValueError("retrieval minimum_similarity must be finite and between -1 and 1")

    norms = np.linalg.norm(values, axis=1)
    if np.any(norms <= np.finfo(np.float64).eps):
        raise ValueError("retrieval descriptors must have non-zero length")
    normalized = values / norms[:, None]
    similarities = normalized @ normalized.T
    graph: dict[int, set[int]] = {index: set() for index in range(values.shape[0])}
    neighbor_limit = min(max_neighbors, max(0, values.shape[0] - 1))
    for index in range(values.shape[0]):
        candidates = sorted(
            (
                (float(similarities[index, candidate]), candidate)
                for candidate in range(values.shape[0])
                if candidate != index and float(similarities[index, candidate]) >= minimum_similarity
            ),
            key=lambda item: (-item[0], item[1]),
        )[:neighbor_limit]
        for _, candidate in candidates:
            graph[index].add(candidate)
            graph[candidate].add(index)
    return {index: sorted(neighbors) for index, neighbors in graph.items()}


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


def estimate_oriented_sim3(
    source_w2c: np.ndarray,
    target_w2c: np.ndarray,
    *,
    maximum_normalized_rmse: float = MAX_NORMALIZED_ALIGNMENT_RMSE,
) -> tuple[float, np.ndarray, np.ndarray, float]:
    source = _validated_w2c(source_w2c)
    target = _validated_w2c(target_w2c)
    if source.shape != target.shape or source.shape[0] < MIN_ORIENTED_ALIGNMENT_ANCHORS:
        raise ValueError("oriented Sim(3) requires matching poses for at least two views")

    rotation_sum = np.zeros((3, 3), dtype=np.float64)
    for source_pose, target_pose in zip(source, target):
        rotation_sum += target_pose[:3, :3].T @ source_pose[:3, :3]
    u, _, vt = np.linalg.svd(rotation_sum)
    correction = np.eye(3, dtype=np.float64)
    correction[-1, -1] = 1.0 if np.linalg.det(u @ vt) >= 0.0 else -1.0
    rotation = u @ correction @ vt
    if not np.all(np.isfinite(rotation)) or float(np.linalg.det(rotation)) <= 0.0:
        raise ValueError("oriented Sim(3) produced a non-proper rotation")

    source_centers = camera_centers_from_w2c(source)
    target_centers = camera_centers_from_w2c(target)
    scales: list[float] = []
    farthest_pair: tuple[int, int] | None = None
    farthest_source_distance = -1.0
    for first, second in combinations(range(source.shape[0]), 2):
        source_distance = float(np.linalg.norm(source_centers[first] - source_centers[second]))
        target_distance = float(np.linalg.norm(target_centers[first] - target_centers[second]))
        if source_distance > 1e-8 and target_distance > 1e-8:
            scales.append(target_distance / source_distance)
            if source_distance > farthest_source_distance:
                farthest_pair = (first, second)
                farthest_source_distance = source_distance
    if not scales:
        raise ValueError("oriented Sim(3) anchors had no usable baseline")
    scale = float(np.median(np.asarray(scales, dtype=np.float64)))
    if not np.isfinite(scale) or scale < MIN_SIM3_SCALE or scale > MAX_SIM3_SCALE:
        raise ValueError(f"oriented Sim(3) scale {scale} was non-positive or implausible")

    assert farthest_pair is not None
    first, second = farthest_pair
    rotated_source_baseline = rotation @ (source_centers[second] - source_centers[first])
    target_baseline = target_centers[second] - target_centers[first]
    rotation = _rotation_between_vectors(rotated_source_baseline, target_baseline) @ rotation

    translations = target_centers - (scale * (rotation @ source_centers.T)).T
    translation = np.median(translations, axis=0)
    transformed = (scale * (rotation @ source_centers.T)).T + translation
    residual = transformed - target_centers
    rmse = float(np.sqrt(np.mean(np.sum(residual * residual, axis=1))))
    target_centered = target_centers - np.mean(target_centers, axis=0)
    target_spread = float(np.sqrt(np.mean(np.sum(target_centered * target_centered, axis=1))))
    normalized_rmse = rmse / max(target_spread, np.finfo(np.float64).eps)
    if not np.isfinite(normalized_rmse) or normalized_rmse > maximum_normalized_rmse:
        raise ValueError(
            f"oriented Sim(3) normalized alignment RMSE {normalized_rmse:.6f} exceeded "
            f"{maximum_normalized_rmse:.6f}"
        )
    return scale, rotation, translation, normalized_rmse


def _rotation_between_vectors(source: np.ndarray, target: np.ndarray) -> np.ndarray:
    source_norm = float(np.linalg.norm(source))
    target_norm = float(np.linalg.norm(target))
    if source_norm <= 1e-8 or target_norm <= 1e-8:
        raise ValueError("oriented Sim(3) baseline had zero length")
    first = np.asarray(source, dtype=np.float64) / source_norm
    second = np.asarray(target, dtype=np.float64) / target_norm
    cosine = float(np.clip(np.dot(first, second), -1.0, 1.0))
    if cosine > 1.0 - 1e-12:
        return np.eye(3, dtype=np.float64)
    if cosine < -1.0 + 1e-12:
        basis = np.eye(3, dtype=np.float64)[int(np.argmin(np.abs(first)))]
        axis = np.cross(first, basis)
        axis /= np.linalg.norm(axis)
        return 2.0 * np.outer(axis, axis) - np.eye(3, dtype=np.float64)
    cross = np.cross(first, second)
    skew = np.array([
        [0.0, -cross[2], cross[1]],
        [cross[2], 0.0, -cross[0]],
        [-cross[1], cross[0], 0.0],
    ])
    return np.eye(3, dtype=np.float64) + skew + (skew @ skew) / (1.0 + cosine)


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


def validate_common_view_rotations(
    aligned_w2c: np.ndarray,
    accepted_global_w2c: np.ndarray,
    *,
    maximum_error_degrees: float = MAX_COMMON_ROTATION_ERROR_DEGREES,
) -> float:
    """Reject center-only Sim(3) solutions with inconsistent camera chirality.

    Three centers only span a plane after centering, so a mirrored triangle can
    admit a proper 3D rotation. Camera orientations remove that ambiguity. The
    geodesic threshold allows modest learned-pose disagreement while rejecting
    the 180-degree null-axis flip produced by a mirrored batch.
    """

    aligned = _validated_w2c(aligned_w2c)
    accepted = _validated_w2c(accepted_global_w2c)
    if aligned.shape != accepted.shape or aligned.shape[0] < MIN_ORIENTED_ALIGNMENT_ANCHORS:
        raise ValueError("common-view camera orientation validation requires matching anchor poses")
    if not np.isfinite(maximum_error_degrees) or maximum_error_degrees <= 0.0:
        raise ValueError("camera orientation threshold must be positive and finite")

    maximum_error = 0.0
    for aligned_pose, accepted_pose in zip(aligned, accepted):
        relative = aligned_pose[:3, :3] @ accepted_pose[:3, :3].T
        cosine = float(np.clip((np.trace(relative) - 1.0) * 0.5, -1.0, 1.0))
        error_degrees = float(np.degrees(np.arccos(cosine)))
        maximum_error = max(maximum_error, error_degrees)
    if maximum_error > maximum_error_degrees:
        raise ValueError(
            f"common-view camera orientation error {maximum_error:.3f} degrees exceeded "
            f"{maximum_error_degrees:.3f} degrees"
        )
    return maximum_error


def _validated_w2c(values: np.ndarray) -> np.ndarray:
    poses = np.asarray(values, dtype=np.float64)
    if poses.ndim != 3 or poses.shape[1:] != (4, 4):
        raise ValueError("w2c poses must have shape Nx4x4")
    if not np.all(np.isfinite(poses)):
        raise ValueError("w2c poses must be finite")
    return poses
