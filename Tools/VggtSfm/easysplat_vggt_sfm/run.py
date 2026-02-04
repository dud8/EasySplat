import argparse
import copy
import gc
import math
import os
import sys
from pathlib import Path

import numpy as np
import torch
import torch.nn.functional as F


def _supported_image_exts() -> set[str]:
    return {".jpg", ".jpeg", ".png"}


def _list_images(images_dir: Path) -> list[Path]:
    exts = _supported_image_exts()
    return sorted([p for p in images_dir.iterdir() if p.is_file() and p.suffix.lower() in exts])


def _select_device(requested: str) -> torch.device:
    req = requested.strip().lower()
    if req == "mps":
        if torch.backends.mps.is_available():
            return torch.device("mps")
        print("VGGT: requested device=mps but MPS is unavailable; falling back to cpu", file=sys.stderr)
        return torch.device("cpu")
    if req == "cuda":
        if torch.cuda.is_available():
            return torch.device("cuda")
        print("VGGT: requested device=cuda but CUDA is unavailable; falling back to cpu", file=sys.stderr)
        return torch.device("cpu")
    return torch.device(req)


def _torch_dtype_for_device(device: torch.device) -> torch.dtype:
    if device.type == "cuda":
        try:
            return torch.bfloat16 if torch.cuda.get_device_capability()[0] >= 8 else torch.float16
        except Exception:
            return torch.float16
    # MPS works best with float32 for stability. If you want to trade accuracy for speed/memory,
    # override in Swift by passing --device cpu/cuda, or via a future dtype flag.
    return torch.float32


def _rotmat_to_quat_wxyz(R: np.ndarray) -> np.ndarray:
    # Standard robust conversion. Returns (w, x, y, z).
    R = R.astype(np.float64)
    tr = float(R[0, 0] + R[1, 1] + R[2, 2])
    if tr > 0.0:
        S = np.sqrt(tr + 1.0) * 2.0
        w = 0.25 * S
        x = (R[2, 1] - R[1, 2]) / S
        y = (R[0, 2] - R[2, 0]) / S
        z = (R[1, 0] - R[0, 1]) / S
    elif R[0, 0] > R[1, 1] and R[0, 0] > R[2, 2]:
        S = np.sqrt(1.0 + R[0, 0] - R[1, 1] - R[2, 2]) * 2.0
        w = (R[2, 1] - R[1, 2]) / S
        x = 0.25 * S
        y = (R[0, 1] + R[1, 0]) / S
        z = (R[0, 2] + R[2, 0]) / S
    elif R[1, 1] > R[2, 2]:
        S = np.sqrt(1.0 + R[1, 1] - R[0, 0] - R[2, 2]) * 2.0
        w = (R[0, 2] - R[2, 0]) / S
        x = (R[0, 1] + R[1, 0]) / S
        y = 0.25 * S
        z = (R[1, 2] + R[2, 1]) / S
    else:
        S = np.sqrt(1.0 + R[2, 2] - R[0, 0] - R[1, 1]) * 2.0
        w = (R[1, 0] - R[0, 1]) / S
        x = (R[0, 2] + R[2, 0]) / S
        y = (R[1, 2] + R[2, 1]) / S
        z = 0.25 * S
    q = np.array([w, x, y, z], dtype=np.float64)
    n = np.linalg.norm(q)
    if n > 0:
        q /= n
    return q


def _write_colmap_text_model(
    out_dir: Path,
    image_paths: list[Path],
    extrinsics_w2c: np.ndarray,
    intrinsics_3x3: np.ndarray,
    original_sizes_wh: list[tuple[int, int]],
    vggt_resolution: int,
    points_xyz: np.ndarray,
    points_rgb: np.ndarray,
) -> None:
    out_dir.mkdir(parents=True, exist_ok=True)

    cameras_txt = out_dir / "cameras.txt"
    images_txt = out_dir / "images.txt"
    points_txt = out_dir / "points3D.txt"

    # Cameras: one camera per image (simple + robust).
    with cameras_txt.open("w", encoding="utf-8") as f:
        f.write("# Camera list with one line per camera:\n")
        f.write("#   CAMERA_ID, MODEL, WIDTH, HEIGHT, PARAMS[]\n")
        f.write(f"# Number of cameras: {len(image_paths)}\n")
        for i, (w, h) in enumerate(original_sizes_wh):
            cam_id = i + 1
            max_dim = max(w, h)
            resize_ratio = float(max_dim) / float(vggt_resolution)
            fx = float(intrinsics_3x3[i, 0, 0]) * resize_ratio
            fy = float(intrinsics_3x3[i, 1, 1]) * resize_ratio
            cx = float(w) / 2.0
            cy = float(h) / 2.0
            f.write(f"{cam_id} PINHOLE {w} {h} {fx} {fy} {cx} {cy}\n")

    # Images: write only image lines (points lines are optional and often omitted).
    with images_txt.open("w", encoding="utf-8") as f:
        f.write("# Image list with two lines per image:\n")
        f.write("#   IMAGE_ID, QW, QX, QY, QZ, TX, TY, TZ, CAMERA_ID, NAME\n")
        f.write("#   POINTS2D[] as (X, Y, POINT3D_ID)\n")
        f.write(f"# Number of images: {len(image_paths)}, mean observations per image: 0\n")
        for i, path in enumerate(image_paths):
            image_id = i + 1
            cam_id = i + 1
            R = extrinsics_w2c[i, :3, :3]
            t = extrinsics_w2c[i, :3, 3]
            q = _rotmat_to_quat_wxyz(R)
            f.write(
                f"{image_id} {q[0]} {q[1]} {q[2]} {q[3]} {t[0]} {t[1]} {t[2]} {cam_id} {path.name}\n"
            )

    # Points3D: write points with empty tracks.
    with points_txt.open("w", encoding="utf-8") as f:
        f.write("# 3D point list with one line per point:\n")
        f.write("#   POINT3D_ID, X, Y, Z, R, G, B, ERROR, TRACK[] as (IMAGE_ID, POINT2D_IDX)\n")
        f.write(f"# Number of points: {len(points_xyz)}, mean track length: 0\n")
        for idx, (xyz, rgb) in enumerate(zip(points_xyz, points_rgb), start=1):
            f.write(f"{idx} {xyz[0]} {xyz[1]} {xyz[2]} {int(rgb[0])} {int(rgb[1])} {int(rgb[2])} 1.0\n")


def _rename_colmap_recons_and_rescale_camera(
    reconstruction,
    image_paths: list[str],
    original_coords: np.ndarray,
    img_size: int,
    shift_point2d_to_original_res: bool,
    shared_camera: bool,
):
    rescale_camera = True
    resize_ratio = 1.0

    for pyimageid in reconstruction.images:
        pyimage = reconstruction.images[pyimageid]
        pycamera = reconstruction.cameras[pyimage.camera_id]
        pyimage.name = image_paths[pyimageid - 1]

        if rescale_camera:
            pred_params = copy.deepcopy(pycamera.params)

            real_image_size = original_coords[pyimageid - 1, -2:]
            resize_ratio = max(real_image_size) / img_size
            pred_params = pred_params * resize_ratio
            real_pp = real_image_size / 2
            pred_params[-2:] = real_pp

            pycamera.params = pred_params
            pycamera.width = real_image_size[0]
            pycamera.height = real_image_size[1]

        if shift_point2d_to_original_res:
            top_left = original_coords[pyimageid - 1, :2]
            for point2D in pyimage.points2D:
                point2D.xy = (point2D.xy - top_left) * resize_ratio

        if shared_camera:
            rescale_camera = False

    return reconstruction


def _load_images_square(
    image_paths: list[Path],
    target_size: int,
):
    from vggt.utils.load_fn import load_and_preprocess_images_square

    images_cpu, original_coords = load_and_preprocess_images_square(
        [str(p) for p in image_paths],
        target_size=int(target_size),
    )

    original_coords_np = original_coords.cpu().numpy()
    original_sizes_wh: list[tuple[int, int]] = []
    for row in original_coords_np:
        w = int(round(float(row[4])))
        h = int(round(float(row[5])))
        original_sizes_wh.append((w, h))

    return images_cpu, original_coords, original_sizes_wh


def _load_state_dict(path: Path, device: torch.device) -> dict:
    checkpoint = torch.load(path, map_location=device)
    if isinstance(checkpoint, dict):
        for key in ("state_dict", "model_state_dict", "model"):
            if key in checkpoint and isinstance(checkpoint[key], dict):
                return checkpoint[key]
    if not isinstance(checkpoint, dict):
        raise ValueError(f"Unexpected checkpoint type: {type(checkpoint)}")
    return checkpoint


def _camera_centers_from_extrinsics_w2c(extrinsics_w2c: np.ndarray) -> np.ndarray:
    # extrinsics_w2c: (S, 4, 4) or (S, 3, 4)
    R = extrinsics_w2c[:, :3, :3]
    t = extrinsics_w2c[:, :3, 3]
    # Camera center in world coordinates for OpenCV w2c extrinsics: C = -R^T t
    return -(R.transpose(0, 2, 1) @ t[:, :, None])[:, :, 0]


def _average_rotation(rotations: list[np.ndarray]) -> np.ndarray:
    if not rotations:
        return np.eye(3, dtype=np.float64)
    M = np.zeros((3, 3), dtype=np.float64)
    for R in rotations:
        M += R.astype(np.float64)
    U, _, Vt = np.linalg.svd(M)
    R = U @ Vt
    if np.linalg.det(R) < 0:
        U[:, -1] *= -1.0
        R = U @ Vt
    return R


def _estimate_similarity_from_overlap(
    chunk_extrinsics_w2c: np.ndarray,
    global_extrinsics_w2c: np.ndarray,
) -> tuple[float, np.ndarray, np.ndarray]:
    """
    Estimate similarity transform mapping chunk-world -> global-world using overlapping camera poses.

    Returns:
        (scale, R_align, t_align) such that:
            X_global = scale * (R_align @ X_chunk) + t_align
    """
    if chunk_extrinsics_w2c.shape[0] != global_extrinsics_w2c.shape[0]:
        raise ValueError("overlap pose count mismatch")

    m = int(chunk_extrinsics_w2c.shape[0])
    if m == 0:
        return 1.0, np.eye(3, dtype=np.float64), np.zeros(3, dtype=np.float64)

    # Use rotations for a stable estimate of world-frame alignment, since video camera centers
    # can be close to colinear (degenerate for pure Procrustes).
    R_chunk = chunk_extrinsics_w2c[:, :3, :3].astype(np.float64)
    R_global = global_extrinsics_w2c[:, :3, :3].astype(np.float64)
    R_candidates = [Rg.T @ Rc for (Rg, Rc) in zip(R_global, R_chunk)]
    R_align = _average_rotation(R_candidates)

    C_chunk = _camera_centers_from_extrinsics_w2c(chunk_extrinsics_w2c).astype(np.float64)
    C_global = _camera_centers_from_extrinsics_w2c(global_extrinsics_w2c).astype(np.float64)

    # Solve scale + translation after applying rotation.
    A = (R_align @ C_chunk.T).T
    mu_a = A.mean(axis=0)
    mu_b = C_global.mean(axis=0)
    A_c = A - mu_a
    B_c = C_global - mu_b
    denom = float(np.sum(A_c * A_c))
    if denom < 1e-12 or m < 2:
        scale = 1.0
    else:
        scale = float(np.sum(B_c * A_c) / denom)
        if not np.isfinite(scale) or scale <= 0:
            scale = 1.0
    t_align = mu_b - scale * mu_a
    return scale, R_align, t_align


def _transform_extrinsics_w2c(
    extrinsics_w2c: np.ndarray,
    scale: float,
    R_align: np.ndarray,
    t_align: np.ndarray,
) -> np.ndarray:
    centers = _camera_centers_from_extrinsics_w2c(extrinsics_w2c).astype(np.float64)
    centers_g = (scale * (R_align @ centers.T)).T + t_align[None, :]

    R_chunk = extrinsics_w2c[:, :3, :3].astype(np.float64)
    R_g = R_chunk @ R_align.T
    t_g = -(R_g @ centers_g[:, :, None])[:, :, 0]

    out = np.zeros((extrinsics_w2c.shape[0], 4, 4), dtype=np.float64)
    out[:, 3, 3] = 1.0
    out[:, :3, :3] = R_g
    out[:, :3, 3] = t_g
    return out


def _transform_points_xyz(
    points_xyz: np.ndarray,
    scale: float,
    R_align: np.ndarray,
    t_align: np.ndarray,
) -> np.ndarray:
    # points_xyz: (..., 3)
    pts = points_xyz.reshape(-1, 3).astype(np.float64)
    pts_g = (scale * (R_align @ pts.T)).T + t_align[None, :]
    return pts_g.reshape(points_xyz.shape)


def _maybe_empty_cache(device: torch.device) -> None:
    if device.type == "cuda":
        torch.cuda.empty_cache()
    elif device.type == "mps" and hasattr(torch, "mps") and hasattr(torch.mps, "empty_cache"):
        torch.mps.empty_cache()


def _run_vggt_chunk(
    *,
    model,
    image_paths: list[Path],
    img_load_resolution: int,
    vggt_resolution: int,
    device: torch.device,
    dtype: torch.dtype,
) -> tuple[np.ndarray, np.ndarray, np.ndarray, np.ndarray, np.ndarray, list[tuple[int, int]]]:
    """
    Runs VGGT on a chunk of images.

    Returns:
        extrinsic_w2c (S, 4, 4)
        intrinsic_3x3 (S, 3, 3)
        depth_map (S, H, W, 1)
        depth_conf (S, H, W)
        rgb_u8 (S, H, W, 3) at vggt_resolution
        original_sizes_wh (list[(W,H)])
    """
    from vggt.utils.load_fn import load_and_preprocess_images_square
    from vggt.utils.pose_enc import pose_encoding_to_extri_intri

    images_cpu, original_coords = load_and_preprocess_images_square(
        [str(p) for p in image_paths],
        target_size=int(img_load_resolution),
    )

    # Extract original sizes (W, H) from the preprocess metadata.
    original_coords_np = original_coords.cpu().numpy()
    original_sizes_wh: list[tuple[int, int]] = []
    for row in original_coords_np:
        w = int(round(float(row[4])))
        h = int(round(float(row[5])))
        original_sizes_wh.append((w, h))

    images_dev = images_cpu.to(device)

    # Resize to VGGT fixed resolution (square).
    vggt_res = int(vggt_resolution)
    images_resized = F.interpolate(images_dev, size=(vggt_res, vggt_res), mode="bilinear", align_corners=False)

    with torch.no_grad():
        if device.type == "cuda":
            with torch.cuda.amp.autocast(dtype=dtype, enabled=True):
                images_batched = images_resized[None]
                aggregated_tokens_list, ps_idx = model.aggregator(images_batched)
        else:
            images_batched = images_resized[None]
            aggregated_tokens_list, ps_idx = model.aggregator(images_batched)

        pose_enc = model.camera_head(aggregated_tokens_list)[-1]
        extrinsic, intrinsic = pose_encoding_to_extri_intri(pose_enc, images_resized.shape[-2:])
        depth_map, depth_conf = model.depth_head(aggregated_tokens_list, images_batched, ps_idx)

    # Move predictions to CPU before freeing GPU memory.
    extrinsic_np = extrinsic.squeeze(0).cpu().numpy()
    intrinsic_np = intrinsic.squeeze(0).cpu().numpy()
    depth_map_np = depth_map.squeeze(0).cpu().numpy()
    depth_conf_np = depth_conf.squeeze(0).cpu().numpy()

    # RGB at the same resolution as the depth maps / point maps.
    rgb = F.interpolate(images_cpu, size=(vggt_res, vggt_res), mode="bilinear", align_corners=False)
    rgb = (rgb.detach().cpu().numpy() * 255.0).astype(np.uint8).transpose(0, 2, 3, 1)

    # Free big tensors promptly; chunked processing can otherwise accumulate MPS allocations.
    del images_batched, images_resized, images_dev
    del aggregated_tokens_list, ps_idx, pose_enc, extrinsic, intrinsic, depth_map, depth_conf
    gc.collect()
    _maybe_empty_cache(device)

    return extrinsic_np, intrinsic_np, depth_map_np, depth_conf_np, rgb, original_sizes_wh


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="EasySplat VGGT -> COLMAP sparse model bridge")
    parser.add_argument("--images", required=True, help="Directory containing input images (selected frames).")
    parser.add_argument("--out-sparse", required=True, help="Output directory for COLMAP sparse model (cameras/images/points3D).")
    parser.add_argument("--models-dir", required=True, help="Directory containing vggt_model.pt.")
    parser.add_argument("--device", default=os.environ.get("EASYSPLAT_VGGT_DEVICE", "mps"))
    parser.add_argument("--img-load-resolution", type=int, default=1024)
    parser.add_argument("--vggt-resolution", type=int, default=518)
    parser.add_argument("--conf-thres", type=float, default=5.0)
    parser.add_argument("--max-points", type=int, default=100_000)
    parser.add_argument("--seed", type=int, default=42)
    # Chunking is required on MPS for longer sequences. Smaller chunks are often faster overall
    # because VGGT's global attention scales superlinearly with the number of views.
    parser.add_argument("--chunk-size", type=int, default=int(os.environ.get("EASYSPLAT_VGGT_CHUNK_SIZE", "6")))
    parser.add_argument("--chunk-overlap", type=int, default=int(os.environ.get("EASYSPLAT_VGGT_CHUNK_OVERLAP", "2")))
    parser.add_argument("--use-ba", action="store_true", default=False, help="Enable bundle adjustment refinement.")
    parser.add_argument("--max-reproj-error", type=float, default=8.0)
    parser.add_argument("--shared-camera", action="store_true", default=False)
    parser.add_argument("--camera-type", type=str, default="SIMPLE_PINHOLE")
    parser.add_argument("--vis-thresh", type=float, default=0.2)
    parser.add_argument("--query-frame-num", type=int, default=8)
    parser.add_argument("--max-query-pts", type=int, default=4096)
    parser.add_argument("--keypoint-extractor", type=str, default="aliked+sp")
    parser.add_argument("--fine-tracking", dest="fine_tracking", action="store_true", default=True)
    parser.add_argument("--no-fine-tracking", dest="fine_tracking", action="store_false")
    parser.add_argument("--ba-max-frames", type=int, default=0)
    args = parser.parse_args(argv)

    images_dir = Path(args.images)
    out_sparse = Path(args.out_sparse)
    models_dir = Path(args.models_dir)
    model_path = models_dir / "vggt_model.pt"

    if not images_dir.exists():
        print(f"VGGT: images dir not found: {images_dir}", file=sys.stderr)
        return 2
    if not model_path.exists():
        print(f"VGGT: model weights not found: {model_path}", file=sys.stderr)
        return 2

    image_paths = _list_images(images_dir)
    if not image_paths:
        print(f"VGGT: no supported images found in {images_dir}", file=sys.stderr)
        return 2

    np.random.seed(args.seed)
    torch.manual_seed(args.seed)

    device = _select_device(args.device)
    dtype = _torch_dtype_for_device(device)

    print(f"VGGT: device={device}, dtype={dtype}")
    print(f"VGGT: images={len(image_paths)}")

    # Imports are intentionally late so we can produce a clean error if the vendor tree is missing.
    try:
        from vggt.models.vggt import VGGT
        from vggt.utils.geometry import unproject_depth_map_to_point_map
        from vggt.utils.helper import randomly_limit_trues
    except Exception as e:
        print(f"VGGT: import failed: {e}", file=sys.stderr)
        return 3

    print("VGGT: loading model weights...")
    model = VGGT()
    state = _load_state_dict(model_path, device)
    model.load_state_dict(state)
    model.eval()
    model = model.to(device)

    if args.use_ba:
        max_ba_frames = int(args.ba_max_frames or 0)
        if max_ba_frames <= 0 and device.type == "mps":
            max_ba_frames = 32
        if max_ba_frames > 0 and len(image_paths) > max_ba_frames:
            print(
                "VGGT: BA disabled for long sequences; falling back to feed-forward.",
                file=sys.stderr
            )
        else:
            ba_failed = False
            try:
                import pycolmap  # noqa: F401
                from vggt.dependency.track_predict import predict_tracks
                from vggt.dependency.np_to_pycolmap import batch_np_matrix_to_pycolmap
                from vggt.utils.geometry import unproject_depth_map_to_point_map
            except Exception as e:
                print(f"VGGT: BA dependencies unavailable: {e}", file=sys.stderr)
                ba_failed = True

            if not ba_failed:
                print("VGGT: BA enabled (tracking + bundle adjustment).")
                images_cpu, original_coords, _ = _load_images_square(image_paths, int(args.img_load_resolution))
                images = images_cpu.to(device)

                vggt_res = int(args.vggt_resolution)
                images_resized = F.interpolate(images, size=(vggt_res, vggt_res), mode="bilinear", align_corners=False)

                with torch.no_grad():
                    if device.type == "cuda":
                        with torch.cuda.amp.autocast(dtype=dtype, enabled=True):
                            images_batched = images_resized[None]
                            aggregated_tokens_list, ps_idx = model.aggregator(images_batched)
                    else:
                        images_batched = images_resized[None]
                        aggregated_tokens_list, ps_idx = model.aggregator(images_batched)

                    pose_enc = model.camera_head(aggregated_tokens_list)[-1]
                    from vggt.utils.pose_enc import pose_encoding_to_extri_intri
                    extrinsic, intrinsic = pose_encoding_to_extri_intri(pose_enc, images_resized.shape[-2:])
                    depth_map, depth_conf = model.depth_head(aggregated_tokens_list, images_batched, ps_idx)

                extrinsic_np = extrinsic.squeeze(0).cpu().numpy()
                intrinsic_np = intrinsic.squeeze(0).cpu().numpy()

                points_3d = unproject_depth_map_to_point_map(depth_map, extrinsic, intrinsic)

                image_size = np.array(images.shape[-2:])
                scale = float(args.img_load_resolution) / float(vggt_res)

                # Predict tracks and build reconstruction with BA.
                pred_tracks, pred_vis_scores, pred_confs, points_3d, points_rgb = predict_tracks(
                    images,
                    conf=depth_conf,
                    points_3d=points_3d,
                    masks=None,
                    max_query_pts=int(args.max_query_pts),
                    query_frame_num=int(args.query_frame_num),
                    keypoint_extractor=str(args.keypoint_extractor),
                    fine_tracking=bool(args.fine_tracking),
                )
                _maybe_empty_cache(device)

                intrinsic_np[:, :2, :] *= scale
                track_mask = pred_vis_scores > float(args.vis_thresh)

                reconstruction, valid_track_mask = batch_np_matrix_to_pycolmap(
                    points_3d,
                    extrinsic_np,
                    intrinsic_np,
                    pred_tracks,
                    image_size,
                    masks=track_mask,
                    max_reproj_error=float(args.max_reproj_error),
                    shared_camera=bool(args.shared_camera),
                    camera_type=str(args.camera_type),
                    points_rgb=points_rgb,
                )

                if reconstruction is None:
                    print("VGGT: BA reconstruction failed; falling back to feed-forward.", file=sys.stderr)
                    ba_failed = True

            if not ba_failed:
                ba_options = pycolmap.BundleAdjustmentOptions()
                pycolmap.bundle_adjustment(reconstruction, ba_options)

                reconstruction = _rename_colmap_recons_and_rescale_camera(
                    reconstruction,
                    [p.name for p in image_paths],
                    original_coords.cpu().numpy(),
                    img_size=int(args.img_load_resolution),
                    shift_point2d_to_original_res=True,
                    shared_camera=bool(args.shared_camera),
                )

                out_sparse.mkdir(parents=True, exist_ok=True)
                if hasattr(reconstruction, "write_text"):
                    reconstruction.write_text(str(out_sparse))
                else:
                    reconstruction.write(str(out_sparse))

                images_txt = out_sparse / "images.txt"
                if not images_txt.exists():
                    print("VGGT: expected images.txt missing after BA write; falling back to feed-forward.", file=sys.stderr)
                    ba_failed = True

            if not ba_failed:
                print("VGGT: done")
                return 0
            print("VGGT: BA failed; continuing with feed-forward.", file=sys.stderr)

    # Chunked VGGT inference
    total_images = len(image_paths)
    requested_chunk = max(2, int(args.chunk_size))
    requested_overlap = max(0, int(args.chunk_overlap))

    # On MPS, extremely long global-attention sequences can crash the process (or hit Metal buffer limits).
    # Keep per-chunk sequence length conservative: S * (1 + reg + patches).
    if device.type == "mps":
        patch_size = 14  # VGGT-1B defaults; the published checkpoint assumes 518px with 14px patches.
        grid = max(1, int(round(float(args.vggt_resolution) / float(patch_size))))
        tokens_per_image = 1 + 4 + (grid * grid)
        max_global_tokens = 18_000  # below the ~28GiB buffer limit observed on MPS SDPA
        safe_max = max(2, max_global_tokens // tokens_per_image)
        requested_chunk = min(requested_chunk, safe_max)

    chunk_size = min(requested_chunk, total_images)
    overlap = min(requested_overlap, max(0, chunk_size - 1))
    stride = max(1, chunk_size - overlap)

    # If everything fits in one chunk, don't run an overlapping sliding window.
    if total_images <= chunk_size:
        overlap = 0
        stride = chunk_size

    if total_images > chunk_size:
        print(f"VGGT: chunking enabled (chunk={chunk_size}, overlap={overlap}, stride={stride}).")

    global_extrinsics: list[np.ndarray | None] = [None] * total_images
    global_intrinsics: list[np.ndarray | None] = [None] * total_images
    global_sizes: list[tuple[int, int] | None] = [None] * total_images

    points_xyz_accum: list[np.ndarray] = []
    points_rgb_accum: list[np.ndarray] = []

    # Budget points per chunk to avoid large intermediate arrays.
    est_chunks = max(1, int(math.ceil((total_images - chunk_size) / float(stride))) + 1)
    per_chunk_budget = max(1, int(args.max_points) // est_chunks)

    start = 0
    chunk_idx = 0
    while start < total_images:
        end = min(start + chunk_size, total_images)
        chunk_paths = image_paths[start:end]
        print(f"VGGT: chunk {chunk_idx + 1}/{est_chunks} images[{start}:{end}]")

        try:
            extr_c, intr_c, depth_c, conf_c, rgb_c, sizes_c = _run_vggt_chunk(
                model=model,
                image_paths=chunk_paths,
                img_load_resolution=int(args.img_load_resolution),
                vggt_resolution=int(args.vggt_resolution),
                device=device,
                dtype=dtype,
            )
        except RuntimeError as e:
            # Opportunistic adaptation: if we hit an MPS buffer-size issue, reduce chunk size and retry.
            msg = str(e)
            if "Invalid buffer size" in msg and chunk_size > 2:
                chunk_size = max(2, chunk_size - 2)
                overlap = min(overlap, max(0, chunk_size - 1))
                stride = max(1, chunk_size - overlap)
                est_chunks = max(1, int(math.ceil((total_images - chunk_size) / float(stride))) + 1)
                per_chunk_budget = max(1, int(args.max_points) // est_chunks)
                print(f"VGGT: reducing chunk size to {chunk_size} due to MPS buffer limits; retrying.", file=sys.stderr)
                _maybe_empty_cache(device)
                continue
            raise

        if start == 0:
            scale = 1.0
            R_align = np.eye(3, dtype=np.float64)
            t_align = np.zeros(3, dtype=np.float64)
        else:
            # Align this chunk's coordinate frame to the global frame using the overlap.
            overlap_start = start
            overlap_end = min(end, start + overlap)
            overlap_indices = [i for i in range(overlap_start, overlap_end) if global_extrinsics[i] is not None]
            if len(overlap_indices) < 1:
                # Fallback: try to align with the immediately previous image, if possible.
                fallback = start - 1
                overlap_indices = [fallback] if fallback >= 0 and global_extrinsics[fallback] is not None else []

            if not overlap_indices:
                # Last resort: keep chunk in its own frame (will likely produce a broken model, but avoids crashing).
                print("VGGT: warning: no overlap poses available for alignment; continuing without alignment.", file=sys.stderr)
                scale = 1.0
                R_align = np.eye(3, dtype=np.float64)
                t_align = np.zeros(3, dtype=np.float64)
            else:
                local = [i - start for i in overlap_indices]
                chunk_overlap = extr_c[local]
                global_overlap = np.stack([global_extrinsics[i] for i in overlap_indices], axis=0)
                scale, R_align, t_align = _estimate_similarity_from_overlap(chunk_overlap, global_overlap)

        extr_g = _transform_extrinsics_w2c(extr_c, scale, R_align, t_align)

        # Persist per-image outputs (first write wins to avoid drift on overlaps).
        for local_idx, global_idx in enumerate(range(start, end)):
            if global_extrinsics[global_idx] is None:
                global_extrinsics[global_idx] = extr_g[local_idx]
            if global_intrinsics[global_idx] is None:
                global_intrinsics[global_idx] = intr_c[local_idx]
            if global_sizes[global_idx] is None:
                global_sizes[global_idx] = sizes_c[local_idx]

        # Generate points for this chunk and merge into global.
        points_3d = unproject_depth_map_to_point_map(depth_c, extr_c, intr_c)
        points_3d = _transform_points_xyz(points_3d, scale, R_align, t_align)

        conf_mask = conf_c >= float(args.conf_thres)
        conf_mask = randomly_limit_trues(conf_mask, int(per_chunk_budget))

        filtered_xyz = points_3d[conf_mask]
        filtered_rgb = rgb_c[conf_mask]
        finite = np.isfinite(filtered_xyz).all(axis=1)
        filtered_xyz = filtered_xyz[finite].astype(np.float32)
        filtered_rgb = filtered_rgb[finite].astype(np.uint8)

        if filtered_xyz.shape[0] > 0:
            points_xyz_accum.append(filtered_xyz)
            points_rgb_accum.append(filtered_rgb)

        if end == total_images:
            break
        start += stride
        chunk_idx += 1

    if any(v is None for v in global_extrinsics) or any(v is None for v in global_intrinsics) or any(v is None for v in global_sizes):
        print("VGGT: internal error: failed to compute poses for all images.", file=sys.stderr)
        return 4

    extrinsic_all = np.stack([v for v in global_extrinsics if v is not None], axis=0)
    intrinsic_all = np.stack([v for v in global_intrinsics if v is not None], axis=0)
    original_sizes_wh = [v for v in global_sizes if v is not None]

    if points_xyz_accum:
        points_xyz = np.concatenate(points_xyz_accum, axis=0)
        points_rgb = np.concatenate(points_rgb_accum, axis=0)
    else:
        points_xyz = np.zeros((0, 3), dtype=np.float32)
        points_rgb = np.zeros((0, 3), dtype=np.uint8)

    if points_xyz.shape[0] == 0:
        print("VGGT: produced 0 valid points after filtering; cannot write COLMAP model.", file=sys.stderr)
        return 4

    # Final cap (in case per-chunk budgets overshoot due to low est_chunks for short sequences).
    if points_xyz.shape[0] > int(args.max_points):
        idx = np.random.choice(points_xyz.shape[0], size=int(args.max_points), replace=False)
        points_xyz = points_xyz[idx]
        points_rgb = points_rgb[idx]

    vggt_res = int(args.vggt_resolution)
    print(f"VGGT: writing COLMAP model to {out_sparse} (points={points_xyz.shape[0]})")
    _write_colmap_text_model(
        out_dir=out_sparse,
        image_paths=image_paths,
        extrinsics_w2c=extrinsic_all,
        intrinsics_3x3=intrinsic_all,
        original_sizes_wh=original_sizes_wh,
        vggt_resolution=vggt_res,
        points_xyz=points_xyz,
        points_rgb=points_rgb,
    )

    print("VGGT: done")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
