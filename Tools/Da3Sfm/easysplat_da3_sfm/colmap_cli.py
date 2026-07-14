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
_PYCOLMAP_VERSION = "4.1.0"


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
