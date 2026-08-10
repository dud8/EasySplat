#!/usr/bin/env python3
"""Generate deterministic, tiny COLMAP datasets for native msplat release tests."""

from __future__ import annotations

import argparse
import json
import math
import struct
import zlib
from pathlib import Path


CASES = (
    (500, "sphere"),
    (511, "plane"),
    (512, "thin"),
    (513, "elongated"),
    (767, "room"),
    (768, "clusters"),
    (769, "sphere"),
    (1023, "plane"),
    (1024, "thin"),
    (1025, "elongated"),
    (1279, "room"),
    (1500, "clusters"),
)

IDENTITY_ORIENTATION = '{"schema_version":1,"source_to_canonical_wxyz":[1,0,0,0]}\n'


def png_chunk(kind: bytes, payload: bytes) -> bytes:
    return struct.pack(">I", len(payload)) + kind + payload + struct.pack(">I", zlib.crc32(kind + payload))


def write_png(path: Path, width: int, height: int, seed: int) -> None:
    rows = bytearray()
    for y in range(height):
        rows.append(0)
        for x in range(width):
            rows.extend(
                (
                    (x * 7 + y * 3 + seed * 19) % 256,
                    (x * 2 + y * 11 + seed * 29) % 256,
                    (x * 13 + y * 5 + seed * 37) % 256,
                )
            )
    payload = b"\x89PNG\r\n\x1a\n"
    payload += png_chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0))
    payload += png_chunk(b"IDAT", zlib.compress(bytes(rows), 9))
    payload += png_chunk(b"IEND", b"")
    path.write_bytes(payload)


def point(layout: str, index: int, count: int) -> tuple[float, float, float]:
    u = (index + 0.5) / count
    angle = index * math.pi * (3.0 - math.sqrt(5.0))
    if layout == "sphere":
        radius = 0.28 + 0.04 * math.sin(index * 0.17)
        latitude = math.asin(2.0 * u - 1.0)
        return (
            radius * math.cos(latitude) * math.cos(angle),
            radius * math.sin(latitude),
            2.6 + radius * math.cos(latitude) * math.sin(angle),
        )
    if layout in {"plane", "thin"}:
        side = math.ceil(math.sqrt(count))
        x = ((index % side) / max(1, side - 1) - 0.5) * 0.7
        y = ((index // side) / max(1, side - 1) - 0.5) * 0.5
        depth = 0.025 if layout == "plane" else 0.002
        return x, y, 2.6 + depth * math.sin(index * 0.31)
    if layout == "elongated":
        return (
            (u - 0.5) * 1.8,
            0.12 * math.sin(angle),
            2.6 + 0.16 * math.cos(angle),
        )
    if layout == "room":
        lane = index % 3
        along = ((index // 3) + 0.5) / math.ceil(count / 3)
        if lane == 0:
            return -0.55, (along - 0.5) * 0.8, 2.3 + 0.3 * math.sin(angle)
        if lane == 1:
            return 0.55, (along - 0.5) * 0.8, 2.3 + 0.3 * math.cos(angle)
        return (along - 0.5) * 1.1, -0.4, 2.25 + 0.55 * ((index % 17) / 16)
    centers = ((-0.42, -0.18, 2.4), (0.0, 0.22, 2.75), (0.43, -0.1, 2.5))
    cx, cy, cz = centers[index % len(centers)]
    radius = 0.08 + 0.035 * ((index % 11) / 10)
    return cx + radius * math.cos(angle), cy + radius * math.sin(angle), cz + 0.06 * math.sin(index * 0.23)


def write_cameras(path: Path, width: int, height: int) -> None:
    focal_length = width * 0.9375
    with path.open("wb") as output:
        output.write(struct.pack("<Q", 1))
        output.write(
            struct.pack(
                "<iiQQ4d",
                1,
                1,
                width,
                height,
                focal_length,
                focal_length,
                width / 2,
                height / 2,
            )
        )


def write_images(path: Path, camera_ids: list[int]) -> None:
    with path.open("wb") as output:
        output.write(struct.pack("<Q", len(camera_ids)))
        for image_index, camera_id in enumerate(camera_ids):
            offset = image_index - (len(camera_ids) - 1) / 2
            output.write(
                struct.pack(
                    "<i7di",
                    image_index + 1,
                    1.0,
                    0.0,
                    0.0,
                    0.0,
                    offset * 0.11,
                    0.025 * math.sin(image_index),
                    0.0,
                    camera_id,
                )
            )
            output.write(f"{image_index:04d}.png".encode("ascii") + b"\0")
            output.write(struct.pack("<Q", 0))


def write_images_with_x_offsets(path: Path, x_offsets: list[float]) -> None:
    with path.open("wb") as output:
        output.write(struct.pack("<Q", len(x_offsets)))
        for image_index, x_offset in enumerate(x_offsets):
            output.write(
                struct.pack(
                    "<i7di",
                    image_index + 1,
                    1.0,
                    0.0,
                    0.0,
                    0.0,
                    x_offset,
                    0.0,
                    0.0,
                    1,
                )
            )
            output.write(f"{image_index:04d}.png".encode("ascii") + b"\0")
            output.write(struct.pack("<Q", 0))


def write_points(path: Path, count: int, layout: str) -> None:
    with path.open("wb") as output:
        output.write(struct.pack("<Q", count))
        for index in range(count):
            x, y, z = point(layout, index, count)
            output.write(struct.pack("<Q3d", index + 1, x, y, z))
            output.write(bytes(((index * 31) % 256, (index * 67) % 256, (index * 97) % 256)))
            output.write(struct.pack("<dQ", 0.5, 0))


def write_identity_orientation(sparse: Path) -> None:
    (sparse / "easysplat_orientation.json").write_text(
        IDENTITY_ORIENTATION,
        encoding="utf-8",
    )


def write_overflow_points(path: Path, count: int) -> None:
    with path.open("wb") as output:
        output.write(struct.pack("<Q", count))
        for index in range(count):
            angle = index * math.pi * (3.0 - math.sqrt(5.0))
            radius = 1.0e-5 * (1.0 + 0.1 * math.sin(index * 0.31))
            x = radius * math.cos(angle)
            y = radius * math.sin(angle)
            z = 2.4 + index * 2.0e-5
            output.write(struct.pack("<Q3d", index + 1, x, y, z))
            output.write(bytes(((index * 31) % 256, (index * 67) % 256, (index * 97) % 256)))
            output.write(struct.pack("<dQ", 0.5, 0))


def write_mixed_cameras(path: Path) -> None:
    # Geometry-Adam parity trains on the first camera. Keep its active pixels in
    # one SIMD group so unordered floating-point gradient atomics cannot turn a
    # near-zero cancellation into a different Adam step between test arms. The
    # second camera still forces the intended large mixed-resolution growth.
    cameras = ((1, 4, 4), (2, 320, 180))
    with path.open("wb") as output:
        output.write(struct.pack("<Q", len(cameras)))
        for camera_id, width, height in cameras:
            focal_length = width * 0.9375
            output.write(
                struct.pack(
                    "<iiQQ4d",
                    camera_id,
                    1,
                    width,
                    height,
                    focal_length,
                    focal_length,
                    width / 2,
                    height / 2,
                )
            )


def generate(root: Path) -> None:
    if root.exists():
        raise FileExistsError(f"refusing to replace existing output: {root}")
    root.mkdir(parents=True)
    fixtures = []
    for case_index, (count, layout) in enumerate(CASES):
        name = f"{case_index + 1:02d}-{layout}-{count}"
        dataset = root / name
        images = dataset / "images"
        sparse = dataset / "sparse" / "0"
        images.mkdir(parents=True)
        sparse.mkdir(parents=True)
        camera_count = 4 + case_index % 5
        numeric_stability_stress = case_index == 10
        metal_pipeline_stress = case_index == 10
        width, height = (320, 180) if numeric_stability_stress else (32, 32)
        for image_index in range(camera_count):
            write_png(
                images / f"{image_index:04d}.png",
                width,
                height,
                case_index * 11 + image_index,
            )
        write_cameras(sparse / "cameras.bin", width, height)
        write_images(sparse / "images.bin", [1] * camera_count)
        write_points(sparse / "points3D.bin", count, layout)
        write_identity_orientation(sparse)
        fixtures.append(
            {
                "camera_count": camera_count,
                "dataset": name,
                "layout": layout,
                "metal_pipeline_stress": metal_pipeline_stress,
                "numeric_stability_stress": numeric_stability_stress,
                "point_count": count,
                "raster_overflow_stress": False,
                "mixed_resolution_stress": False,
                "resolution": [width, height],
            }
        )

    overflow_name = "13-overflow-2304"
    overflow_dataset = root / overflow_name
    overflow_images = overflow_dataset / "images"
    overflow_sparse = overflow_dataset / "sparse" / "0"
    overflow_images.mkdir(parents=True)
    overflow_sparse.mkdir(parents=True)
    for image_index in range(4):
        write_png(overflow_images / f"{image_index:04d}.png", 32, 32, 200 + image_index)
    write_cameras(overflow_sparse / "cameras.bin", 32, 32)
    write_images(overflow_sparse / "images.bin", [1, 1, 1, 1])
    write_overflow_points(overflow_sparse / "points3D.bin", 2304)
    write_identity_orientation(overflow_sparse)
    fixtures.append(
        {
            "camera_count": 4,
            "dataset": overflow_name,
            "layout": "overflow",
            "metal_pipeline_stress": False,
            "numeric_stability_stress": False,
            "point_count": 2304,
            "raster_overflow_stress": True,
            "mixed_resolution_stress": False,
            "resolution": [32, 32],
        }
    )

    broad_name = "16-broad-overflow-2304"
    broad_dataset = root / broad_name
    broad_images = broad_dataset / "images"
    broad_sparse = broad_dataset / "sparse" / "0"
    broad_images.mkdir(parents=True)
    broad_sparse.mkdir(parents=True)
    write_png(broad_images / "0000.png", 128, 128, 500)
    write_cameras(broad_sparse / "cameras.bin", 128, 128)
    write_images(broad_sparse / "images.bin", [1])
    write_overflow_points(broad_sparse / "points3D.bin", 2304)
    write_identity_orientation(broad_sparse)
    fixtures.append(
        {
            "camera_count": 1,
            "dataset": broad_name,
            "layout": "broad-overflow",
            "metal_pipeline_stress": False,
            "numeric_stability_stress": False,
            "point_count": 2304,
            "raster_overflow_stress": False,
            "broad_raster_stress": True,
            "mixed_resolution_stress": False,
            "resolution": [128, 128],
        }
    )

    increasing_name = "15-increasing-overflow-10000"
    increasing_dataset = root / increasing_name
    increasing_images = increasing_dataset / "images"
    increasing_sparse = increasing_dataset / "sparse" / "0"
    increasing_images.mkdir(parents=True)
    increasing_sparse.mkdir(parents=True)
    write_png(increasing_images / "0000.png", 32, 32, 400)
    write_png(increasing_images / "0001.png", 32, 32, 401)
    write_cameras(increasing_sparse / "cameras.bin", 32, 32)
    write_images_with_x_offsets(increasing_sparse / "images.bin", [1.0, 0.0])
    write_overflow_points(increasing_sparse / "points3D.bin", 10000)
    write_identity_orientation(increasing_sparse)
    fixtures.append(
        {
            "camera_count": 2,
            "dataset": increasing_name,
            "layout": "increasing-overflow",
            "metal_pipeline_stress": False,
            "numeric_stability_stress": False,
            "point_count": 10000,
            "raster_overflow_stress": False,
            "raster_replay_stress": True,
            "mixed_resolution_stress": False,
            "resolution": [32, 32],
        }
    )

    mixed_name = "14-mixed-resolution-500"
    mixed_dataset = root / mixed_name
    mixed_images = mixed_dataset / "images"
    mixed_sparse = mixed_dataset / "sparse" / "0"
    mixed_images.mkdir(parents=True)
    mixed_sparse.mkdir(parents=True)
    write_png(mixed_images / "0000.png", 4, 4, 300)
    write_png(mixed_images / "0001.png", 320, 180, 301)
    write_mixed_cameras(mixed_sparse / "cameras.bin")
    write_images(mixed_sparse / "images.bin", [1, 2])
    write_points(mixed_sparse / "points3D.bin", 500, "sphere")
    write_identity_orientation(mixed_sparse)
    fixtures.append(
        {
            "camera_count": 2,
            "dataset": mixed_name,
            "layout": "sphere",
            "metal_pipeline_stress": False,
            "numeric_stability_stress": False,
            "point_count": 500,
            "raster_overflow_stress": False,
            "mixed_resolution_stress": True,
            "resolution": [[4, 4], [320, 180]],
        }
    )

    exact_budget_name = "17-exact-budget-1279"
    exact_budget_dataset = root / exact_budget_name
    exact_budget_images = exact_budget_dataset / "images"
    exact_budget_sparse = exact_budget_dataset / "sparse" / "0"
    exact_budget_images.mkdir(parents=True)
    exact_budget_sparse.mkdir(parents=True)
    write_png(exact_budget_images / "0000.png", 640, 360, 600)
    write_cameras(exact_budget_sparse / "cameras.bin", 640, 360)
    write_images(exact_budget_sparse / "images.bin", [1])
    write_points(exact_budget_sparse / "points3D.bin", 1279, "room")
    write_identity_orientation(exact_budget_sparse)
    fixtures.append(
        {
            "camera_count": 1,
            "dataset": exact_budget_name,
            "exact_budget_stress": True,
            "layout": "room",
            "metal_pipeline_stress": False,
            "numeric_stability_stress": False,
            "point_count": 1279,
            "raster_overflow_stress": False,
            "mixed_resolution_stress": False,
            "resolution": [640, 360],
        }
    )
    (root / "manifest.json").write_text(
        json.dumps({"fixtures": fixtures, "schema_version": 1}, indent=2) + "\n",
        encoding="utf-8",
    )


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    generate(args.output.resolve())


if __name__ == "__main__":
    main()
