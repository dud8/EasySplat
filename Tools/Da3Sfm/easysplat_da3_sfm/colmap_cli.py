from __future__ import annotations

import json
import math
import os
import sqlite3
import stat
import sys
import tempfile
from pathlib import Path
from typing import Any, NamedTuple

import numpy as np


class ColmapCliError(RuntimeError):
    pass


_IMAGE_EXTENSIONS = frozenset({".jpg", ".jpeg", ".png"})
_PYCOLMAP_VERSION = "4.1.0"

_REQUIRED_PYCOLMAP_API_PATHS = (
    "BundleAdjustmentOptions",
    "Camera",
    "CameraMode.AUTO",
    "CameraMode.SINGLE",
    "Database.open",
    "Device.cpu",
    "FeatureDescriptors",
    "FeatureExtractionOptions",
    "FeatureExtractorType.SIFT",
    "FeatureMatchingOptions",
    "FileCopyType.copy",
    "Image",
    "ImageReaderOptions",
    "ImportedPairingOptions",
    "IncrementalPipelineOptions",
    "Reconstruction",
    "TwoViewGeometryOptions",
    "UndistortCameraOptions",
    "VisualIndex.BuildOptions",
    "VisualIndex.create",
    "VocabTreePairGenerator",
    "VocabTreePairingOptions",
    "bundle_adjustment",
    "extract_features",
    "incremental_mapping",
    "match_image_pairs",
    "triangulate_points",
    "undistort_images",
)

_CALLABLE_PYCOLMAP_API_PATHS = frozenset(_REQUIRED_PYCOLMAP_API_PATHS) - {
    "CameraMode.AUTO",
    "CameraMode.SINGLE",
    "Device.cpu",
    "FeatureExtractorType.SIFT",
    "FileCopyType.copy",
}

_REQUIRED_OPTION_FIELDS = {
    "ImageReaderOptions": ("camera_model",),
    "FeatureExtractionOptions": (
        "max_image_size",
        "num_threads",
        "use_gpu",
        "sift.max_num_features",
    ),
    "FeatureMatchingOptions": (
        "num_threads",
        "max_num_matches",
        "use_gpu",
        "sift.cpu_brute_force_matcher",
    ),
    "ImportedPairingOptions": ("match_list_path",),
    "IncrementalPipelineOptions": (
        "ba_use_gpu",
        "ba_global_frames_ratio",
        "ba_global_points_ratio",
        "ba_global_max_refinements",
        "ba_global_max_num_iterations",
        "random_seed",
        "ba_refine_focal_length",
    ),
    "BundleAdjustmentOptions": (
        "refine_focal_length",
        "refine_principal_point",
        "refine_extra_params",
        "ceres.use_gpu",
        "ceres.solver_options.max_num_iterations",
    ),
    "UndistortCameraOptions": ("max_image_size",),
    "VisualIndex.BuildOptions": (
        "num_visual_words",
        "num_iterations",
        "num_rounds",
        "num_checks",
        "num_threads",
    ),
    "VocabTreePairingOptions": (
        "vocab_tree_path",
        "num_images",
        "num_nearest_neighbors",
        "num_checks",
        "num_images_after_verification",
        "max_num_features",
        "num_threads",
    ),
}


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
    "matches_importer": {
        "database_path",
        "match_list_path",
        "match_type",
        "FeatureMatching.use_gpu",
        "FeatureMatching.num_threads",
        "FeatureMatching.max_num_matches",
        "SiftMatching.cpu_brute_force_matcher",
    },
    "local_vocab_retriever": {
        "database_path",
        "output_pair_list_path",
        "query_image_list_path",
        "excluded_pair_list_path",
        "num_images",
        "returned_neighbor_count",
        "minimum_frame_separation",
        "num_visual_words",
        "max_features_per_image",
        "max_training_descriptors",
        "num_iterations",
        "num_rounds",
        "num_checks",
        "num_threads",
    },
    "mapper": {
        "database_path",
        "image_path",
        "output_path",
        "Mapper.ba_global_frames_ratio",
        "Mapper.ba_global_points_ratio",
        "Mapper.ba_global_max_refinements",
        "Mapper.ba_global_max_num_iterations",
        "Mapper.random_seed",
        "Mapper.ba_refine_focal_length",
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
            f"pycolmap {_PYCOLMAP_VERSION} · CPU\n\n"
            f"Commands:\n{commands}\n"
        )
    if command == "feature_importer":
        return "feature_importer is not supported by the EasySplat pycolmap bridge\n"
    options = "\n".join(
        f"  --{name} <value>" for name in sorted(_COMMAND_OPTIONS[command])
    )
    suffix = f"\nOptions:\n{options}\n" if options else "\n"
    return f"{command} via pycolmap {_PYCOLMAP_VERSION} (CPU){suffix}"


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


def _bounded_integer(
    options: dict[str, str], name: str, default: int, minimum: int, maximum: int
) -> int:
    value = _integer(options, name, default)
    if value < minimum or value > maximum:
        raise ColmapCliError(f"--{name} must be between {minimum} and {maximum}")
    return value


def _nonnegative_int32(options: dict[str, str], name: str, default: int) -> int:
    value = _integer(options, name, default)
    if value < 0 or value > 2_147_483_647:
        raise ColmapCliError(f"--{name} must be between 0 and 2147483647")
    return value


def _refinement_ratio(options: dict[str, str], name: str, default: float) -> float:
    text = options.get(name)
    if text is None:
        return default
    try:
        value = float(text)
    except ValueError as exc:
        raise ColmapCliError(f"--{name} must be a finite number") from exc
    if not math.isfinite(value):
        raise ColmapCliError(f"--{name} must be a finite number")
    if value <= 1.0:
        raise ColmapCliError(f"--{name} must be greater than 1.0")
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
        raise ColmapCliError(f"pycolmap {_PYCOLMAP_VERSION} is not installed") from exc
    if getattr(pycolmap, "__version__", None) != _PYCOLMAP_VERSION:
        raise ColmapCliError(
            f"pycolmap {_PYCOLMAP_VERSION} is required; "
            f"found {getattr(pycolmap, '__version__', 'unknown')}"
        )
    return pycolmap


def _runtime_self_check() -> dict[str, object]:
    pycolmap = _load_pycolmap()
    unavailable: list[str] = []
    sentinel = object()

    def resolve(root: object, path: str) -> object:
        value = root
        for component in path.split("."):
            value = getattr(value, component, sentinel)
            if value is sentinel:
                break
        return value

    for path in _REQUIRED_PYCOLMAP_API_PATHS:
        value = resolve(pycolmap, path)
        if value is sentinel or (
            path in _CALLABLE_PYCOLMAP_API_PATHS and not callable(value)
        ):
            unavailable.append(path)

    for constructor_path, fields in _REQUIRED_OPTION_FIELDS.items():
        constructor = resolve(pycolmap, constructor_path)
        if constructor is sentinel or not callable(constructor):
            continue
        try:
            options = constructor()
        except Exception:
            unavailable.append(f"{constructor_path}()")
            continue
        for field in fields:
            if resolve(options, field) is sentinel:
                unavailable.append(f"{constructor_path}.{field}")

    visual_index_factory = resolve(pycolmap, "VisualIndex.create")
    if callable(visual_index_factory):
        try:
            visual_index = visual_index_factory(128, 64)
        except Exception:
            unavailable.append("VisualIndex.create(128, 64)")
        else:
            for method in ("build", "write"):
                if not callable(getattr(visual_index, method, None)):
                    unavailable.append(f"VisualIndex.{method}")

    if unavailable:
        raise ColmapCliError(
            "required PyCOLMAP APIs are unavailable: "
            + ", ".join(sorted(set(unavailable)))
        )
    return {
        "runtime": "pycolmap",
        "runtime_version": _PYCOLMAP_VERSION,
        "schema_version": 1,
        "status": "ok",
    }


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


def _read_pairs(
    path: str, *, allow_empty: bool = False
) -> list[tuple[str, str]]:
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
    if not pairs and not allow_empty:
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


def _run_matches_importer(pycolmap: Any, options: dict[str, str]) -> None:
    if options.get("match_type", "pairs") != "pairs":
        raise ColmapCliError("matches_importer supports only --match_type pairs")
    database_path = _required(options, "database_path")
    pairs_path = _required(options, "match_list_path")
    pairs = _read_pairs(pairs_path)
    matching = _feature_matching_options(pycolmap, options)
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
    finally:
        database.close()

    pairing = pycolmap.ImportedPairingOptions()
    pairing.match_list_path = pairs_path
    pycolmap.match_image_pairs(
        database_path=database_path,
        matching_options=matching,
        pairing_options=pairing,
        verification_options=pycolmap.TwoViewGeometryOptions(),
        device=pycolmap.Device.cpu,
    )


def _largest_scale_rows(keypoints: Any, limit: int) -> np.ndarray:
    matrix = np.asarray(keypoints)
    if matrix.ndim != 2 or matrix.shape[1] < 4:
        raise ColmapCliError("retrieval keypoints must be an Nx4 or Nx6 matrix")
    if matrix.shape[1] >= 6:
        scales = np.sqrt(
            np.abs(matrix[:, 2] * matrix[:, 5] - matrix[:, 3] * matrix[:, 4])
        )
    else:
        scales = matrix[:, 2]
    if not np.all(np.isfinite(scales)):
        raise ColmapCliError("retrieval keypoint scales must be finite")
    row_ids = np.arange(matrix.shape[0], dtype=np.int64)
    return np.lexsort((row_ids, -scales))[:limit]


class _RetrievalImage(NamedTuple):
    image_id: int
    name: str


def _selected_retrieval_features(
    source: sqlite3.Connection,
    image: _RetrievalImage,
    *,
    descriptor_has_type: bool,
    max_features_per_image: int,
) -> tuple[np.ndarray, np.ndarray]:
    keypoints = _read_feature_matrix(
        source,
        table="keypoints",
        image_id=int(image.image_id),
        dtype=np.dtype(np.float32),
    )
    descriptors = _read_feature_matrix(
        source,
        table="descriptors",
        image_id=int(image.image_id),
        dtype=np.dtype(np.uint8),
        expected_columns=128,
        descriptor_has_type=descriptor_has_type,
    )
    if keypoints.shape == (0, 0):
        keypoints = np.empty((0, 4), dtype=np.float32)
    if keypoints.ndim != 2:
        raise ColmapCliError(f"invalid keypoints for retrieval image: {image.name}")
    if keypoints.shape[0] != descriptors.shape[0]:
        raise ColmapCliError(f"mismatched retrieval features for image: {image.name}")
    if descriptors.shape[0] == 0:
        return (
            np.empty((0, keypoints.shape[1]), dtype=np.float32),
            np.empty((0, 128), dtype=np.uint8),
        )
    rows = _largest_scale_rows(keypoints, max_features_per_image)
    return (
        np.ascontiguousarray(keypoints[rows], dtype=np.float32),
        np.ascontiguousarray(descriptors[rows], dtype=np.uint8),
    )


def _readonly_feature_database(path: Path) -> sqlite3.Connection:
    for suffix in ("-wal", "-journal"):
        sidecar = Path(f"{path}{suffix}")
        try:
            if sidecar.is_file() and sidecar.stat().st_size > 0:
                raise ColmapCliError(
                    f"retrieval database has a pending SQLite {suffix[1:]} sidecar"
                )
        except OSError as exc:
            raise ColmapCliError(
                f"could not inspect retrieval database sidecars: {path}"
            ) from exc
    database: sqlite3.Connection | None = None
    try:
        database = sqlite3.connect(
            f"{path.as_uri()}?mode=ro&immutable=1",
            uri=True,
        )
        database.execute("PRAGMA query_only = ON")
        database.execute("BEGIN")
        return database
    except sqlite3.Error as exc:
        if database is not None:
            database.close()
        raise ColmapCliError(
            f"could not open retrieval database read-only: {path}"
        ) from exc


def _database_columns(database: sqlite3.Connection, table: str) -> set[str]:
    try:
        return {str(row[1]) for row in database.execute(f"PRAGMA table_info({table})")}
    except sqlite3.Error as exc:
        raise ColmapCliError(f"could not inspect retrieval table: {table}") from exc


def _validate_retrieval_schema(database: sqlite3.Connection) -> bool:
    required_by_table = {
        "images": {"image_id", "name"},
        "keypoints": {"image_id", "rows", "cols", "data"},
        "descriptors": {"image_id", "rows", "cols", "data"},
    }
    columns_by_table = {
        table: _database_columns(database, table) for table in required_by_table
    }
    for table, required in required_by_table.items():
        if not required.issubset(columns_by_table[table]):
            raise ColmapCliError(f"retrieval database has an invalid {table} table")
    return "type" in columns_by_table["descriptors"]


def _read_feature_matrix(
    database: sqlite3.Connection,
    *,
    table: str,
    image_id: int,
    dtype: np.dtype[Any],
    expected_columns: int | None = None,
    descriptor_has_type: bool = False,
) -> np.ndarray:
    query = f"SELECT rows, cols, data FROM {table} WHERE image_id = ?"
    arguments: tuple[int, ...] = (image_id,)
    if table == "descriptors" and descriptor_has_type:
        query += " AND type = ?"
        arguments = (image_id, 0)
    try:
        rows = database.execute(query, arguments).fetchall()
    except sqlite3.Error as exc:
        raise ColmapCliError(
            f"could not read retrieval {table} for image ID {image_id}"
        ) from exc
    if not rows:
        columns_count = expected_columns or 0
        return np.empty((0, columns_count), dtype=dtype)
    if len(rows) != 1:
        raise ColmapCliError(
            f"retrieval database has duplicate {table} rows for image ID {image_id}"
        )
    row_count, column_count, blob = rows[0]
    if (
        not isinstance(row_count, int)
        or not isinstance(column_count, int)
        or row_count < 0
        or column_count < 0
        or (expected_columns is not None and column_count != expected_columns)
    ):
        raise ColmapCliError(
            f"retrieval database has invalid {table} dimensions for image ID {image_id}"
        )
    payload = b"" if blob is None else bytes(blob)
    expected_bytes = row_count * column_count * np.dtype(dtype).itemsize
    if len(payload) != expected_bytes:
        raise ColmapCliError(
            f"retrieval database has an invalid {table} blob for image ID {image_id}"
        )
    return np.frombuffer(payload, dtype=dtype).reshape(row_count, column_count)


def _populate_retrieval_database(
    pycolmap: Any,
    source: sqlite3.Connection,
    retrieval_database: Any,
    *,
    max_features_per_image: int,
    max_training_descriptors: int,
) -> tuple[list[Any], np.ndarray]:
    descriptor_has_type = _validate_retrieval_schema(source)
    try:
        image_rows = source.execute(
            "SELECT image_id, name FROM images ORDER BY name"
        ).fetchall()
    except sqlite3.Error as exc:
        raise ColmapCliError("retrieval database has an invalid images table") from exc
    images = [_RetrievalImage(int(image_id), str(name)) for image_id, name in image_rows]
    if len(images) < 2:
        raise ColmapCliError("retrieval database contains fewer than two images")
    image_ids = [int(image.image_id) for image in images]
    image_names = [str(image.name) for image in images]
    if len(set(image_ids)) != len(image_ids):
        raise ColmapCliError("retrieval database contains duplicate image identifiers")
    if len(set(image_names)) != len(image_names) or any(
        not name or any(character.isspace() for character in name)
        for name in image_names
    ):
        raise ColmapCliError("retrieval database contains invalid image names")

    camera = pycolmap.Camera(
        model="SIMPLE_PINHOLE",
        width=1,
        height=1,
        params=[1.0, 0.5, 0.5],
        camera_id=1,
    )
    retrieval_database.write_camera(camera, use_camera_id=True)
    selected_counts: list[tuple[_RetrievalImage, int]] = []
    usable_images = 0
    for image in sorted(images, key=lambda value: str(value.name)):
        retrieval_database.write_image(
            pycolmap.Image(
                name=str(image.name),
                camera_id=1,
                image_id=int(image.image_id),
            ),
            use_image_id=True,
        )
        selected_keypoints, selected_descriptors = _selected_retrieval_features(
            source,
            image,
            descriptor_has_type=descriptor_has_type,
            max_features_per_image=max_features_per_image,
        )
        retrieval_database.write_keypoints(int(image.image_id), selected_keypoints)
        retrieval_database.write_descriptors(
            int(image.image_id),
            pycolmap.FeatureDescriptors(
                pycolmap.FeatureExtractorType.SIFT,
                selected_descriptors,
            ),
        )
        if selected_descriptors.shape[0] == 0:
            continue
        selected_counts.append((image, int(selected_descriptors.shape[0])))
        usable_images += 1
    if usable_images < 2:
        raise ColmapCliError("retrieval requires two images with usable features")

    total_descriptors = sum(count for _, count in selected_counts)
    training_count = min(total_descriptors, max_training_descriptors)
    if training_count == total_descriptors:
        sampled_positions = np.arange(training_count, dtype=np.int64)
    elif training_count == 1:
        sampled_positions = np.asarray([0], dtype=np.int64)
    else:
        sampled_positions = (
            np.arange(training_count, dtype=np.int64)
            * (total_descriptors - 1)
            // (training_count - 1)
        )
    training = np.empty((training_count, 128), dtype=np.uint8)
    source_offset = 0
    destination_offset = 0
    for image, descriptor_count in selected_counts:
        source_end = source_offset + descriptor_count
        first = int(np.searchsorted(sampled_positions, source_offset, side="left"))
        last = int(np.searchsorted(sampled_positions, source_end, side="left"))
        if first < last:
            _, selected_descriptors = _selected_retrieval_features(
                source,
                image,
                descriptor_has_type=descriptor_has_type,
                max_features_per_image=max_features_per_image,
            )
            local_rows = sampled_positions[first:last] - source_offset
            destination_end = destination_offset + len(local_rows)
            training[destination_offset:destination_end] = selected_descriptors[
                local_rows
            ]
            destination_offset = destination_end
        source_offset = source_end
    if destination_offset != training_count:
        raise ColmapCliError("retrieval training sampling was incomplete")
    return images, training


def _regular_input_path(value: str, label: str) -> Path:
    path = Path(value)
    if not path.is_absolute():
        raise ColmapCliError(f"{label} must be an absolute path")
    try:
        mode = path.lstat().st_mode
    except OSError as exc:
        raise ColmapCliError(f"could not inspect {label}: {path}") from exc
    if not stat.S_ISREG(mode):
        raise ColmapCliError(f"{label} is not a regular file: {path}")
    return path


def _safe_output_path(value: str) -> Path:
    output = Path(value)
    if not output.is_absolute():
        raise ColmapCliError("output pair list path must be absolute")
    try:
        parent_mode = output.parent.lstat().st_mode
    except OSError as exc:
        raise ColmapCliError(
            f"could not inspect output pair list directory: {output.parent}"
        ) from exc
    if not stat.S_ISDIR(parent_mode):
        raise ColmapCliError(
            f"output pair list directory is not a directory: {output.parent}"
        )
    try:
        output_mode = output.lstat().st_mode
    except FileNotFoundError:
        return output
    except OSError as exc:
        raise ColmapCliError(f"could not inspect output pair list: {output}") from exc
    if not stat.S_ISREG(output_mode):
        raise ColmapCliError(f"output pair list is not a regular file: {output}")
    return output


def _query_image_ids(
    database_images: list[Any], query_image_list_path: str | None
) -> list[int]:
    images_by_name = {str(image.name): int(image.image_id) for image in database_images}
    if len(images_by_name) != len(database_images):
        raise ColmapCliError("retrieval database contains duplicate image names")
    if query_image_list_path is None:
        return [
            int(image.image_id)
            for image in sorted(database_images, key=lambda value: str(value.name))
        ]
    path = _regular_input_path(query_image_list_path, "query image list")
    try:
        lines = path.read_text(encoding="utf-8").splitlines()
    except (OSError, UnicodeError) as exc:
        raise ColmapCliError(f"could not read query image list: {path}") from exc
    query_ids: list[int] = []
    seen: set[str] = set()
    for line in lines:
        name = line.strip()
        if not name or name.startswith("#") or name in seen:
            continue
        image_id = images_by_name.get(name)
        if image_id is None:
            raise ColmapCliError(f"query image is absent from database: {name}")
        seen.add(name)
        query_ids.append(image_id)
    if not query_ids:
        raise ColmapCliError("query image list did not contain any database images")
    return query_ids


def _atomic_write_pair_lines(output: Path, lines: list[str]) -> None:
    descriptor, temporary_name = tempfile.mkstemp(
        prefix=f".{output.name}.", suffix=".tmp", dir=output.parent
    )
    temporary = Path(temporary_name)
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8", newline="\n") as stream:
            if lines:
                stream.write("\n".join(lines) + "\n")
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, output)
        try:
            directory = os.open(output.parent, os.O_RDONLY)
            try:
                os.fsync(directory)
            finally:
                os.close(directory)
        except OSError:
            pass
    finally:
        temporary.unlink(missing_ok=True)


def _run_local_vocab_retriever(pycolmap: Any, options: dict[str, str]) -> str:
    num_images = _bounded_integer(options, "num_images", 20, 1, 256)
    returned_count = _bounded_integer(
        options, "returned_neighbor_count", 8, 1, 64
    )
    if returned_count > num_images:
        raise ColmapCliError(
            "--returned_neighbor_count cannot exceed --num_images"
        )
    minimum_separation = _bounded_integer(
        options, "minimum_frame_separation", 0, 0, 1_000_000
    )
    num_visual_words = _bounded_integer(
        options, "num_visual_words", 512, 2, 8192
    )
    max_features = _bounded_integer(
        options, "max_features_per_image", 512, 2, 8192
    )
    max_training = _bounded_integer(
        options, "max_training_descriptors", 65536, 512, 262144
    )
    num_iterations = _bounded_integer(options, "num_iterations", 10, 1, 100)
    num_rounds = _bounded_integer(options, "num_rounds", 1, 1, 3)
    num_checks = _bounded_integer(options, "num_checks", 64, 1, 1024)
    num_threads = _integer(options, "num_threads", -1)
    if num_threads == 0 or num_threads < -1 or num_threads > 64:
        raise ColmapCliError("--num_threads must be -1 or between 1 and 64")

    database_value = _required(options, "database_path")
    output_value = _required(options, "output_pair_list_path")
    required_api = (
        "Database",
        "Camera",
        "Image",
        "FeatureDescriptors",
        "FeatureExtractorType",
        "VisualIndex",
        "VocabTreePairingOptions",
        "VocabTreePairGenerator",
    )
    if any(not hasattr(pycolmap, name) for name in required_api):
        raise ColmapCliError(
            "PyCOLMAP VisualIndex and VocabTreePairGenerator APIs are required"
        )
    database_path = _regular_input_path(database_value, "database path")
    output_path = _safe_output_path(output_value)

    source_database = _readonly_feature_database(database_path)
    database: Any | None = None
    vocabulary_path: Path | None = None
    try:
        database = pycolmap.Database.open(":memory:")
        images, training = _populate_retrieval_database(
            pycolmap,
            source_database,
            database,
            max_features_per_image=max_features,
            max_training_descriptors=max_training,
        )
        query_ids = _query_image_ids(images, options.get("query_image_list_path"))
        names_to_ids = {str(image.name): int(image.image_id) for image in images}
        excluded_pairs: set[tuple[int, int]] = set()
        excluded_path = options.get("excluded_pair_list_path")
        if excluded_path is not None:
            path = _regular_input_path(excluded_path, "excluded pair list")
            for first_name, second_name in _read_pairs(str(path), allow_empty=True):
                first_id = names_to_ids.get(first_name)
                second_id = names_to_ids.get(second_name)
                if first_id is None or second_id is None:
                    raise ColmapCliError(
                        "excluded pair list contains an image absent from the database"
                    )
                excluded_pairs.add((min(first_id, second_id), max(first_id, second_id)))
        ordered_images = sorted(images, key=lambda value: str(value.name))
        order_by_id = {
            int(image.image_id): index for index, image in enumerate(ordered_images)
        }
        name_by_id = {
            int(image.image_id): str(image.name) for image in ordered_images
        }
        excluded_neighbors: dict[int, set[int]] = {}
        for first_id, second_id in excluded_pairs:
            excluded_neighbors.setdefault(first_id, set()).add(second_id)
            excluded_neighbors.setdefault(second_id, set()).add(first_id)
        maximum_filtered_count = 0
        for query_id in query_ids:
            query_order = order_by_id[query_id]
            filtered_ids = set(excluded_neighbors.get(query_id, ()))
            filtered_ids.add(query_id)
            if minimum_separation > 0:
                first_order = max(0, query_order - minimum_separation + 1)
                last_order = min(
                    len(ordered_images), query_order + minimum_separation
                )
                filtered_ids.update(
                    int(image.image_id)
                    for image in ordered_images[first_order:last_order]
                )
            maximum_filtered_count = max(
                maximum_filtered_count, len(filtered_ids)
            )
        effective_words = min(num_visual_words, int(training.shape[0]))
        float_descriptors = pycolmap.FeatureDescriptors(
            pycolmap.FeatureExtractorType.SIFT, training
        ).to_float()
        visual_index = pycolmap.VisualIndex.create(128, 64)
        build = pycolmap.VisualIndex.BuildOptions()
        build.num_visual_words = effective_words
        build.num_iterations = num_iterations
        build.num_rounds = num_rounds
        build.num_checks = min(num_checks, effective_words)
        build.num_threads = num_threads
        # The pinned COLMAP/FAISS build fixes clustering seed 1234. Stable image,
        # feature, and training-row order completes the determinism contract.
        visual_index.build(build, float_descriptors)

        vocabulary_descriptor, vocabulary_name = tempfile.mkstemp(
            prefix=f".{output_path.name}.vocab-",
            suffix=".bin",
            dir=output_path.parent,
        )
        os.close(vocabulary_descriptor)
        vocabulary_path = Path(vocabulary_name)
        visual_index.write(vocabulary_path)

        pairing = pycolmap.VocabTreePairingOptions()
        pairing.vocab_tree_path = vocabulary_path
        pairing.num_images = min(
            len(images), num_images + maximum_filtered_count
        )
        pairing.num_nearest_neighbors = 5
        pairing.num_checks = min(num_checks, effective_words)
        pairing.num_images_after_verification = 0
        pairing.max_num_features = max_features
        pairing.num_threads = num_threads
        generated = pycolmap.VocabTreePairGenerator(
            pairing, database, query_ids
        ).all_pairs()

        query_set = set(query_ids)
        ranked: dict[int, list[int]] = {query_id: [] for query_id in query_ids}
        for raw_first, raw_second in generated:
            first, second = int(raw_first), int(raw_second)
            if first in query_set:
                query_id, candidate_id = first, second
            elif second in query_set:
                query_id, candidate_id = second, first
            else:
                raise ColmapCliError("vocabulary retrieval returned an unknown query")
            if candidate_id not in name_by_id:
                raise ColmapCliError("vocabulary retrieval returned an unknown image")
            candidates = ranked[query_id]
            if candidate_id == query_id or candidate_id in candidates:
                continue
            if (
                abs(order_by_id[query_id] - order_by_id[candidate_id])
                < minimum_separation
            ):
                continue
            if (
                min(query_id, candidate_id),
                max(query_id, candidate_id),
            ) in excluded_pairs:
                continue
            if len(candidates) < returned_count:
                candidates.append(candidate_id)

        pair_lines: list[str] = []
        emitted_edges: set[tuple[int, int]] = set()
        for query_id in query_ids:
            for candidate_id in ranked[query_id]:
                edge = (min(query_id, candidate_id), max(query_id, candidate_id))
                if edge in emitted_edges:
                    continue
                emitted_edges.add(edge)
                pair_lines.append(
                    f"{name_by_id[query_id]} {name_by_id[candidate_id]}"
                )
        pair_lines.sort()
        _atomic_write_pair_lines(output_path, pair_lines)
        return f"Retrieved image pairs: {len(pair_lines)}"
    finally:
        if vocabulary_path is not None:
            vocabulary_path.unlink(missing_ok=True)
        source_database.close()
        if database is not None:
            database.close()


def _incremental_options(pycolmap: Any) -> Any:
    options = pycolmap.IncrementalPipelineOptions()
    options.ba_use_gpu = False
    return options


def _run_mapper(pycolmap: Any, options: dict[str, str]) -> None:
    pipeline = _incremental_options(pycolmap)
    pipeline.ba_global_frames_ratio = _refinement_ratio(
        options,
        "Mapper.ba_global_frames_ratio",
        pipeline.ba_global_frames_ratio,
    )
    pipeline.ba_global_points_ratio = _refinement_ratio(
        options,
        "Mapper.ba_global_points_ratio",
        pipeline.ba_global_points_ratio,
    )
    pipeline.ba_global_max_refinements = _positive_integer(
        options,
        "Mapper.ba_global_max_refinements",
        pipeline.ba_global_max_refinements,
    )
    pipeline.ba_global_max_num_iterations = _positive_integer(
        options,
        "Mapper.ba_global_max_num_iterations",
        pipeline.ba_global_max_num_iterations,
    )
    pipeline.random_seed = _nonnegative_int32(
        options,
        "Mapper.random_seed",
        42,
    )
    pipeline.ba_refine_focal_length = _boolean(
        options,
        "Mapper.ba_refine_focal_length",
        pipeline.ba_refine_focal_length,
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
    adjustment.ceres.use_gpu = False
    iteration_name = (
        "BundleAdjustmentCeres.max_num_iterations"
        if "BundleAdjustmentCeres.max_num_iterations" in options
        else "BundleAdjustment.max_num_iterations"
    )
    adjustment.ceres.solver_options.max_num_iterations = _positive_integer(
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
        copy_policy=pycolmap.FileCopyType.copy,
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
    elif command == "matches_importer":
        _run_matches_importer(pycolmap, options)
    elif command == "local_vocab_retriever":
        return _run_local_vocab_retriever(pycolmap, options)
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
    if arguments[0] == "--self-check":
        if len(arguments) != 1:
            print("ERROR: self-check does not accept arguments", file=sys.stderr)
            return 2
        try:
            print(json.dumps(_runtime_self_check(), sort_keys=True, separators=(",", ":")))
            return 0
        except ColmapCliError as exc:
            print(f"ERROR: runtime self-check failed: {exc}", file=sys.stderr)
            return 2
        except Exception as exc:
            print(f"ERROR: runtime self-check failed: {exc}", file=sys.stderr)
            return 1
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
