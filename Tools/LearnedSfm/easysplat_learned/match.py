import argparse
import json
import os
import sys
import time
from pathlib import Path
from typing import Dict, List, Tuple

import numpy as np
import torch
from PIL import Image

from easysplat_learned.colmap_db import write_database


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="EasySplat learned matcher")
    parser.add_argument("--images", required=True, help="Directory of images")
    parser.add_argument("--out-database", required=True, help="Output COLMAP database path")
    parser.add_argument("--out-features", help="Output directory for metadata (written on success)")
    parser.add_argument("--out-match-list", required=True, help="Output matches.txt path")
    parser.add_argument("--device", default="mps")
    parser.add_argument("--max-image-size", type=int, default=1600)
    parser.add_argument("--pairing", choices=["video", "photos"], default="video")
    parser.add_argument("--sequential-overlap", type=int, default=10)
    parser.add_argument("--stride", type=int, default=1)
    parser.add_argument("--loop-k", type=int, default=0)
    parser.add_argument("--pairs", help="Optional pairs list (image1 image2 per line)")
    parser.add_argument("--require-device", action="store_true")
    parser.add_argument("--offline", action="store_true")
    parser.add_argument("--models-dir", required=True)
    parser.add_argument("--camera-model", default="SIMPLE_RADIAL")
    parser.add_argument("--model-name", default="MASt3R_ViTLarge_BaseDecoder_512_catmlpdpt_metric")
    return parser.parse_args()


def log(line: str) -> None:
    sys.stdout.write(line + "\n")
    sys.stdout.flush()


def supported_images(directory: Path) -> List[Path]:
    exts = {".jpg", ".jpeg", ".png", ".tif", ".tiff", ".bmp"}
    files = [p for p in directory.iterdir() if p.is_file() and p.suffix.lower() in exts]
    return sorted(files, key=lambda p: p.name)


def ensure_device(requested: str, require_device: bool) -> str:
    if requested == "mps":
        built = torch.backends.mps.is_built()
        available = torch.backends.mps.is_available()
        if available:
            return "mps"
        log(f"MPS not available (is_built={built}, is_available={available}).")
        if require_device:
            raise SystemExit(3)
        log("Falling back to CPU.")
        return "cpu"
    return requested


def read_image_size(path: Path) -> Tuple[int, int]:
    with Image.open(path) as img:
        return img.size  # (width, height)


def build_pairs(images: List[str], pairing: str, overlap: int, stride: int, loop_k: int) -> List[Tuple[int, int]]:
    total = len(images)
    if total < 2:
        return []

    pairs = set()
    if pairing == "video":
        stride = max(1, stride)
        for i in range(0, total):
            for step in range(1, overlap + 1):
                j = i + step * stride
                if j < total:
                    pairs.add((i, j))
    else:
        k = max(1, loop_k)
        for i in range(total):
            for j in range(1, k + 1):
                if i + j < total:
                    pairs.add((i, i + j))

    return sorted(pairs)


def load_pairs_file(path: Path, image_names: List[str]) -> List[Tuple[int, int]]:
    name_to_index = {name: idx for idx, name in enumerate(image_names)}
    pairs = set()
    with path.open("r", encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            parts = line.split()
            if len(parts) < 2:
                continue
            a, b = parts[0], parts[1]
            if a not in name_to_index or b not in name_to_index:
                continue
            i, j = name_to_index[a], name_to_index[b]
            if i == j:
                continue
            if i > j:
                i, j = j, i
            pairs.add((i, j))
    return sorted(pairs)


def quantize_xy(x: float, y: float) -> Tuple[float, float]:
    return (round(x * 2.0) / 2.0, round(y * 2.0) / 2.0)


def main() -> int:
    args = parse_args()
    device = ensure_device(args.device, args.require_device)
    log(
        "Config: device="
        + device
        + f" max_image_size={args.max_image_size} pairing={args.pairing}"
        + f" overlap={args.sequential_overlap} stride={args.stride} loop_k={args.loop_k}"
    )

    images_dir = Path(args.images)
    images = supported_images(images_dir)
    if not images:
        log("No images found.")
        return 1

    image_names = [p.name for p in images]
    if args.pairs:
        try:
            pairs = load_pairs_file(Path(args.pairs), image_names)
            log(f"Loaded pairs from {args.pairs}")
        except Exception as exc:
            log(f"Failed to read pairs file: {exc}")
            return 1
    else:
        pairs = build_pairs(image_names, args.pairing, args.sequential_overlap, args.stride, args.loop_k)
    log(f"Image count: {len(image_names)} | Pair count: {len(pairs)}")

    # Defer MASt3R imports until now so we can adjust sys.path for dust3r.
    log("Importing MASt3R/DUSt3R...")
    try:
        from mast3r.model import AsymmetricMASt3R
        from mast3r.fast_nn import fast_reciprocal_NNs
        from dust3r.inference import inference
        from dust3r.utils.image import load_images
    except Exception as exc:  # noqa: BLE001
        log(f"Failed to import MASt3R/DUSt3R: {exc}")
        log("Rebuild the learned_sfm toolchain via ./scripts/dev_run.sh.")
        return 1

    models_dir = Path(args.models_dir)
    os.environ.setdefault("TORCH_HOME", str(models_dir))
    checkpoint_dir = models_dir / "checkpoints"
    model_path = checkpoint_dir / f"{args.model_name}.pth"
    if not model_path.exists():
        fallback = models_dir / f"{args.model_name}.pth"
        if fallback.exists():
            model_path = fallback
    if model_path.exists():
        log(f"Loading model weights from: {model_path}")
        t0 = time.perf_counter()
        model = AsymmetricMASt3R.from_pretrained(str(model_path))
        log(f"Loaded weights in {time.perf_counter() - t0:.1f}s")
    else:
        if args.offline:
            log("Model weights not found locally and offline mode is enabled.")
            return 1
        log(f"Loading model weights from hub: {args.model_name}")
        t0 = time.perf_counter()
        model = AsymmetricMASt3R.from_pretrained(args.model_name)
        log(f"Loaded weights in {time.perf_counter() - t0:.1f}s")

    log(f"Moving model to device: {device}")
    t0 = time.perf_counter()
    model = model.to(device)
    log(f"Model ready in {time.perf_counter() - t0:.1f}s")

    keypoints: Dict[str, List[Tuple[float, float]]] = {name: [] for name in image_names}
    keypoint_index: Dict[str, Dict[Tuple[float, float], int]] = {name: {} for name in image_names}
    matches: Dict[Tuple[str, str], List[Tuple[int, int]]] = {}

    for idx, (i, j) in enumerate(pairs):
        name1 = image_names[i]
        name2 = image_names[j]
        img1 = images_dir / name1
        img2 = images_dir / name2

        try:
            loaded = load_images([str(img1), str(img2)], size=args.max_image_size)
            with torch.no_grad():
                output = inference([tuple(loaded)], model, device, batch_size=1, verbose=False)
        except Exception as exc:
            log(f"Pair {name1} / {name2} failed: {exc}")
            continue

        view1, pred1 = output["view1"], output["pred1"]
        view2, pred2 = output["view2"], output["pred2"]
        desc1 = pred1["desc"].squeeze(0).detach()
        desc2 = pred2["desc"].squeeze(0).detach()

        matches_im0, matches_im1 = fast_reciprocal_NNs(
            desc1,
            desc2,
            subsample_or_initxy1=8,
            device=device,
            dist="dot",
            block_size=2**13,
        )

        if matches_im0.numel() == 0:
            continue

        true_shape1 = view1["true_shape"][0]
        true_shape2 = view2["true_shape"][0]
        valid = (
            (matches_im0[:, 0] >= 3.0)
            & (matches_im0[:, 0] < true_shape1[1] - 3.0)
            & (matches_im0[:, 1] >= 3.0)
            & (matches_im0[:, 1] < true_shape1[0] - 3.0)
            & (matches_im1[:, 0] >= 3.0)
            & (matches_im1[:, 0] < true_shape2[1] - 3.0)
            & (matches_im1[:, 1] >= 3.0)
            & (matches_im1[:, 1] < true_shape2[0] - 3.0)
        )

        matches_im0 = matches_im0[valid].cpu().numpy()
        matches_im1 = matches_im1[valid].cpu().numpy()
        if matches_im0.size == 0:
            continue

        match_pairs: List[Tuple[int, int]] = []
        for p0, p1 in zip(matches_im0, matches_im1):
            q0 = quantize_xy(float(p0[0]), float(p0[1]))
            q1 = quantize_xy(float(p1[0]), float(p1[1]))

            idx_map0 = keypoint_index[name1]
            idx_map1 = keypoint_index[name2]

            if q0 not in idx_map0:
                idx_map0[q0] = len(keypoints[name1])
                keypoints[name1].append(q0)
            if q1 not in idx_map1:
                idx_map1[q1] = len(keypoints[name2])
                keypoints[name2].append(q1)

            match_pairs.append((idx_map0[q0], idx_map1[q1]))

        if match_pairs:
            matches[(name1, name2)] = match_pairs

        if (idx + 1) % 10 == 0 or (idx + 1) == len(pairs):
            log(f"Processed {idx + 1}/{len(pairs)} pairs")

    log("Reading image sizes for COLMAP database...")
    t0 = time.perf_counter()
    image_sizes: Dict[str, Tuple[int, int]] = {p.name: read_image_size(p) for p in images}
    log(f"Read image sizes in {time.perf_counter() - t0:.1f}s")

    # Convert keypoints to numpy arrays
    keypoints_np: Dict[str, np.ndarray] = {}
    for name, pts in keypoints.items():
        if pts:
            keypoints_np[name] = np.array(pts, dtype=np.float32)
        else:
            keypoints_np[name] = np.empty((0, 2), dtype=np.float32)

    matches_np: Dict[Tuple[str, str], np.ndarray] = {}
    for pair, pts in matches.items():
        if pts:
            matches_np[pair] = np.array(pts, dtype=np.uint32)

    out_db = Path(args.out_database)
    out_db.parent.mkdir(parents=True, exist_ok=True)
    if out_db.exists():
        out_db.unlink()

    write_database(
        db_path=str(out_db),
        images=image_names,
        image_sizes=image_sizes,
        camera_model=args.camera_model,
        keypoints=keypoints_np,
        matches=matches_np,
    )

    out_match_list = Path(args.out_match_list)
    out_match_list.parent.mkdir(parents=True, exist_ok=True)
    with out_match_list.open("w", encoding="utf-8") as f:
        for (name1, name2), match_arr in matches_np.items():
            f.write(f"{name1} {name2}\n")
            for idx1, idx2 in match_arr:
                f.write(f"{idx1} {idx2}\n")
            f.write("\n")

    if args.out_features:
        out_features = Path(args.out_features)
        out_features.mkdir(parents=True, exist_ok=True)
        metadata = {
            "image_count": len(image_names),
            "pair_count": len(pairs),
            "device": device,
            "max_image_size": args.max_image_size,
            "pairing": args.pairing,
            "sequential_overlap": args.sequential_overlap,
            "stride": args.stride,
            "loop_k": args.loop_k,
            "camera_model": args.camera_model,
            "model_name": args.model_name,
            "weights_path": str(model_path) if model_path.exists() else None,
        }
        marker = out_features / "learned_matching_metadata.json"
        marker.write_text(json.dumps(metadata, indent=2, sort_keys=True) + "\n", encoding="utf-8")

    log("Learned matching complete.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
