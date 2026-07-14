from __future__ import annotations

import math
import stat
import sys
from pathlib import Path
from typing import Any

import numpy as np


class ColmapCliError(RuntimeError):
    pass


_IMAGE_EXTENSIONS = frozenset({".jpg", ".jpeg", ".png"})


_COMMAND_OPTIONS = {
    "feature_extractor": {
        "database_path",
        "image_path",
        "ImageReader.single_camera",
        "ImageReader.camera_model",
        "SiftExtraction.max_image_size",
        "SiftExtraction.max_num_features",
        "FeatureExtraction.use_gpu",
        "FeatureExtraction.num_threads",
    },
    "sequential_matcher": {
        "database_path",
        "FeatureMatching.use_gpu",
        "FeatureMatching.num_threads",
        "FeatureMatching.max_num_matches",
        "SequentialMatching.overlap",
        "SiftMatching.cpu_brute_force_matcher",
    },
    "exhaustive_matcher": {
        "database_path",
        "FeatureMatching.use_gpu",
        "FeatureMatching.num_threads",
        "FeatureMatching.max_num_matches",
        "ExhaustiveMatching.block_size",
        "SiftMatching.cpu_brute_force_matcher",
    },
    "matches_importer": {
        "database_path",
        "match_list_path",
        "match_type",
        "FeatureMatching.use_gpu",
        "FeatureMatching.num_threads",
        "FeatureMatching.max_num_matches",
        "SiftMatching.cpu_brute_force_matcher",
    },
    "mapper": {
        "database_path",
        "image_path",
        "output_path",
        "Mapper.ba_global_max_num_iterations",
    },
    "point_triangulator": {
        "database_path",
        "image_path",
        "input_path",
        "output_path",
    },
    "bundle_adjuster": {
        "input_path",
        "output_path",
        "BundleAdjustment.refine_focal_length",
        "BundleAdjustment.refine_principal_point",
        "BundleAdjustment.refine_extra_params",
        "BundleAdjustmentCeres.max_num_iterations",
        "BundleAdjustment.max_num_iterations",
    },
    "model_analyzer": {"path"},
    "image_undistorter": {
        "image_path",
        "input_path",
        "output_path",
        "output_type",
        "copy_policy",
        "max_image_size",
    },
    "model_converter": {"input_path", "output_path", "output_type"},
    "feature_importer": set(),
}


def _help(command: str | None = None) -> str:
    if command is None:
        commands = "\n".join(
            f"  {name}{' (not supported)' if name == 'feature_importer' else ''}"
            for name in _COMMAND_OPTIONS
        )
        return (
            "EasySplat COLMAP compatibility bridge\n"
            "pycolmap 3.13.0 · CPU\n\n"
            f"Commands:\n{commands}\n"
        )
    if command == "feature_importer":
        return "feature_importer is not supported by the EasySplat pycolmap bridge\n"
    options = "\n".join(
        f"  --{name} <value>" for name in sorted(_COMMAND_OPTIONS[command])
    )
    suffix = f"\nOptions:\n{options}\n" if options else "\n"
    return f"{command} via pycolmap 3.13.0 (CPU){suffix}"


def _parse_options(command: str, arguments: list[str]) -> dict[str, str]:
    if len(arguments) % 2 != 0:
        raise ColmapCliError(f"{command} options must be --name value pairs")
    allowed = _COMMAND_OPTIONS[command]
    parsed: dict[str, str] = {}
    for index in range(0, len(arguments), 2):
        flag = arguments[index]
        if not flag.startswith("--") or flag == "--":
            raise ColmapCliError(f"unexpected argument: {flag}")
        name = flag[2:]
        if name not in allowed:
            raise ColmapCliError(f"unrecognized option for {command}: {flag}")
        if name in parsed:
            raise ColmapCliError(f"duplicate option for {command}: {flag}")
        parsed[name] = arguments[index + 1]
    return parsed


def _required(options: dict[str, str], name: str) -> str:
    value = options.get(name)
    if not value:
        raise ColmapCliError(f"missing required option: --{name}")
    return value


def _integer(options: dict[str, str], name: str, default: int) -> int:
    value = options.get(name)
    if value is None:
        return default
    try:
        return int(value)
    except ValueError as exc:
        raise ColmapCliError(f"--{name} must be an integer") from exc


def _positive_integer(options: dict[str, str], name: str, default: int) -> int:
    value = _integer(options, name, default)
    if value < 1:
        raise ColmapCliError(f"--{name} must be at least 1")
    return value


def _boolean(options: dict[str, str], name: str, default: bool) -> bool:
    value = options.get(name)
    if value is None:
        return default
    if value == "1":
        return True
    if value == "0":
        return False
    raise ColmapCliError(f"--{name} must be 0 or 1")


def _load_pycolmap() -> Any:
    try:
        import pycolmap
    except ImportError as exc:
        raise ColmapCliError("pycolmap 3.13.0 is not installed") from exc
    if getattr(pycolmap, "__version__", None) != "3.13.0":
        raise ColmapCliError(
            f"pycolmap 3.13.0 is required; found {getattr(pycolmap, '__version__', 'unknown')}"
        )
    return pycolmap


def _feature_matching_options(pycolmap: Any, options: dict[str, str]) -> Any:
    matching = pycolmap.FeatureMatchingOptions()
    matching.num_threads = _integer(options, "FeatureMatching.num_threads", -1)
    matching.max_num_matches = _positive_integer(
        options,
        "FeatureMatching.max_num_matches",
        32768,
    )
    matching.use_gpu = False
    matching.sift.cpu_brute_force_matcher = _boolean(
        options,
        "SiftMatching.cpu_brute_force_matcher",
        False,
    )
    return matching


def _normalized_descriptors(descriptors: np.ndarray) -> np.ndarray:
    values = np.asarray(descriptors, dtype=np.float32)
    if values.ndim != 2:
        raise ColmapCliError("COLMAP descriptors must be a two-dimensional array")
    if not np.isfinite(values).all():
        raise ColmapCliError("COLMAP descriptors must contain only finite values")
    if values.shape[0] == 0:
        return values
    norms = np.linalg.norm(values, axis=1, keepdims=True)
    return values / np.maximum(norms, np.finfo(np.float32).eps)


def _nearest_two_l2(
    first: np.ndarray,
    second: np.ndarray,
    *,
    working_memory_bytes: int,
) -> tuple[np.ndarray, np.ndarray]:
    query_count = first.shape[0]
    candidate_count = second.shape[0]
    indices = np.full((query_count, 2), -1, dtype=np.int64)
    distances = np.full((query_count, 2), np.inf, dtype=np.float32)
    if query_count == 0 or candidate_count == 0:
        return indices, distances
    if working_memory_bytes < 16:
        raise ColmapCliError("descriptor matcher working-memory budget is too small")

    # Each product entry needs a float32 distance and an int64 argpartition index.
    # The extra margin covers norms and per-row tie resolution.
    max_pairs = max(1, working_memory_bytes // 16)
    query_block_size = max(1, min(query_count, math.isqrt(max_pairs)))
    candidate_block_size = max(1, min(candidate_count, max_pairs // query_block_size))
    candidate_norms = np.einsum("ij,ij->i", second, second)

    for query_start in range(0, query_count, query_block_size):
        query_stop = min(query_start + query_block_size, query_count)
        queries = first[query_start:query_stop]
        query_norms = np.einsum("ij,ij->i", queries, queries)
        best_indices = indices[query_start:query_stop]
        best_distances_squared = np.full(best_indices.shape, np.inf, dtype=np.float32)

        for candidate_start in range(0, candidate_count, candidate_block_size):
            candidate_stop = min(
                candidate_start + candidate_block_size, candidate_count
            )
            candidates = second[candidate_start:candidate_stop]
            block = np.matmul(queries, candidates.T)
            block *= -2.0
            block += query_norms[:, np.newaxis]
            block += candidate_norms[candidate_start:candidate_stop][np.newaxis, :]
            np.maximum(block, 0.0, out=block)

            if block.shape[1] == 1:
                local_indices = np.zeros((block.shape[0], 1), dtype=np.int64)
            else:
                local_indices = np.argpartition(block, kth=1, axis=1)[:, :2]

            for row in range(block.shape[0]):
                selected = local_indices[row]
                cutoff = float(np.max(block[row, selected]))
                tied = np.flatnonzero(block[row] <= cutoff)
                global_tied = tied + candidate_start
                order = np.lexsort((global_tied, block[row, tied]))
                local = [
                    (float(block[row, tied[index]]), int(global_tied[index]))
                    for index in order[:2]
                ]
                retained = [
                    (
                        float(best_distances_squared[row, column]),
                        int(best_indices[row, column]),
                    )
                    for column in range(2)
                    if best_indices[row, column] >= 0
                ]
                retained.extend(local)
                retained.sort(key=lambda match: (match[0], match[1]))
                retained = retained[:2]
                best_indices[row] = -1
                best_distances_squared[row] = np.inf
                for column, (distance_squared, candidate_index) in enumerate(retained):
                    best_indices[row, column] = candidate_index
                    best_distances_squared[row, column] = distance_squared

        indices[query_start:query_stop] = best_indices
        distances[query_start:query_stop] = np.sqrt(best_distances_squared)
    return indices, distances


def _ratio_matches(
    first: np.ndarray,
    second: np.ndarray,
    max_ratio: float,
    max_distance: float,
    *,
    working_memory_bytes: int,
) -> dict[int, tuple[int, float]]:
    if first.shape[0] == 0 or second.shape[0] < 2:
        return {}
    indices, distances = _nearest_two_l2(
        first,
        second,
        working_memory_bytes=working_memory_bytes,
    )
    accepted: dict[int, tuple[int, float]] = {}
    for query_index in range(first.shape[0]):
        best_index, runner_up_index = indices[query_index]
        best_distance, runner_up_distance = distances[query_index]
        if best_index < 0 or runner_up_index < 0:
            continue
        if (
            best_distance > max_distance
            or best_distance >= max_ratio * runner_up_distance
        ):
            continue
        accepted[query_index] = (int(best_index), float(best_distance))
    return accepted


def _match_descriptors(
    descriptors1: np.ndarray,
    descriptors2: np.ndarray,
    *,
    max_ratio: float,
    max_distance: float,
    cross_check: bool,
    max_num_matches: int,
    working_memory_bytes: int = 16 * 1024 * 1024,
) -> np.ndarray:
    first = _normalized_descriptors(descriptors1)
    second = _normalized_descriptors(descriptors2)
    if first.shape[1] != second.shape[1]:
        raise ColmapCliError("COLMAP descriptor dimensions do not match")
    forward = _ratio_matches(
        first,
        second,
        max_ratio,
        max_distance,
        working_memory_bytes=working_memory_bytes,
    )
    reverse = (
        _ratio_matches(
            second,
            first,
            max_ratio,
            max_distance,
            working_memory_bytes=working_memory_bytes,
        )
        if cross_check
        else {}
    )
    matches = [
        (query, train, distance)
        for query, (train, distance) in forward.items()
        if not cross_check or reverse.get(train, (-1, 0.0))[0] == query
    ]
    matches.sort(key=lambda match: (match[2], match[0], match[1]))
    limited = matches[:max_num_matches]
    if not limited:
        return np.empty((0, 2), dtype=np.uint32)
    return np.asarray([(query, train) for query, train, _ in limited], dtype=np.uint32)


def _read_pairs(path: str) -> list[tuple[str, str]]:
    try:
        lines = Path(path).read_text(encoding="utf-8").splitlines()
    except OSError as exc:
        raise ColmapCliError(f"could not read pair list: {path}") from exc
    pairs: list[tuple[str, str]] = []
    for line_number, line in enumerate(lines, start=1):
        stripped = line.strip()
        if not stripped or stripped.startswith("#"):
            continue
        names = stripped.split()
        if len(names) != 2:
            raise ColmapCliError(
                f"invalid pair list line {line_number}: expected two image names"
            )
        if names[0] == names[1]:
            raise ColmapCliError(
                f"invalid pair list line {line_number}: image cannot match itself"
            )
        pairs.append((names[0], names[1]))
    if not pairs:
        raise ColmapCliError("pair list did not contain any image pairs")
    return pairs


def _input_image_names(image_path: str) -> list[str]:
    root = Path(image_path)
    if not root.is_dir():
        raise ColmapCliError(f"image path is not a directory: {image_path}")
    names: list[str] = []
    try:
        for path in root.rglob("*"):
            if path.suffix.lower() not in _IMAGE_EXTENSIONS:
                continue
            if stat.S_ISREG(path.stat(follow_symlinks=False).st_mode):
                names.append(path.relative_to(root).as_posix())
    except OSError as exc:
        raise ColmapCliError(f"could not inspect image path: {image_path}") from exc
    names.sort()
    if not names:
        raise ColmapCliError("image path contains no supported regular image files")
    return names


def _matrix_rows(values: Any) -> int:
    array = np.asarray(values)
    if array.ndim != 2 or array.size == 0:
        return 0
    return int(array.shape[0])


def _validate_feature_extraction(
    pycolmap: Any, database_path: str, image_path: str
) -> None:
    expected_names = _input_image_names(image_path)
    database = pycolmap.Database.open(database_path)
    try:
        images = list(database.read_all_images())
        database_names = [str(image.name) for image in images]
        seen: set[str] = set()
        duplicates: set[str] = set()
        for name in database_names:
            if name in seen:
                duplicates.add(name)
            seen.add(name)

        missing = sorted(set(expected_names) - seen)
        unexpected = sorted(seen - set(expected_names))
        if len(images) != len(expected_names) or missing or unexpected or duplicates:
            details = [f"database rows: {len(images)}"]
            if missing:
                details.append(f"missing: {', '.join(missing)}")
            if unexpected:
                details.append(f"unexpected: {', '.join(unexpected)}")
            if duplicates:
                details.append(f"duplicates: {', '.join(sorted(duplicates))}")
            raise ColmapCliError(
                f"feature extraction incomplete for {len(expected_names)} input images; "
                + "; ".join(details)
            )

        usable_images = 0
        inconsistent_features: list[str] = []
        for image in images:
            keypoint_count = _matrix_rows(database.read_keypoints(image.image_id))
            descriptor_count = _matrix_rows(database.read_descriptors(image.image_id))
            if keypoint_count != descriptor_count:
                inconsistent_features.append(
                    f"{image.name} (keypoints={keypoint_count}, descriptors={descriptor_count})"
                )
            elif keypoint_count > 0:
                usable_images += 1
        if inconsistent_features:
            raise ColmapCliError(
                f"feature extraction incomplete for {len(expected_names)} input images; "
                f"mismatched features: {', '.join(inconsistent_features)}"
            )
        if usable_images < 2:
            raise ColmapCliError(
                "feature extraction produced fewer than two images with usable features"
            )
    finally:
        database.close()


def _run_feature_extractor(pycolmap: Any, options: dict[str, str]) -> None:
    database_path = _required(options, "database_path")
    image_path = _required(options, "image_path")
    camera_model = options.get("ImageReader.camera_model", "SIMPLE_RADIAL")
    reader = pycolmap.ImageReaderOptions()
    reader.camera_model = camera_model
    extraction = pycolmap.FeatureExtractionOptions()
    extraction.max_image_size = _positive_integer(
        options,
        "SiftExtraction.max_image_size",
        3200,
    )
    extraction.num_threads = _integer(options, "FeatureExtraction.num_threads", -1)
    extraction.use_gpu = False
    extraction.sift.max_num_features = _positive_integer(
        options,
        "SiftExtraction.max_num_features",
        8192,
    )
    camera_mode = (
        pycolmap.CameraMode.SINGLE
        if _boolean(options, "ImageReader.single_camera", False)
        else pycolmap.CameraMode.AUTO
    )
    pycolmap.extract_features(
        database_path=database_path,
        image_path=image_path,
        camera_mode=camera_mode,
        camera_model=camera_model,
        reader_options=reader,
        extraction_options=extraction,
        device=pycolmap.Device.cpu,
    )
    _validate_feature_extraction(pycolmap, database_path, image_path)


def _run_standard_matcher(pycolmap: Any, command: str, options: dict[str, str]) -> None:
    database_path = _required(options, "database_path")
    matching = _feature_matching_options(pycolmap, options)
    verification = pycolmap.TwoViewGeometryOptions()
    if command == "sequential_matcher":
        pairing = pycolmap.SequentialPairingOptions()
        pairing.overlap = _positive_integer(options, "SequentialMatching.overlap", 10)
        pycolmap.match_sequential(
            database_path,
            matching_options=matching,
            pairing_options=pairing,
            verification_options=verification,
            device=pycolmap.Device.cpu,
        )
        return
    pairing = pycolmap.ExhaustivePairingOptions()
    pairing.block_size = _positive_integer(options, "ExhaustiveMatching.block_size", 50)
    pycolmap.match_exhaustive(
        database_path,
        matching_options=matching,
        pairing_options=pairing,
        verification_options=verification,
        device=pycolmap.Device.cpu,
    )


def _run_matches_importer(pycolmap: Any, options: dict[str, str]) -> None:
    if options.get("match_type", "pairs") != "pairs":
        raise ColmapCliError("matches_importer supports only --match_type pairs")
    database_path = _required(options, "database_path")
    pairs_path = _required(options, "match_list_path")
    pairs = _read_pairs(pairs_path)
    matching = _feature_matching_options(pycolmap, options)
    sift = matching.sift
    database = pycolmap.Database.open(database_path)
    try:
        for name1, name2 in pairs:
            image1 = database.read_image_with_name(name1)
            image2 = database.read_image_with_name(name2)
            if image1 is None:
                raise ColmapCliError(
                    f"pair list image is absent from database: {name1}"
                )
            if image2 is None:
                raise ColmapCliError(
                    f"pair list image is absent from database: {name2}"
                )
            low_id, high_id = sorted((image1.image_id, image2.image_id))
            if database.exists_matches(low_id, high_id):
                continue
            matches = _match_descriptors(
                database.read_descriptors(image1.image_id),
                database.read_descriptors(image2.image_id),
                max_ratio=float(getattr(sift, "max_ratio", 0.8)),
                max_distance=float(getattr(sift, "max_distance", 0.7)),
                cross_check=bool(getattr(sift, "cross_check", True)),
                max_num_matches=matching.max_num_matches,
            )
            if image1.image_id == low_id:
                database.write_matches(low_id, high_id, matches)
            else:
                database.write_matches(low_id, high_id, matches[:, ::-1].copy())
    finally:
        database.close()
    pycolmap.verify_matches(
        database_path,
        pairs_path,
        pycolmap.TwoViewGeometryOptions(),
    )


def _incremental_options(pycolmap: Any) -> Any:
    options = pycolmap.IncrementalPipelineOptions()
    options.ba_use_gpu = False
    return options


def _run_mapper(pycolmap: Any, options: dict[str, str]) -> None:
    pipeline = _incremental_options(pycolmap)
    pipeline.ba_global_max_num_iterations = _positive_integer(
        options,
        "Mapper.ba_global_max_num_iterations",
        50,
    )
    output_path = _required(options, "output_path")
    Path(output_path).mkdir(parents=True, exist_ok=True)
    pycolmap.incremental_mapping(
        database_path=_required(options, "database_path"),
        image_path=_required(options, "image_path"),
        output_path=output_path,
        options=pipeline,
    )


def _read_reconstruction(pycolmap: Any, path: str) -> Any:
    reconstruction = pycolmap.Reconstruction()
    reconstruction.read(path)
    return reconstruction


def _run_point_triangulator(pycolmap: Any, options: dict[str, str]) -> None:
    output_path = _required(options, "output_path")
    Path(output_path).mkdir(parents=True, exist_ok=True)
    reconstruction = _read_reconstruction(pycolmap, _required(options, "input_path"))
    pycolmap.triangulate_points(
        reconstruction=reconstruction,
        database_path=_required(options, "database_path"),
        image_path=_required(options, "image_path"),
        output_path=output_path,
        clear_points=True,
        options=_incremental_options(pycolmap),
        refine_intrinsics=False,
    )


def _remove_invalid_point_errors(reconstruction: Any) -> int:
    points = list(reconstruction.points3D.items())
    finite_errors = np.asarray(
        [
            float(point.error)
            for _, point in points
            if math.isfinite(float(point.error))
        ],
        dtype=np.float64,
    )
    if finite_errors.size:
        median = float(np.median(finite_errors))
        mad = float(np.median(np.abs(finite_errors - median)))
        robust_limit = median + 10.0 * max(mad, np.finfo(np.float64).eps)
        limit = max(20.0, robust_limit)
    else:
        limit = 20.0
    removed = 0
    for point_id, point in points:
        error = float(point.error)
        if not math.isfinite(error) or error > limit or error > 1_000_000.0:
            reconstruction.delete_point3D(point_id)
            removed += 1
    return removed


def _run_bundle_adjuster(pycolmap: Any, options: dict[str, str]) -> None:
    reconstruction = _read_reconstruction(pycolmap, _required(options, "input_path"))
    adjustment = pycolmap.BundleAdjustmentOptions()
    adjustment.refine_focal_length = _boolean(
        options,
        "BundleAdjustment.refine_focal_length",
        True,
    )
    adjustment.refine_principal_point = _boolean(
        options,
        "BundleAdjustment.refine_principal_point",
        False,
    )
    adjustment.refine_extra_params = _boolean(
        options,
        "BundleAdjustment.refine_extra_params",
        True,
    )
    adjustment.use_gpu = False
    iteration_name = (
        "BundleAdjustmentCeres.max_num_iterations"
        if "BundleAdjustmentCeres.max_num_iterations" in options
        else "BundleAdjustment.max_num_iterations"
    )
    adjustment.solver_options.max_num_iterations = _positive_integer(
        options,
        iteration_name,
        50,
    )
    pycolmap.bundle_adjustment(reconstruction, adjustment)
    reconstruction.update_point_3d_errors()
    _remove_invalid_point_errors(reconstruction)
    reconstruction.update_point_3d_errors()
    output_path = _required(options, "output_path")
    Path(output_path).mkdir(parents=True, exist_ok=True)
    reconstruction.write(output_path)


def _run_model_analyzer(pycolmap: Any, options: dict[str, str]) -> str:
    reconstruction = _read_reconstruction(pycolmap, _required(options, "path"))
    registered = int(reconstruction.num_reg_images())
    total = int(reconstruction.num_images())
    points = int(reconstruction.num_points3D())
    observations = int(reconstruction.compute_num_observations())
    track_length = float(reconstruction.compute_mean_track_length()) if points else 0.0
    reprojection = (
        float(reconstruction.compute_mean_reprojection_error()) if observations else 0.0
    )
    if not math.isfinite(track_length):
        track_length = 0.0
    if not math.isfinite(reprojection):
        raise ColmapCliError(
            "model contains a non-finite mean reprojection error despite having observations"
        )
    return "\n".join(
        [
            f"Cameras: {int(reconstruction.num_cameras())}",
            f"Images: {total}",
            f"Registered images: {registered} / {total}",
            f"Points: {points}",
            f"Observations: {observations}",
            f"Mean track length: {track_length:.6g}",
            f"Mean reprojection error: {reprojection:.6g}",
        ]
    )


def _run_image_undistorter(pycolmap: Any, options: dict[str, str]) -> None:
    output_type = options.get("output_type", "COLMAP").upper()
    if output_type != "COLMAP":
        raise ColmapCliError("image_undistorter supports only --output_type COLMAP")
    copy_policy = options.get("copy_policy", "COPY").upper()
    if copy_policy != "COPY":
        raise ColmapCliError("image_undistorter supports only --copy_policy COPY")
    undistort = pycolmap.UndistortCameraOptions()
    undistort.max_image_size = _positive_integer(options, "max_image_size", 3200)
    pycolmap.undistort_images(
        output_path=_required(options, "output_path"),
        input_path=_required(options, "input_path"),
        image_path=_required(options, "image_path"),
        output_type=output_type,
        copy_policy=pycolmap.CopyType.copy,
        undistort_options=undistort,
    )


def _run_model_converter(pycolmap: Any, options: dict[str, str]) -> None:
    reconstruction = _read_reconstruction(pycolmap, _required(options, "input_path"))
    output_path = _required(options, "output_path")
    Path(output_path).mkdir(parents=True, exist_ok=True)
    output_type = options.get("output_type", "TXT").upper()
    if output_type == "TXT":
        reconstruction.write_text(output_path)
    elif output_type == "BIN":
        reconstruction.write(output_path)
    else:
        raise ColmapCliError("model_converter supports only TXT and BIN output")


def run_command(
    command: str,
    options: dict[str, str],
    *,
    pycolmap_module: Any | None = None,
) -> str | None:
    if command not in _COMMAND_OPTIONS:
        raise ColmapCliError(f"unrecognized command: {command}")
    if command == "feature_importer":
        raise ColmapCliError(
            "feature_importer is not supported by the EasySplat bridge"
        )
    pycolmap = pycolmap_module or _load_pycolmap()
    if command == "feature_extractor":
        _run_feature_extractor(pycolmap, options)
    elif command in {"sequential_matcher", "exhaustive_matcher"}:
        _run_standard_matcher(pycolmap, command, options)
    elif command == "matches_importer":
        _run_matches_importer(pycolmap, options)
    elif command == "mapper":
        _run_mapper(pycolmap, options)
    elif command == "point_triangulator":
        _run_point_triangulator(pycolmap, options)
    elif command == "bundle_adjuster":
        _run_bundle_adjuster(pycolmap, options)
    elif command == "model_analyzer":
        return _run_model_analyzer(pycolmap, options)
    elif command == "image_undistorter":
        _run_image_undistorter(pycolmap, options)
    elif command == "model_converter":
        _run_model_converter(pycolmap, options)
    return None


def main(argv: list[str] | None = None) -> int:
    arguments = list(sys.argv[1:] if argv is None else argv)
    if not arguments or arguments[0] in {"-h", "--help"}:
        print(_help(), end="")
        return 0
    command = arguments.pop(0)
    if command not in _COMMAND_OPTIONS:
        print(f"ERROR: unrecognized command: {command}", file=sys.stderr)
        return 2
    if any(argument in {"-h", "--help"} for argument in arguments):
        print(_help(command), end="")
        return 0
    try:
        options = _parse_options(command, arguments)
        report = run_command(command, options)
        if report:
            print(report)
        return 0
    except ColmapCliError as exc:
        print(f"ERROR: {command} failed: {exc}", file=sys.stderr)
        return 2
    except KeyboardInterrupt:
        return 130
    except Exception as exc:
        print(f"ERROR: {command} failed: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
