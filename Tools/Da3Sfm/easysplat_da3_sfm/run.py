from __future__ import annotations

import argparse
import json
import os
import shutil
import sys
import tempfile
from pathlib import Path
from typing import Any

import numpy as np
from PIL import Image

SUPPORTED_CAMERA_TYPES = ("SIMPLE_RADIAL", "SIMPLE_PINHOLE", "PINHOLE", "OPENCV")
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


def _camera_params(
    intrinsics: np.ndarray,
    size: tuple[int, int],
    camera_type: str,
    source_size: tuple[int, int] | None = None,
) -> list[float]:
    width, height = size
    source_width, source_height = source_size or size
    scale_x = width / max(1.0, float(source_width))
    scale_y = height / max(1.0, float(source_height))
    fx = float(intrinsics[0, 0]) * scale_x
    fy = float(intrinsics[1, 1]) * scale_y
    cx = (float(intrinsics[0, 2]) * scale_x) if intrinsics.shape[1] > 2 else width / 2.0
    cy = (float(intrinsics[1, 2]) * scale_y) if intrinsics.shape[1] > 2 else height / 2.0
    if camera_type == "PINHOLE":
        return [fx, fy, cx, cy]
    if camera_type == "SIMPLE_PINHOLE":
        return [(fx + fy) / 2.0, cx, cy]
    if camera_type == "SIMPLE_RADIAL":
        return [(fx + fy) / 2.0, cx, cy, 0.0]
    if camera_type == "OPENCV":
        return [fx, fy, cx, cy, 0.0, 0.0, 0.0, 0.0]
    raise ValueError(f"Unsupported camera type: {camera_type}")


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
) -> None:
    image_count = len(image_paths)
    size = max(2, min(args.window_size, image_count))
    overlap = max(0, min(args.window_overlap, size - 1))
    stride = max(1, size - overlap)
    windows: list[dict[str, Any]] = []
    start = 0
    while start < image_count:
        end = min(start + size, image_count)
        windows.append({"start": start, "end": end, "images": [p.name for p in image_paths[start:end]]})
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
) -> tuple[int, int | None, float | None, int | None]:
    if args.mode != "direct":
        raise RuntimeError(f"DA3 mode {args.mode!r} is not supported in this bridge")
    if len(image_paths) > max(2, args.window_size):
        raise RuntimeError(
            "DA3 native COLMAP export is only accepted for inputs that fit in one safe inference window; "
            "fall back to MapAnything or COLMAP for larger inputs"
        )

    from depth_anything_3.api import DepthAnything3

    try:
        model = DepthAnything3.from_pretrained(str(model_dir), local_files_only=True)
    except TypeError:
        model = DepthAnything3.from_pretrained(str(model_dir))
    if hasattr(model, "to"):
        model = model.to(selected_device)

    with tempfile.TemporaryDirectory(prefix="easysplat-da3-") as tmp:
        export_dir = Path(tmp) / "export"
        _call_da3_inference(args, model, image_paths, export_dir, selected_device)
        if _copy_colmap_export(export_dir, out_sparse):
            registered_count, point_count, observation_count, mean_track_length = _colmap_text_stats(out_sparse)
            return point_count, observation_count, mean_track_length, registered_count
    raise RuntimeError("DA3 did not produce a native COLMAP export")


def _call_da3_inference(
    args: argparse.Namespace,
    model: Any,
    image_paths: list[Path],
    export_dir: Path,
    selected_device: str,
) -> Any:
    kwargs = {
        "image": [str(path) for path in image_paths],
        "export_dir": str(export_dir),
        "export_format": "colmap",
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
    parser = argparse.ArgumentParser(description="Run Depth Anything 3 and export an EasySplat COLMAP text model.")
    parser.add_argument("--images", required=True, type=Path)
    parser.add_argument("--out-sparse", required=True, type=Path)
    parser.add_argument("--models-dir", type=Path, default=None)
    parser.add_argument("--device", default="mps")
    parser.add_argument("--mode", choices=("direct",), default="direct")
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


def main(argv: list[str] | None = None) -> int:
    args = build_arg_parser().parse_args(argv)
    models_dir = args.models_dir or _default_models_dir()
    if models_dir is None:
        raise SystemExit("DA3 models dir was not provided and no packaged models dir was found")
    models_dir = Path(models_dir)
    image_paths = _list_images(args.images)
    if len(image_paths) < 2:
        raise SystemExit("DA3 requires at least 2 supported images")
    if args.max_points < 1:
        raise SystemExit("--max-points must be >= 1")
    if args.window_size < 2:
        raise SystemExit("--window-size must be >= 2")
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

    try:
        point_count, observation_count, mean_track_length, registered_count = _run_da3_export(args, image_paths, primary_model, selected_device, args.out_sparse)
        model_subdir = args.model_subdir
    except Exception as exc:  # noqa: BLE001
        if not _is_memory_error(exc):
            raise
        print(f"DA3: {args.model_subdir} ran out of memory; retrying with {args.fallback_model_subdir}", file=sys.stderr)
        point_count, observation_count, mean_track_length, registered_count = _run_da3_export(args, image_paths, fallback_model, selected_device, args.out_sparse)
        model_subdir = args.fallback_model_subdir

    if args.manifest_out:
        _write_manifest(
            args.manifest_out,
            args=args,
            image_paths=image_paths,
            selected_device=selected_device,
            model_subdir=model_subdir,
            native_colmap_export=len(image_paths) <= max(2, args.window_size),
            registered_image_count=registered_count,
            raw_point_count=point_count,
            final_observation_count=observation_count,
            mean_track_length=mean_track_length,
        )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
