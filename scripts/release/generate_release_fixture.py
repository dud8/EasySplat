#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Generate and authenticate EasySplat's synthetic release photo fixture."""

from __future__ import annotations

import argparse
import binascii
import ctypes
import errno
import hashlib
import json
import math
import os
from pathlib import Path
import re
import shutil
import stat
import struct
import sys
import tempfile
import unicodedata


SCHEMA_VERSION = 1
FIXTURE_ID = "org.easysplat.release-smoke.v1"
MANIFEST_NAME = "release_fixture_manifest.json"
PUBLISHED_MANIFEST_NAME = "fixture-manifest.json"
IMAGE_DIRECTORY = "images"
WIDTH = 640
HEIGHT = 480
VIEW_COUNT = 12
FX = 612.0
FY = 610.0
CX = 319.5
CY = 239.5
DEPTH_PLANES = (3.8, 5.8, 8.8)
SHA256_PATTERN = re.compile(r"[0-9a-f]{64}")
PNG_SIGNATURE = b"\x89PNG\r\n\x1a\n"
CLOSURE_DOMAIN = b"EasySplat release fixture closure v1\0"

# The first and last views deliberately share orientation so the checked-in
# witnesses isolate translation parallax. Interior views add mild yaw/pitch.
VIEWS = (
    (
        (-0.66, -0.08, 0.00),
        2.0,
        -1.0,
        (0.03489418134011367, -0.01745240643728351, 0.9992386149554826),
        (0.9993908270190958, 0.0, -0.03489949670250097),
        (0.0006090802009086826, 0.9998476951563913, 0.017441774902830158),
    ),
    (
        (-0.54, 0.06, 0.03),
        1.4,
        -0.5,
        (0.02443124785017348, -0.008726535498373935, 0.9996634242117088),
        (0.9997014897811831, 0.0, -0.024432178152653153),
        (0.00021320826995172384, 0.9999619230641713, 0.008723930538352801),
    ),
    (
        (-0.42, -0.12, 0.01),
        0.8,
        0.2,
        (0.013962095276764654, 0.003490651415223732, 0.9998964322609517),
        (0.9999025240093042, 0.0, -0.013962180339145272),
        (-0.00004873710456044641, 0.9999939076577904, -0.0034903111605188598),
    ),
    (
        (-0.30, 0.10, 0.04),
        0.2,
        -0.8,
        (0.0034903111605188598, -0.013962180339145272, 0.9998964322609517),
        (0.9999939076577904, 0.0, -0.003490651415223732),
        (0.00004873710456044641, 0.9999025240093042, 0.013962095276764654),
    ),
    (
        (-0.18, -0.05, 0.02),
        -0.4,
        0.4,
        (-0.006981090169572635, 0.0069812602979615525, 0.999951262004652),
        (0.9999756307053947, 0.0, 0.0069812602979615525),
        (0.000048737995347894225, 0.9999756307053947, -0.006981090169572635),
    ),
    (
        (-0.06, 0.12, 0.05),
        -0.8,
        -0.3,
        (-0.0139619889490318, -0.00523596383141958, 0.9998888175929077),
        (0.9999025240093042, 0.0, 0.013962180339145272),
        (-0.00007310547126352221, 0.9999862922474267, 0.0052354534506578645),
    ),
    (
        (0.06, -0.10, 0.03),
        -0.8,
        0.3,
        (-0.0139619889490318, 0.00523596383141958, 0.9998888175929077),
        (0.9999025240093042, 0.0, 0.013962180339145272),
        (0.00007310547126352221, 0.9999862922474267, -0.0052354534506578645),
    ),
    (
        (0.18, 0.05, 0.01),
        -0.4,
        -0.4,
        (-0.006981090169572635, -0.0069812602979615525, 0.999951262004652),
        (0.9999756307053947, 0.0, 0.0069812602979615525),
        (-0.000048737995347894225, 0.9999756307053947, 0.006981090169572635),
    ),
    (
        (0.30, -0.12, 0.04),
        0.2,
        0.8,
        (0.0034903111605188598, 0.013962180339145272, 0.9998964322609517),
        (0.9999939076577904, 0.0, -0.003490651415223732),
        (-0.00004873710456044641, 0.9999025240093042, -0.013962095276764654),
    ),
    (
        (0.42, 0.10, 0.02),
        0.8,
        -0.2,
        (0.013962095276764654, -0.003490651415223732, 0.9998964322609517),
        (0.9999025240093042, 0.0, -0.013962180339145272),
        (0.00004873710456044641, 0.9999939076577904, 0.0034903111605188598),
    ),
    (
        (0.54, -0.06, 0.03),
        1.4,
        0.5,
        (0.02443124785017348, 0.008726535498373935, 0.9996634242117088),
        (0.9997014897811831, 0.0, -0.024432178152653153),
        (-0.00021320826995172384, 0.9999619230641713, -0.008723930538352801),
    ),
    (
        (0.66, -0.08, 0.00),
        2.0,
        -1.0,
        (0.03489418134011367, -0.01745240643728351, 0.9992386149554826),
        (0.9993908270190958, 0.0, -0.03489949670250097),
        (0.0006090802009086826, 0.9998476951563913, 0.017441774902830158),
    ),
)


class FixtureError(RuntimeError):
    pass


def fail(message: str) -> None:
    raise FixtureError(message)


def canonical_json_bytes(value: object) -> bytes:
    return (json.dumps(value, indent=2, sort_keys=True) + "\n").encode("utf-8")


def sha256_bytes(payload: bytes) -> str:
    return hashlib.sha256(payload).hexdigest()


def script_path() -> Path:
    return Path(__file__).resolve()


def manifest_path() -> Path:
    return script_path().with_name(MANIFEST_NAME)


def camera_contract() -> dict[str, object]:
    views = []
    for index, (position, yaw, pitch, forward, right, up) in enumerate(VIEWS, start=1):
        views.append(
            {
                "basisWorldFromCamera": {
                    "forward": list(forward),
                    "right": list(right),
                    "up": list(up),
                },
                "image": f"{IMAGE_DIRECTORY}/view-{index:02d}.png",
                "pitchDegrees": pitch,
                "positionMeters": list(position),
                "view": index,
                "yawDegrees": yaw,
            }
        )
    return {
        "cxPixels": CX,
        "cyPixels": CY,
        "fxPixels": FX,
        "fyPixels": FY,
        "model": "PINHOLE",
        "views": views,
    }


def project_world(point, view):
    position, _, _, forward, right, up = view
    relative = tuple(point[index] - position[index] for index in range(3))
    depth = sum(relative[index] * forward[index] for index in range(3))
    horizontal = sum(relative[index] * right[index] for index in range(3))
    vertical = sum(relative[index] * up[index] for index in range(3))
    return (
        CX + FX * horizontal / depth,
        CY - FY * vertical / depth,
    )


def scene_contract() -> dict[str, object]:
    witnesses = []
    for depth in DEPTH_PLANES:
        point = (0.85, 0.25, depth)
        witnesses.append(
            {
                "viewPixels": [
                    [round(value, 9) for value in project_world(point, VIEWS[index])]
                    for index in (0, 11)
                ],
                "worldMeters": list(point),
            }
        )
    return {
        "construction": "three coherent world-textured planes with finite near and middle occluders",
        "coordinateSystem": "right-handed; x right, y up, z forward; meters",
        "depthPlanesMeters": list(DEPTH_PLANES),
        "parallaxWitnesses": witnesses,
    }


def image_contract() -> dict[str, object]:
    return {
        "bitDepth": 8,
        "colorType": "RGB",
        "count": VIEW_COUNT,
        "heightPixels": HEIGHT,
        "pngEncoding": "filter-none-deflate-stored-v1",
        "widthPixels": WIDTH,
    }


def load_authenticated_manifest() -> tuple[dict[str, object], bytes]:
    path = manifest_path()
    try:
        metadata = path.lstat()
        payload = path.read_bytes()
    except OSError as error:
        fail(f"cannot read canonical fixture manifest: {error}")
    if not stat.S_ISREG(metadata.st_mode) or metadata.st_nlink != 1:
        fail("canonical fixture manifest must be an ordinary single-link file")
    try:
        manifest = json.loads(payload)
    except (UnicodeError, json.JSONDecodeError) as error:
        fail(f"canonical fixture manifest is invalid JSON: {error}")
    if not isinstance(manifest, dict) or payload != canonical_json_bytes(manifest):
        fail("canonical fixture manifest must use canonical sorted JSON")
    if (
        manifest.get("schemaVersion") != SCHEMA_VERSION
        or manifest.get("fixtureID") != FIXTURE_ID
    ):
        fail("canonical fixture manifest has an unsupported identity or schema")
    provenance = manifest.get("provenance")
    if not isinstance(provenance, dict):
        fail("canonical fixture manifest has no provenance")
    source_digest = sha256_bytes(script_path().read_bytes())
    if provenance.get("generatorSHA256") != source_digest:
        fail("fixture generator source digest differs from the canonical manifest")
    if provenance.get("generatorPath") != "scripts/release/generate_release_fixture.py":
        fail("canonical fixture manifest has an unexpected generator path")
    if provenance.get("sourceAssets") != [] or provenance.get("synthetic") is not True:
        fail(
            "canonical fixture provenance must describe an asset-free synthetic corpus"
        )
    license_record = manifest.get("license")
    if not isinstance(license_record, dict) or license_record.get("spdxID") != "MIT":
        fail("canonical fixture manifest must identify the MIT license")
    if manifest.get("image") != image_contract():
        fail("canonical fixture manifest image contract differs from the generator")
    if manifest.get("camera") != camera_contract():
        fail("canonical fixture manifest camera contract differs from the generator")
    if manifest.get("scene") != scene_contract():
        fail("canonical fixture manifest scene contract differs from the generator")
    rows = manifest.get("files")
    if not isinstance(rows, list) or len(rows) != VIEW_COUNT:
        fail("canonical fixture manifest must pin exactly twelve image files")
    expected_paths = [
        f"{IMAGE_DIRECTORY}/view-{index:02d}.png" for index in range(1, 13)
    ]
    if [
        row.get("path") if isinstance(row, dict) else None for row in rows
    ] != expected_paths:
        fail("canonical fixture manifest image inventory is not exact and ordered")
    for index, row in enumerate(rows, start=1):
        if (
            not isinstance(row, dict)
            or row.get("view") != index
            or not isinstance(row.get("bytes"), int)
            or row["bytes"] <= 0
            or not isinstance(row.get("sha256"), str)
            or SHA256_PATTERN.fullmatch(row["sha256"]) is None
        ):
            fail("canonical fixture manifest has an invalid image record")
    if not isinstance(manifest.get("totalBytes"), int) or manifest["totalBytes"] <= 0:
        fail("canonical fixture manifest has an invalid total byte count")
    if (
        not isinstance(manifest.get("closureSHA256"), str)
        or SHA256_PATTERN.fullmatch(manifest["closureSHA256"]) is None
    ):
        fail("canonical fixture manifest has an invalid closure digest")
    return manifest, payload


def mix32(x_value: int, y_value: int, seed: int) -> int:
    value = (
        x_value * 0x1F123BB5 + y_value * 0x5F356495 + seed * 0x6C8E9CF5
    ) & 0xFFFFFFFF
    value ^= value >> 16
    value = (value * 0x7FEB352D) & 0xFFFFFFFF
    value ^= value >> 15
    value = (value * 0x846CA68B) & 0xFFFFFFFF
    return value ^ (value >> 16)


def surface_color(layer: int, world_x: float, world_y: float) -> tuple[int, int, int]:
    cell_x = int(math.floor((world_x + 12.0) * 96.0))
    cell_y = int(math.floor((world_y + 8.0) * 96.0))
    noise = mix32(cell_x, cell_y, 97 + layer * 131)
    checker = ((cell_x // 7) ^ (cell_y // 7)) & 1
    grid = cell_x % 29 < 2 or cell_y % 31 < 2
    palettes = ((188, 76, 48), (46, 150, 116), (48, 92, 174))
    base = palettes[layer]
    lift = 34 if checker else -18
    if grid:
        return (238 - layer * 14, 226 - layer * 9, 86 + layer * 24)
    return tuple(
        max(12, min(244, base[channel] + lift + ((noise >> (channel * 8)) & 0x3F) - 31))
        for channel in range(3)
    )


def near_surface_visible(world_x: float, world_y: float) -> bool:
    left_panel = -1.70 <= world_x <= -0.18 and -1.10 <= world_y <= 1.12
    diamond = abs((world_x - 1.02) / 0.92) + abs((world_y + 0.02) / 0.82) <= 1.0
    shelf = -0.10 <= world_x <= 1.88 and -1.28 <= world_y <= -0.92
    return left_panel or diamond or shelf


def middle_surface_visible(world_x: float, world_y: float) -> bool:
    outer = -2.75 <= world_x <= 2.70 and -1.72 <= world_y <= 1.65
    aperture = -1.32 <= world_x <= 1.18 and -0.78 <= world_y <= 0.82
    pillars = (-2.38 <= world_x <= -1.82 and -1.95 <= world_y <= 1.90) or (
        1.72 <= world_x <= 2.30 and -1.95 <= world_y <= 1.90
    )
    diagonal = abs(world_y - 0.32 * world_x) <= 0.13 and -2.4 <= world_x <= 2.4
    return (outer and not aperture) or pillars or diagonal


def render_view(view_index: int) -> bytes:
    position, _, _, forward, right, up = VIEWS[view_index]
    output = bytearray()
    for pixel_y in range(HEIGHT):
        output.append(0)
        image_y = (pixel_y + 0.5 - CY) / FY
        for pixel_x in range(WIDTH):
            image_x = (pixel_x + 0.5 - CX) / FX
            direction = (
                forward[0] + right[0] * image_x - up[0] * image_y,
                forward[1] + right[1] * image_x - up[1] * image_y,
                forward[2] + right[2] * image_x - up[2] * image_y,
            )
            color = None
            for layer, depth in enumerate(DEPTH_PLANES):
                distance = (depth - position[2]) / direction[2]
                world_x = position[0] + distance * direction[0]
                world_y = position[1] + distance * direction[1]
                visible = (
                    near_surface_visible(world_x, world_y)
                    if layer == 0
                    else middle_surface_visible(world_x, world_y)
                    if layer == 1
                    else True
                )
                if visible:
                    color = surface_color(layer, world_x, world_y)
                    break
            output.extend(color)
    return bytes(output)


def adler32(payload: bytes) -> int:
    first = 1
    second = 0
    modulus = 65521
    for offset in range(0, len(payload), 5552):
        for value in payload[offset : offset + 5552]:
            first += value
            second += first
        first %= modulus
        second %= modulus
    return (second << 16) | first


def stored_deflate(payload: bytes) -> bytes:
    output = bytearray(b"\x78\x01")
    offset = 0
    while offset < len(payload):
        chunk = payload[offset : offset + 65535]
        offset += len(chunk)
        output.append(1 if offset == len(payload) else 0)
        output.extend(struct.pack("<HH", len(chunk), 0xFFFF - len(chunk)))
        output.extend(chunk)
    output.extend(struct.pack(">I", adler32(payload)))
    return bytes(output)


def png_chunk(kind: bytes, payload: bytes) -> bytes:
    return (
        struct.pack(">I", len(payload))
        + kind
        + payload
        + struct.pack(">I", binascii.crc32(kind + payload) & 0xFFFFFFFF)
    )


def png_bytes(scanlines: bytes) -> bytes:
    header = struct.pack(">IIBBBBB", WIDTH, HEIGHT, 8, 2, 0, 0, 0)
    return (
        PNG_SIGNATURE
        + png_chunk(b"IHDR", header)
        + png_chunk(b"IDAT", stored_deflate(scanlines))
        + png_chunk(b"IEND", b"")
    )


def render_fixture_bytes() -> dict[str, bytes]:
    return {
        f"{IMAGE_DIRECTORY}/view-{index + 1:02d}.png": png_bytes(render_view(index))
        for index in range(VIEW_COUNT)
    }


def closure_digest(files: dict[str, bytes]) -> tuple[str, int]:
    digest = hashlib.sha256()
    digest.update(CLOSURE_DOMAIN)
    total = 0
    for relative in sorted(files):
        payload = files[relative]
        file_digest = hashlib.sha256(payload).digest()
        total += len(payload)
        digest.update(relative.encode("utf-8"))
        digest.update(b"\0")
        digest.update(str(len(payload)).encode("ascii"))
        digest.update(b"\0")
        digest.update(file_digest)
    return digest.hexdigest(), total


def compare_rendered_bytes(
    manifest: dict[str, object], files: dict[str, bytes]
) -> None:
    rows = manifest["files"]
    for row in rows:
        payload = files[row["path"]]
        if len(payload) != row["bytes"] or sha256_bytes(payload) != row["sha256"]:
            fail(
                f"rendered fixture bytes differ from canonical manifest: {row['path']}"
            )
    closure, total = closure_digest(files)
    if closure != manifest["closureSHA256"] or total != manifest["totalBytes"]:
        fail("rendered fixture closure differs from canonical manifest")


def inspect_safe_parent(path: Path) -> Path:
    raw = os.fspath(path)
    if not path.is_absolute() or os.path.normpath(raw) != raw:
        fail("output path must be absolute and normalized")
    if not path.name or unicodedata.normalize("NFC", path.name) != path.name:
        fail("output path has an unsafe final component")
    if any(ord(character) < 32 for character in path.name):
        fail("output path has an unsafe final component")
    if os.path.lexists(raw):
        fail("output path must not already exist")
    parent = path.parent
    try:
        metadata = parent.lstat()
    except OSError as error:
        fail(f"cannot inspect output parent: {error}")
    if not stat.S_ISDIR(metadata.st_mode) or metadata.st_uid != os.getuid():
        fail("output parent must be a caller-owned directory")
    if stat.S_IMODE(metadata.st_mode) & 0o022:
        fail("output parent cannot be group- or world-writable")
    if os.path.realpath(os.fspath(parent)) != os.fspath(parent):
        fail("output parent cannot contain symlink aliases")
    return parent


def write_file(path: Path, payload: bytes, mode: int) -> None:
    flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL
    flags |= getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOFOLLOW", 0)
    descriptor = os.open(path, flags, 0o600)
    try:
        view = memoryview(payload)
        while view:
            written = os.write(descriptor, view)
            if written <= 0:
                fail(f"short write while creating {path.name}")
            view = view[written:]
        os.fsync(descriptor)
        os.fchmod(descriptor, mode)
    finally:
        os.close(descriptor)


def fsync_directory(path: Path) -> None:
    descriptor = os.open(path, os.O_RDONLY | getattr(os, "O_DIRECTORY", 0))
    try:
        os.fsync(descriptor)
    finally:
        os.close(descriptor)


def remove_staging(path: Path) -> None:
    if not os.path.lexists(path):
        return
    for candidate in sorted(path.rglob("*"), reverse=True):
        if candidate.is_symlink():
            candidate.unlink()
        elif candidate.is_dir():
            candidate.chmod(0o700)
        else:
            candidate.chmod(0o600)
    path.chmod(0o700)
    shutil.rmtree(path)


def rename_exclusive(source: Path, destination: Path) -> None:
    if sys.platform == "darwin":
        renameatx_np = ctypes.CDLL(None, use_errno=True).renameatx_np
        renameatx_np.argtypes = (
            ctypes.c_int,
            ctypes.c_char_p,
            ctypes.c_int,
            ctypes.c_char_p,
            ctypes.c_uint,
        )
        renameatx_np.restype = ctypes.c_int
        result = renameatx_np(
            -2,
            os.fsencode(source),
            -2,
            os.fsencode(destination),
            0x00000004 | 0x00000010,
        )
        if result != 0:
            error = ctypes.get_errno()
            if error == errno.EEXIST:
                fail("output path appeared before transactional publication")
            fail(f"cannot publish fixture transactionally: {os.strerror(error)}")
        return
    if os.path.lexists(destination):
        fail("output path appeared before transactional publication")
    os.rename(source, destination)


def generate_fixture(output: Path) -> dict[str, object]:
    parent = inspect_safe_parent(output)
    manifest, manifest_bytes = load_authenticated_manifest()
    files = render_fixture_bytes()
    compare_rendered_bytes(manifest, files)
    staging = Path(tempfile.mkdtemp(prefix=f".{output.name}.staging-", dir=parent))
    published = False
    try:
        staging.chmod(0o700)
        images = staging / IMAGE_DIRECTORY
        images.mkdir(mode=0o700)
        for relative, payload in sorted(files.items()):
            write_file(staging / relative, payload, 0o444)
        write_file(staging / PUBLISHED_MANIFEST_NAME, manifest_bytes, 0o444)
        images.chmod(0o555)
        staging.chmod(0o555)
        fsync_directory(images)
        fsync_directory(staging)
        verify_fixture(staging)
        rename_exclusive(staging, output)
        published = True
        fsync_directory(parent)
    finally:
        if not published:
            remove_staging(staging)
    return verify_fixture(output)


def read_authenticated_file(
    path: Path, expected_mode: int, expected_size: int
) -> bytes:
    flags = os.O_RDONLY | os.O_NONBLOCK
    flags |= getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOFOLLOW", 0)
    try:
        descriptor = os.open(path, flags)
    except OSError as error:
        fail(
            f"fixture closure contains an unreadable or linked file: {path.name}: {error}"
        )
    try:
        initial = os.fstat(descriptor)
        if (
            not stat.S_ISREG(initial.st_mode)
            or initial.st_nlink != 1
            or stat.S_IMODE(initial.st_mode) != expected_mode
        ):
            fail(f"fixture closure contains an unsafe regular file: {path.name}")
        if initial.st_size != expected_size:
            fail(
                "fixture closure file has an unexpected size: "
                f"{path.name}: expected {expected_size} bytes, "
                f"found {initial.st_size}"
            )
        chunks = []
        while True:
            chunk = os.read(descriptor, 1024 * 1024)
            if not chunk:
                break
            chunks.append(chunk)
        final = os.fstat(descriptor)
        path_metadata = path.lstat()
    finally:
        os.close(descriptor)
    fields = (
        "st_dev",
        "st_ino",
        "st_mode",
        "st_nlink",
        "st_size",
        "st_mtime_ns",
        "st_ctime_ns",
    )
    if any(getattr(initial, field) != getattr(final, field) for field in fields) or any(
        getattr(final, field) != getattr(path_metadata, field) for field in fields
    ):
        fail(f"fixture closure changed while it was authenticated: {path.name}")
    payload = b"".join(chunks)
    if len(payload) != initial.st_size:
        fail(f"fixture closure file was not read completely: {path.name}")
    return payload


def verified_attestation(
    manifest: dict[str, object], manifest_bytes: bytes
) -> dict[str, object]:
    return {
        "fileCount": VIEW_COUNT,
        "fixtureClosureSHA256": manifest["closureSHA256"],
        "fixtureID": FIXTURE_ID,
        "fixtureManifestSHA256": sha256_bytes(manifest_bytes),
        "fixtureSchemaVersion": SCHEMA_VERSION,
        "generatorSHA256": manifest["provenance"]["generatorSHA256"],
        "licenseSPDX": "MIT",
        "schemaVersion": 1,
        "status": "verified",
        "totalBytes": manifest["totalBytes"],
    }


def verify_fixture(root: Path) -> dict[str, object]:
    raw = os.fspath(root)
    if (
        not root.is_absolute()
        or os.path.normpath(raw) != raw
        or os.path.realpath(raw) != raw
    ):
        fail("fixture root must be an absolute normalized path without symlink aliases")
    manifest, manifest_bytes = load_authenticated_manifest()
    try:
        root_metadata = root.lstat()
        image_metadata = (root / IMAGE_DIRECTORY).lstat()
    except OSError as error:
        fail(f"cannot inspect fixture root: {error}")
    if (
        not stat.S_ISDIR(root_metadata.st_mode)
        or stat.S_IMODE(root_metadata.st_mode) != 0o555
        or root_metadata.st_uid != os.getuid()
        or not stat.S_ISDIR(image_metadata.st_mode)
        or stat.S_IMODE(image_metadata.st_mode) != 0o555
        or image_metadata.st_uid != os.getuid()
    ):
        fail(
            "fixture root and image directory must be caller-owned read-only directories"
        )
    root_inventory = sorted(entry.name for entry in os.scandir(root))
    if root_inventory != [PUBLISHED_MANIFEST_NAME, IMAGE_DIRECTORY]:
        fail("fixture root inventory differs from the canonical closure")
    published_manifest = read_authenticated_file(
        root / PUBLISHED_MANIFEST_NAME, 0o444, len(manifest_bytes)
    )
    if published_manifest != manifest_bytes:
        fail("fixture manifest copy changed")
    rows = manifest["files"]
    expected_names = [Path(row["path"]).name for row in rows]
    image_inventory = sorted(entry.name for entry in os.scandir(root / IMAGE_DIRECTORY))
    if image_inventory != expected_names:
        fail("fixture image inventory differs from the canonical closure")
    files = {}
    for row in rows:
        relative = row["path"]
        payload = read_authenticated_file(root / relative, 0o444, row["bytes"])
        if len(payload) != row["bytes"] or sha256_bytes(payload) != row["sha256"]:
            fail(f"fixture image changed: {relative}")
        files[relative] = payload
    closure, total = closure_digest(files)
    if closure != manifest["closureSHA256"] or total != manifest["totalBytes"]:
        fail("fixture closure digest changed")
    return verified_attestation(manifest, manifest_bytes)


def write_attestation(path: Path, record: dict[str, object]) -> None:
    inspect_safe_parent(path)
    write_file(path, canonical_json_bytes(record), 0o600)
    fsync_directory(path.parent)


def parse_arguments(argv=None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    generate = commands.add_parser(
        "generate", help="generate the pinned fixture transactionally"
    )
    generate.add_argument("--output", required=True, type=Path)
    verify = commands.add_parser("verify", help="verify an existing generated fixture")
    verify.add_argument("--root", required=True, type=Path)
    verify.add_argument("--attestation", type=Path)
    return parser.parse_args(argv)


def main(argv=None) -> int:
    arguments = parse_arguments(argv)
    if arguments.command == "generate":
        record = generate_fixture(arguments.output)
    else:
        record = verify_fixture(arguments.root)
        if arguments.attestation is not None:
            write_attestation(arguments.attestation, record)
    sys.stdout.buffer.write(canonical_json_bytes(record))
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except FixtureError as error:
        print(f"release fixture error: {error}", file=sys.stderr)
        raise SystemExit(1)
