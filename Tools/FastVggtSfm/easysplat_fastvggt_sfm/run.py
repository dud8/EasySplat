import argparse
import math
import os
import time
from pathlib import Path

import numpy as np
import torch
import torch.nn.functional as F
from PIL import Image

# Ensure project root is in sys.path for absolute imports like `vggt.*`
ROOT_DIR = os.path.abspath(os.path.join(os.path.dirname(__file__), os.pardir))
if ROOT_DIR not in os.sys.path:
    os.sys.path.insert(0, ROOT_DIR)

from vggt.models.vggt import VGGT
from vggt.utils.device import maybe_autocast, resolve_device, resolve_dtype, sync_device, warn_if_mps_fallback_disabled
from vggt.utils.geometry import unproject_depth_map_to_point_map
from vggt.utils.helper import create_pixel_coordinate_grid, randomly_limit_trues
from vggt.utils.pose_enc import pose_encoding_to_extri_intri


def _supported_image_exts() -> tuple[str, ...]:
    return (".jpg", ".jpeg", ".png")


def _list_images(images_dir: Path) -> list[Path]:
    exts = _supported_image_exts()
    image_paths: list[Path] = []
    for ext in exts:
        image_paths.extend(sorted(images_dir.glob(f"*{ext}")))
    return image_paths


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


def _load_images_rgb(image_paths: list[Path]) -> list[np.ndarray]:
    images: list[np.ndarray] = []
    for image_path in image_paths:
        try:
            img = Image.open(image_path).convert("RGB")
        except Exception:
            continue
        images.append(np.array(img))
    return images


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
        max_dim = max(width, height)

        left = (max_dim - width) // 2
        top = (max_dim - height) // 2

        scale = float(target_width) / float(max_dim)

        x1 = left * scale
        y1 = top * scale
        x2 = (left + width) * scale
        y2 = (top + height) * scale

        original_coords.append(np.array([x1, y1, x2, y2, width, height], dtype=np.float32))

    original_coords = torch.from_numpy(np.stack(original_coords, axis=0)).float()
    return original_coords


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

    resize_ratios = []
    top_lefts = []
    for fidx in range(num_frames):
        real_image_size = original_coords[fidx, -2:]
        resize_ratio = float(max(real_image_size) / img_size)
        resize_ratios.append(resize_ratio)
        top_lefts.append(original_coords[fidx, :2])

    for point_idx in range(len(points3d)):
        fidx = int(points_xyf[point_idx, 2])
        if fidx < 0 or fidx >= num_frames:
            continue
        xy = points_xyf[point_idx, :2]
        xy = (xy - top_lefts[fidx]) * resize_ratios[fidx]
        point_id = point_idx + 1
        point2d_idx = len(image_points2d[fidx])
        image_points2d[fidx].append((xy, point_id))
        point_tracks[point_idx].append((fidx + 1, point2d_idx))

    cameras = []
    for fidx in range(num_frames):
        colmap_intri = _build_colmap_intri(fidx, intrinsics, camera_type)
        real_image_size = original_coords[fidx, -2:]
        resize_ratio = resize_ratios[fidx]
        colmap_intri = colmap_intri * resize_ratio
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
    return parser.parse_args()


def main():
    args = parse_args()

    device = resolve_device(args.device)
    dtype = resolve_dtype(device, args.dtype)
    warn_if_mps_fallback_disabled(device)

    vggt_resolution = int(args.vggt_resolution)
    if vggt_resolution % 14 != 0:
        adjusted = max(14, (vggt_resolution // 14) * 14)
        if adjusted != vggt_resolution:
            print(
                "FASTVGGT: vggt-resolution must be multiple of 14; "
                f"using {adjusted} instead of {vggt_resolution}"
            )
            vggt_resolution = adjusted

    images_dir = Path(args.images)
    if not images_dir.exists():
        print(f"FASTVGGT: images dir not found: {images_dir}", file=os.sys.stderr)
        return 1

    image_paths = _list_images(images_dir)
    if len(image_paths) == 0:
        print(f"FASTVGGT: no supported images found in {images_dir}", file=os.sys.stderr)
        return 1

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

    images = _load_images_rgb(image_paths)
    if not images or len(images) < 3:
        print("FASTVGGT: not enough valid images", file=os.sys.stderr)
        return 1
    image_stack = np.stack(images)

    vgg_input, patch_width, patch_height = _get_vgg_input_imgs(image_stack, target_width=vggt_resolution)
    model.update_patch_dimensions(patch_width, patch_height)
    original_coords = _compute_original_coords(image_paths, target_width=vggt_resolution)

    print("FASTVGGT: running FastVGGT inference...")
    sync_device(device)
    start = time.time()
    with torch.no_grad():
        with maybe_autocast(device, dtype):
            vgg_input_device = vgg_input.to(device=device, dtype=dtype)
            predictions = model(vgg_input_device, image_paths=[p.name for p in image_paths])
    sync_device(device)
    elapsed_ms = (time.time() - start) * 1000.0
    print(f"FASTVGGT: inference done in {elapsed_ms:.1f} ms for {len(image_paths)} images")

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
        image_paths,
        original_coords.detach().cpu().numpy(),
        img_size=int(grid_w),
        shared_camera=bool(args.shared_camera),
        camera_type=camera_type,
    )

    print("FASTVGGT: export seed model ready")
    print("FASTVGGT: done")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
