#!/usr/bin/env python3
"""Stage a sparse-view COLMAP dataset, matching the nerfbaselines protocol.

The Mip-NeRF 360 Sparse benchmark trains on 12 or 24 views and evaluates on the
dataset's ordinary test set. Its selection rule, from nerfbaselines' own
`mipnerf360_sparse.py`, is two steps:

    train, test = every 8th filename-sorted image held out for test
    sparse_train = train[np.linspace(0, len(train) - 1, num_views, dtype=int)]

The test set is untouched, so a sparse result is directly comparable to a dense one
on the same held-out views.

EasySplat's trainer derives its split from the COLMAP model it is given, so a sparse
run needs a model containing only the chosen training images -- filtering the image
directory alone would leave the trainer with camera records whose files are missing.
This writes a new dataset directory with a filtered `images.bin`, the original
`cameras.bin` and `points3D.bin`, and symlinks for the images it kept.

The trainer must then be run with holdout disabled (`--holdout-every 1`), because the
held-out views are deliberately absent from the staged model. Render and score the
standard test cameras from the *original* dataset: the exported PLY is written back
through the scene normalisation into original world coordinates, so it lines up with
the full reconstruction's poses regardless of which cameras trained it.
"""

from __future__ import annotations

import argparse
import pathlib
import shutil
import struct
import sys


class ColmapImage:
    __slots__ = ("image_id", "quat", "translation", "camera_id", "name", "points2d")

    def __init__(self, image_id, quat, translation, camera_id, name, points2d):
        self.image_id = image_id
        self.quat = quat
        self.translation = translation
        self.camera_id = camera_id
        self.name = name
        self.points2d = points2d


def read_images_bin(path: pathlib.Path) -> list[ColmapImage]:
    data = path.read_bytes()
    offset = 0

    def take(fmt: str):
        nonlocal offset
        size = struct.calcsize(fmt)
        values = struct.unpack_from(fmt, data, offset)
        offset += size
        return values

    (count,) = take("<Q")
    images = []
    for _ in range(count):
        image_id, qw, qx, qy, qz, tx, ty, tz, camera_id = take("<idddddddi")
        name = bytearray()
        while data[offset] != 0:
            name.append(data[offset])
            offset += 1
        offset += 1
        (num_points,) = take("<Q")
        # Kept verbatim rather than parsed: the trainer does not read 2D
        # correspondences, but COLMAP's format requires them to be present and
        # well formed for anything else that might open the model.
        span = num_points * struct.calcsize("<ddq")
        points2d = data[offset : offset + span]
        offset += span
        images.append(
            ColmapImage(
                image_id,
                (qw, qx, qy, qz),
                (tx, ty, tz),
                camera_id,
                name.decode("utf-8"),
                (num_points, points2d),
            )
        )
    return images


def write_images_bin(path: pathlib.Path, images: list[ColmapImage]) -> None:
    out = bytearray()
    out += struct.pack("<Q", len(images))
    for image in images:
        out += struct.pack(
            "<idddddddi",
            image.image_id,
            *image.quat,
            *image.translation,
            image.camera_id,
        )
        out += image.name.encode("utf-8") + b"\0"
        count, blob = image.points2d
        out += struct.pack("<Q", count)
        out += blob
    path.write_bytes(bytes(out))


def sparse_train_names(names: list[str], num_views: int, holdout_every: int = 8):
    """The nerfbaselines selection, as names rather than indices.

    Returns (sparse_train, test). `names` is sorted here rather than assumed sorted,
    because the trainer sorts by filename before splitting and a caller that passed
    COLMAP's own order would otherwise select a different set.
    """
    ordered = sorted(names)
    train = [n for i, n in enumerate(ordered) if i % holdout_every != 0]
    test = [n for i, n in enumerate(ordered) if i % holdout_every == 0]
    if num_views >= len(train):
        return train, test
    if num_views == 1:
        return [train[0]], test
    # linspace(0, len(train) - 1, num_views) rounded toward zero, matching numpy's
    # dtype=int cast rather than rounding to nearest.
    step = (len(train) - 1) / (num_views - 1)
    chosen = sorted({int(round(i * step)) for i in range(num_views)})
    return [train[i] for i in chosen], test


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--dataset", required=True, help="source dataset directory")
    parser.add_argument("--output", required=True, help="staged sparse dataset directory")
    parser.add_argument("--views", type=int, required=True, help="12 or 24")
    parser.add_argument("--holdout-every", type=int, default=8)
    arguments = parser.parse_args()

    source = pathlib.Path(arguments.dataset)
    target = pathlib.Path(arguments.output)
    sparse_in = source / "sparse" / "0"
    if not (sparse_in / "images.bin").is_file():
        sys.exit(f"no COLMAP model at {sparse_in}")

    images = read_images_bin(sparse_in / "images.bin")
    train, test = sparse_train_names(
        [image.name for image in images], arguments.views, arguments.holdout_every
    )
    keep = set(train)
    kept = [image for image in images if image.name in keep]
    if len(kept) != len(keep):
        sys.exit(f"model is missing {len(keep) - len(kept)} selected images")

    sparse_out = target / "sparse" / "0"
    sparse_out.mkdir(parents=True, exist_ok=True)
    write_images_bin(sparse_out / "images.bin", kept)
    # Everything else in the model directory is copied rather than an allow-list of
    # cameras.bin and points3D.bin. EasySplat writes an orientation overlay beside the
    # COLMAP files and refuses to start without it, and an allow-list silently drops
    # any such sidecar a future version adds.
    for entry in sorted(sparse_in.iterdir()):
        if entry.name == "images.bin" or not entry.is_file():
            continue
        shutil.copy2(entry, sparse_out / entry.name)

    images_dir = target / "images"
    if images_dir.is_symlink() or images_dir.is_file():
        images_dir.unlink()
    elif images_dir.is_dir():
        shutil.rmtree(images_dir)
    images_dir.mkdir(parents=True)
    resolved = (source / "images").resolve()
    # Copied, not linked. The trainer validates that every input is an ordinary
    # single-link file and rejects both symlinks and hardlinks, which is the right
    # posture for something that reads untrusted paths -- a sparse set is a few dozen
    # images, so the duplication is cheap.
    for name in train:
        shutil.copy2(resolved / name, images_dir / name)

    print(f"staged {len(train)} train views ({arguments.views} requested) at {target}")
    print(f"test set is unchanged at {len(test)} views; render those from {source}")
    print("train with --holdout-every 1: the held-out views are not in this model")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
