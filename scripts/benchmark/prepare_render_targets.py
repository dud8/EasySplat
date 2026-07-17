#!/usr/bin/env python3
"""Prepare immutable RGB ground truth in the exact camera domain used by msplat."""

from __future__ import annotations

import argparse
import ctypes
import errno
import hashlib
import io
import json
import math
import os
import platform
import shutil
import stat
import struct
import subprocess
import sys
import tempfile
from pathlib import Path, PurePosixPath
from typing import Any

import numpy
from PIL import Image


MAX_SPEC_BYTES = 4 * 1024 * 1024
MAX_SOURCE_BYTES = 256 * 1024 * 1024
MAX_PIXELS = 4_194_304
BOUNDARY_SAMPLES = 200
INVERSE_ITERATIONS = 20
SHA256_PREFIX = "sha256:"
MSPLAT_SOURCE_COMMIT = "106499b0a53f82b0c92d013b0861fbebd341b17e"
NATIVE_DECODE_CONTRACT = "native_coregraphics_imageio_rgb8_v1"
CAMERA_DIGEST_PREFIX = b"EasySplat render camera digest v1\0"


class PreparationError(RuntimeError):
    pass


def canonical_json_bytes(value: Any) -> bytes:
    return (
        json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=False)
        + "\n"
    ).encode("utf-8")


def sha256_bytes(value: bytes) -> str:
    return SHA256_PREFIX + hashlib.sha256(value).hexdigest()


def render_camera_digest(value: Any) -> str:
    camera = _render_camera(value, "render camera digest")
    payload = bytearray(CAMERA_DIGEST_PREFIX)
    payload.extend(struct.pack(">II", camera["width"], camera["height"]))
    values = (
        camera["projection_matrix_column_major"]
        + camera["world_to_camera_matrix_column_major"]
    )
    for position, value in enumerate(values):
        try:
            bits = struct.unpack(">I", struct.pack(">f", value))[0]
        except (OverflowError, struct.error) as error:
            raise PreparationError(
                f"render camera digest value {position} is outside Float32"
            ) from error
        if bits & 0x7FFF_FFFF == 0:
            bits = 0
        payload.extend(struct.pack(">I", bits))
    return sha256_bytes(bytes(payload))


def _exact_keys(value: dict[str, Any], expected: set[str], label: str) -> None:
    if set(value) != expected:
        missing = sorted(expected - set(value))
        unexpected = sorted(set(value) - expected)
        raise PreparationError(
            f"{label} fields are invalid (missing={missing}, unexpected={unexpected})"
        )


def _mapping(value: Any, label: str) -> dict[str, Any]:
    if not isinstance(value, dict):
        raise PreparationError(f"{label} must be an object")
    return value


def _finite_number(value: Any, label: str) -> float:
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        raise PreparationError(f"{label} must be a finite number")
    result = float(value)
    if not math.isfinite(result):
        raise PreparationError(f"{label} must be a finite number")
    return result


def _positive_dimension(value: Any, label: str) -> int:
    if type(value) is not int or not 1 <= value <= 16_384:
        raise PreparationError(f"{label} is invalid")
    return value


def _digest(value: Any, label: str) -> str:
    if (
        not isinstance(value, str)
        or len(value) != 71
        or not value.startswith(SHA256_PREFIX)
        or any(character not in "0123456789abcdef" for character in value[7:])
    ):
        raise PreparationError(f"{label} is not a SHA-256 digest")
    return value


def _relative_path(value: Any, label: str) -> PurePosixPath:
    if not isinstance(value, str) or not value or "\\" in value or value.startswith("/"):
        raise PreparationError(f"{label} must be a safe relative path")
    path = PurePosixPath(value)
    if any(part in {"", ".", ".."} for part in path.parts):
        raise PreparationError(f"{label} must be a safe relative path")
    return path


def _read_relative_regular(
    root_fd: int,
    relative: PurePosixPath,
    limit: int,
    label: str,
) -> bytes:
    directory_fd = os.dup(root_fd)
    try:
        for component in relative.parts[:-1]:
            try:
                next_fd = os.open(
                    component,
                    os.O_RDONLY | os.O_DIRECTORY | os.O_CLOEXEC | os.O_NOFOLLOW,
                    dir_fd=directory_fd,
                )
            except OSError as error:
                raise PreparationError(
                    f"{label} has a missing, non-directory, or symbolic link ancestor"
                ) from error
            os.close(directory_fd)
            directory_fd = next_fd
        try:
            descriptor = os.open(
                relative.name,
                os.O_RDONLY | os.O_CLOEXEC | os.O_NOFOLLOW,
                dir_fd=directory_fd,
            )
        except OSError as error:
            detail = (
                "symbolic link"
                if error.errno == errno.ELOOP
                else "missing or unreadable file"
            )
            raise PreparationError(f"{label} is a {detail}") from error
        try:
            metadata = os.fstat(descriptor)
            if not stat.S_ISREG(metadata.st_mode):
                raise PreparationError(f"{label} is not a regular file")
            if metadata.st_size > limit:
                raise PreparationError(f"{label} exceeds the {limit}-byte limit")
            chunks: list[bytes] = []
            total = 0
            while True:
                chunk = os.read(descriptor, min(1024 * 1024, limit + 1 - total))
                if not chunk:
                    break
                chunks.append(chunk)
                total += len(chunk)
                if total > limit:
                    raise PreparationError(f"{label} exceeds the {limit}-byte limit")
            return b"".join(chunks)
        finally:
            os.close(descriptor)
    finally:
        os.close(directory_fd)


class _ArtifactRoot:
    def __init__(self, supplied: Path) -> None:
        self.caller_path = Path(os.path.abspath(os.fspath(supplied)))
        try:
            caller_metadata = os.lstat(self.caller_path)
        except OSError as error:
            raise PreparationError("artifact root is unavailable") from error
        if stat.S_ISLNK(caller_metadata.st_mode) or not stat.S_ISDIR(caller_metadata.st_mode):
            raise PreparationError("artifact root must be a caller-supplied real directory")
        try:
            self.fd = os.open(
                self.caller_path,
                os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC,
            )
        except OSError as error:
            raise PreparationError("artifact root cannot be opened safely") from error
        opened = os.fstat(self.fd)
        if (opened.st_dev, opened.st_ino) != (
            caller_metadata.st_dev,
            caller_metadata.st_ino,
        ):
            os.close(self.fd)
            raise PreparationError("artifact root changed while opening")
        self.identity = (opened.st_dev, opened.st_ino)

    def close(self) -> None:
        if self.fd >= 0:
            os.close(self.fd)
            self.fd = -1

    def verify(self) -> None:
        if self.fd < 0:
            raise PreparationError("artifact root is closed")
        opened = os.fstat(self.fd)
        try:
            caller = os.lstat(self.caller_path)
        except OSError as error:
            raise PreparationError("artifact root changed during preparation") from error
        if (
            stat.S_ISLNK(caller.st_mode)
            or not stat.S_ISDIR(caller.st_mode)
            or (opened.st_dev, opened.st_ino) != self.identity
            or (caller.st_dev, caller.st_ino) != self.identity
        ):
            raise PreparationError("artifact root changed during preparation")

    def relative_argument(self, supplied: Path, label: str) -> PurePosixPath:
        absolute = Path(os.path.abspath(os.fspath(supplied)))
        try:
            relative = absolute.relative_to(self.caller_path)
        except ValueError as error:
            raise PreparationError(f"{label} must be inside the artifact root") from error
        return _relative_path(relative.as_posix(), label)


def _entry_exists(directory_fd: int, name: str) -> bool:
    try:
        os.stat(name, dir_fd=directory_fd, follow_symlinks=False)
    except FileNotFoundError:
        return False
    return True


def _open_or_create_directory(parent_fd: int, name: str, label: str) -> int:
    try:
        os.mkdir(name, mode=0o700, dir_fd=parent_fd)
    except FileExistsError:
        pass
    try:
        descriptor = os.open(
            name,
            os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC,
            dir_fd=parent_fd,
        )
    except OSError as error:
        raise PreparationError(f"{label} must be a real directory") from error
    metadata = os.fstat(descriptor)
    if not stat.S_ISDIR(metadata.st_mode):
        os.close(descriptor)
        raise PreparationError(f"{label} must be a real directory")
    return descriptor


def _write_exclusive(directory_fd: int, name: str, data: bytes, mode: int = 0o600) -> None:
    try:
        descriptor = os.open(
            name,
            os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW | os.O_CLOEXEC,
            mode,
            dir_fd=directory_fd,
        )
    except OSError as error:
        raise PreparationError(f"cannot create protected output {name}") from error
    try:
        with os.fdopen(descriptor, "wb", closefd=False) as handle:
            handle.write(data)
            handle.flush()
            os.fsync(handle.fileno())
    finally:
        os.close(descriptor)


def _remove_flat_directory(parent_fd: int, name: str) -> None:
    try:
        descriptor = os.open(
            name,
            os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC,
            dir_fd=parent_fd,
        )
    except OSError:
        return
    try:
        for entry in os.listdir(descriptor):
            try:
                os.unlink(entry, dir_fd=descriptor)
            except OSError:
                pass
    finally:
        os.close(descriptor)
    try:
        os.rmdir(name, dir_fd=parent_fd)
    except OSError:
        pass


def _rename_directory_exclusive(parent_fd: int, source: str, destination: str) -> None:
    libc = ctypes.CDLL(None, use_errno=True)
    function = libc.renameatx_np
    function.argtypes = [ctypes.c_int, ctypes.c_char_p, ctypes.c_int, ctypes.c_char_p, ctypes.c_uint]
    function.restype = ctypes.c_int
    if function(
        parent_fd,
        os.fsencode(source),
        parent_fd,
        os.fsencode(destination),
        0x00000004,
    ) != 0:
        error = ctypes.get_errno()
        raise PreparationError(
            f"cannot install rendering/ground-truth exclusively: {os.strerror(error)}"
        )


def _camera(value: Any, label: str) -> dict[str, Any]:
    camera = _mapping(value, label)
    _exact_keys(camera, {"model", "width", "height", "parameters"}, label)
    model = camera["model"]
    if model not in {"PINHOLE", "SIMPLE_PINHOLE", "SIMPLE_RADIAL"}:
        raise PreparationError(f"{label} uses unsupported camera model {model!r}")
    width = _positive_dimension(camera["width"], f"{label}.width")
    height = _positive_dimension(camera["height"], f"{label}.height")
    if width * height > MAX_PIXELS:
        raise PreparationError(f"{label} exceeds the {MAX_PIXELS:,}-pixel limit")
    parameters = camera["parameters"]
    expected_count = {"PINHOLE": 4, "SIMPLE_PINHOLE": 3, "SIMPLE_RADIAL": 4}[model]
    if not isinstance(parameters, list) or len(parameters) != expected_count:
        raise PreparationError(f"{label}.parameters do not match {model}")
    normalized = [
        _finite_number(parameter, f"{label}.parameters[{index}]")
        for index, parameter in enumerate(parameters)
    ]
    if normalized[0] <= 0 or (model == "PINHOLE" and normalized[1] <= 0):
        raise PreparationError(f"{label} has a non-positive focal length")
    return {"model": model, "width": width, "height": height, "parameters": normalized}


def _pinhole_intrinsics(camera: dict[str, Any]) -> tuple[float, float, float, float]:
    parameters = camera["parameters"]
    if camera["model"] == "PINHOLE":
        return parameters[0], parameters[1], parameters[2], parameters[3]
    return parameters[0], parameters[0], parameters[1], parameters[2]


def _render_camera(value: Any, label: str) -> dict[str, Any]:
    camera = _mapping(value, label)
    _exact_keys(
        camera,
        {
            "width",
            "height",
            "projection_matrix_column_major",
            "world_to_camera_matrix_column_major",
        },
        label,
    )
    width = _positive_dimension(camera["width"], f"{label}.width")
    height = _positive_dimension(camera["height"], f"{label}.height")
    if width * height > MAX_PIXELS:
        raise PreparationError(f"{label} exceeds the {MAX_PIXELS:,}-pixel limit")

    def matrix(field: str) -> list[float]:
        raw = camera[field]
        if not isinstance(raw, list) or len(raw) != 16:
            raise PreparationError(f"{label}.{field} must contain 16 values")
        return [
            _finite_number(item, f"{label}.{field}[{index}]")
            for index, item in enumerate(raw)
        ]

    return {
        "width": width,
        "height": height,
        "projection_matrix_column_major": matrix("projection_matrix_column_major"),
        "world_to_camera_matrix_column_major": matrix(
            "world_to_camera_matrix_column_major"
        ),
    }


def _undistort_scalar(
    xd: numpy.float32,
    yd: numpy.float32,
    coefficients: tuple[numpy.float32, ...],
) -> tuple[numpy.float32, numpy.float32]:
    k1, k2, p1, p2, k3 = coefficients
    xu = numpy.float32(xd)
    yu = numpy.float32(yd)
    one = numpy.float32(1.0)
    two = numpy.float32(2.0)
    for _ in range(INVERSE_ITERATIONS):
        r2 = numpy.float32(xu * xu + yu * yu)
        r4 = numpy.float32(r2 * r2)
        r6 = numpy.float32(r4 * r2)
        radial = numpy.float32(one + k1 * r2 + k2 * r4 + k3 * r6)
        dx = numpy.float32(two * p1 * xu * yu + p2 * (r2 + two * xu * xu))
        dy = numpy.float32(p1 * (r2 + two * yu * yu) + two * p2 * xu * yu)
        xu = numpy.float32((xd - dx) / radial)
        yu = numpy.float32((yd - dy) / radial)
    return xu, yu


def _distortion_parameters(camera: dict[str, Any]) -> tuple[numpy.float32, ...]:
    if camera["model"] != "SIMPLE_RADIAL":
        return tuple(numpy.float32(0.0) for _ in range(5))
    k1 = camera["parameters"][3]
    return (
        numpy.float32(k1),
        numpy.float32(0.0),
        numpy.float32(0.0),
        numpy.float32(0.0),
        numpy.float32(0.0),
    )


def _native_alpha_zero_roi(camera: dict[str, Any]) -> tuple[int, int, int, int]:
    width = camera["width"]
    height = camera["height"]
    fx_raw, fy_raw, cx_raw, cy_raw = _pinhole_intrinsics(camera)
    fx = numpy.float32(fx_raw)
    fy = numpy.float32(fy_raw)
    cx = numpy.float32(cx_raw)
    cy = numpy.float32(cy_raw)
    coefficients = _distortion_parameters(camera)
    top_max = numpy.float32(-1e9)
    bottom_min = numpy.float32(1e9)
    left_max = numpy.float32(-1e9)
    right_min = numpy.float32(1e9)
    denominator = numpy.float32(BOUNDARY_SAMPLES - 1)
    for index in range(BOUNDARY_SAMPLES):
        t = numpy.float32(numpy.float32(index) / denominator)

        xd = numpy.float32((numpy.float32(t * width) - cx) / fx)
        yd = numpy.float32((numpy.float32(0.0) - cy) / fy)
        _, yu = _undistort_scalar(xd, yd, coefficients)
        top_max = numpy.maximum(top_max, numpy.float32(yu * fy + cy))

        xd = numpy.float32((numpy.float32(t * width) - cx) / fx)
        yd = numpy.float32((numpy.float32(height - 1) - cy) / fy)
        _, yu = _undistort_scalar(xd, yd, coefficients)
        bottom_min = numpy.minimum(bottom_min, numpy.float32(yu * fy + cy))

        xd = numpy.float32((numpy.float32(0.0) - cx) / fx)
        yd = numpy.float32((numpy.float32(t * height) - cy) / fy)
        xu, _ = _undistort_scalar(xd, yd, coefficients)
        left_max = numpy.maximum(left_max, numpy.float32(xu * fx + cx))

        xd = numpy.float32((numpy.float32(width - 1) - cx) / fx)
        yd = numpy.float32((numpy.float32(t * height) - cy) / fy)
        xu, _ = _undistort_scalar(xd, yd, coefficients)
        right_min = numpy.minimum(right_min, numpy.float32(xu * fx + cx))

    roi_x = max(0, math.ceil(float(left_max)))
    roi_y = max(0, math.ceil(float(top_max)))
    roi_width = min(width, math.floor(float(right_min))) - roi_x
    roi_height = min(height, math.floor(float(bottom_min))) - roi_y
    if roi_width <= 0 or roi_height <= 0:
        return 0, 0, width, height
    return roi_x, roi_y, roi_width, roi_height


def _native_undistort(
    source_rgb8: numpy.ndarray,
    camera: dict[str, Any],
    roi: tuple[int, int, int, int],
) -> numpy.ndarray:
    height, width, _ = source_rgb8.shape
    fx_raw, fy_raw, cx_raw, cy_raw = _pinhole_intrinsics(camera)
    fx = numpy.float32(fx_raw)
    fy = numpy.float32(fy_raw)
    cx = numpy.float32(cx_raw)
    cy = numpy.float32(cy_raw)
    k1, k2, p1, p2, k3 = _distortion_parameters(camera)
    source = source_rgb8.astype(numpy.float32) / numpy.float32(255.0)
    output = numpy.empty((height, width, 3), dtype=numpy.float32)
    one = numpy.float32(1.0)
    two = numpy.float32(2.0)

    columns = numpy.arange(width, dtype=numpy.float32)[None, :]
    for start in range(0, height, 128):
        stop = min(height, start + 128)
        rows = numpy.arange(start, stop, dtype=numpy.float32)[:, None]
        x = (columns - cx) / fx
        y = (rows - cy) / fy
        r2 = x * x + y * y
        r4 = r2 * r2
        r6 = r4 * r2
        radial = one + k1 * r2 + k2 * r4 + k3 * r6
        distorted_x = x * radial + two * p1 * x * y + p2 * (r2 + two * x * x)
        distorted_y = y * radial + p1 * (r2 + two * y * y) + two * p2 * x * y
        source_x = distorted_x * fx + cx
        source_y = distorted_y * fy + cy
        floor_x = numpy.floor(source_x)
        floor_y = numpy.floor(source_y)
        x0 = numpy.clip(floor_x.astype(numpy.int64), 0, width - 1)
        x1 = numpy.clip(x0 + 1, 0, width - 1)
        y0 = numpy.clip(floor_y.astype(numpy.int64), 0, height - 1)
        y1 = numpy.clip(y0 + 1, 0, height - 1)
        fraction_x = source_x - floor_x
        fraction_y = source_y - floor_y
        p00 = source[y0, x0]
        p10 = source[y0, x1]
        p01 = source[y1, x0]
        p11 = source[y1, x1]
        top = p00 * (one - fraction_x[:, :, None]) + p10 * fraction_x[:, :, None]
        bottom = p01 * (one - fraction_x[:, :, None]) + p11 * fraction_x[:, :, None]
        output[start:stop] = (
            top * (one - fraction_y[:, :, None]) + bottom * fraction_y[:, :, None]
        )

    roi_x, roi_y, roi_width, roi_height = roi
    cropped = output[roi_y : roi_y + roi_height, roi_x : roi_x + roi_width]
    return numpy.clip(cropped * numpy.float32(255.0) + numpy.float32(0.5), 0, 255).astype(
        numpy.uint8
    )


def _target_camera(
    source_camera: dict[str, Any], roi: tuple[int, int, int, int]
) -> dict[str, Any]:
    fx, fy, cx, cy = _pinhole_intrinsics(source_camera)
    roi_x, roi_y, width, height = roi
    return {
        "model": "PINHOLE",
        "width": width,
        "height": height,
        "parameters": [fx, fy, cx - roi_x, cy - roi_y],
    }


def _verify_render_camera(render: dict[str, Any], target: dict[str, Any], label: str) -> None:
    fx, fy, cx, cy = target["parameters"]
    width = target["width"]
    height = target["height"]
    projection = render["projection_matrix_column_major"]
    expected = {
        0: 2.0 * fx / width,
        5: 2.0 * fy / height,
        8: 1.0 - 2.0 * cx / width,
        9: 2.0 * cy / height - 1.0,
    }
    if render["width"] != width or render["height"] != height:
        raise PreparationError(f"{label} dimensions do not match the prepared camera")
    for index, value in expected.items():
        if not math.isclose(projection[index], value, rel_tol=1e-6, abs_tol=1e-6):
            raise PreparationError(f"{label} intrinsics do not match the prepared camera")


def _read_absolute_regular(path: Path, limit: int, label: str) -> tuple[bytes, int]:
    try:
        before = os.lstat(path)
        descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_CLOEXEC)
    except OSError as error:
        raise PreparationError(f"{label} must be a real regular file") from error
    try:
        opened = os.fstat(descriptor)
        if (
            stat.S_ISLNK(before.st_mode)
            or not stat.S_ISREG(before.st_mode)
            or not stat.S_ISREG(opened.st_mode)
            or (before.st_dev, before.st_ino) != (opened.st_dev, opened.st_ino)
            or opened.st_size > limit
        ):
            raise PreparationError(f"{label} must be a bounded real regular file")
        data = bytearray()
        while len(data) <= limit:
            chunk = os.read(descriptor, min(1024 * 1024, limit + 1 - len(data)))
            if not chunk:
                break
            data.extend(chunk)
        if len(data) > limit:
            raise PreparationError(f"{label} exceeds the {limit}-byte limit")
        after = os.fstat(descriptor)
        final = os.lstat(path)
        stable_fields = ("st_dev", "st_ino", "st_size", "st_mtime_ns", "st_ctime_ns")
        if any(getattr(opened, field) != getattr(after, field) for field in stable_fields) or any(
            getattr(opened, field) != getattr(final, field) for field in stable_fields
        ):
            raise PreparationError(f"{label} changed while reading")
        return bytes(data), stat.S_IMODE(opened.st_mode)
    finally:
        os.close(descriptor)


def _trainer_build_digest(executable: bytes, metallib: bytes) -> str:
    digest = hashlib.sha256(b"EasySplat file digest v1")
    for name, data in (("easysplat-train", executable), ("default.metallib", metallib)):
        encoded_name = name.encode("utf-8")
        digest.update(struct.pack(">Q", len(encoded_name)))
        digest.update(encoded_name)
        digest.update(struct.pack(">Q", len(data)))
        digest.update(data)
    return SHA256_PREFIX + digest.hexdigest()


def _native_decoder_identity(value: Any, label: str) -> dict[str, Any]:
    identity = _mapping(value, label)
    _exact_keys(
        identity,
        {
            "contract",
            "mode_version",
            "executable_bytes",
            "executable_sha256",
            "metallib_bytes",
            "metallib_sha256",
            "trainer_build_digest",
            "msplat_source_commit",
        },
        label,
    )
    if identity["contract"] != NATIVE_DECODE_CONTRACT or identity["mode_version"] != 1:
        raise PreparationError(f"{label} contract is unsupported")
    for field in ("executable_sha256", "metallib_sha256", "trainer_build_digest"):
        _digest(identity[field], f"{label}.{field}")
    for field in ("executable_bytes", "metallib_bytes"):
        if type(identity[field]) is not int or identity[field] <= 0:
            raise PreparationError(f"{label}.{field} is invalid")
    if identity["msplat_source_commit"] != MSPLAT_SOURCE_COMMIT:
        raise PreparationError(f"{label}.msplat_source_commit is unsupported")
    return dict(identity)


def _snapshot_native_decoder(
    helper: Path,
    private_root: Path,
    expected: dict[str, Any],
) -> tuple[Path, dict[str, Any]]:
    executable, executable_mode = _read_absolute_regular(
        helper,
        256 * 1024 * 1024,
        "native decoder executable",
    )
    metallib, _ = _read_absolute_regular(
        helper.parent / "default.metallib",
        256 * 1024 * 1024,
        "native decoder metallib",
    )
    actual = {
        "contract": NATIVE_DECODE_CONTRACT,
        "mode_version": 1,
        "executable_bytes": len(executable),
        "executable_sha256": sha256_bytes(executable),
        "metallib_bytes": len(metallib),
        "metallib_sha256": sha256_bytes(metallib),
        "trainer_build_digest": _trainer_build_digest(executable, metallib),
        "msplat_source_commit": MSPLAT_SOURCE_COMMIT,
    }
    if actual != expected:
        raise PreparationError("native decoder identity does not match the protected spec")
    helper_root = private_root / "native-decoder"
    helper_root.mkdir(mode=0o700)
    snapshot = helper_root / "easysplat-train"
    descriptor = os.open(snapshot, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o700)
    with os.fdopen(descriptor, "wb") as handle:
        handle.write(executable)
        handle.flush()
        os.fsync(handle.fileno())
    os.chmod(snapshot, executable_mode | stat.S_IXUSR)
    metallib_path = helper_root / "default.metallib"
    descriptor = os.open(
        metallib_path,
        os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW,
        0o600,
    )
    with os.fdopen(descriptor, "wb") as handle:
        handle.write(metallib)
        handle.flush()
        os.fsync(handle.fileno())
    return snapshot, actual


def _native_decode_source(
    *,
    source_bytes: bytes,
    declared_format: str,
    width: int,
    height: int,
    helper: Path,
    helper_identity: dict[str, Any],
    private_root: Path,
    label: str,
) -> tuple[numpy.ndarray, dict[str, Any]]:
    suffixes = {"png_rgb8": ".png", "jpeg_rgb8": ".jpg"}
    suffix = suffixes.get(declared_format)
    if suffix is None:
        raise PreparationError(f"{label}.format is unsupported")
    if declared_format == "png_rgb8" and not source_bytes.startswith(b"\x89PNG\r\n\x1a\n"):
        raise PreparationError(f"{label} does not match its declared PNG format")
    if declared_format == "jpeg_rgb8" and not (
        source_bytes.startswith(b"\xff\xd8") and source_bytes.endswith(b"\xff\xd9")
    ):
        raise PreparationError(f"{label} does not match its declared JPEG format")

    invocation_root = Path(tempfile.mkdtemp(prefix="decode-", dir=private_root))
    try:
        source = invocation_root / f"source{suffix}"
        output = invocation_root / "decoded.rgb8"
        descriptor = os.open(
            source,
            os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW,
            0o600,
        )
        with os.fdopen(descriptor, "wb") as handle:
            handle.write(source_bytes)
            handle.flush()
            os.fsync(handle.fileno())
        completed = subprocess.run(
            [
                str(helper),
                "--benchmark-decode",
                str(source),
                "--benchmark-decode-output",
                str(output),
            ],
            cwd=invocation_root,
            env={"PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "TMPDIR": str(invocation_root)},
            check=False,
            capture_output=True,
            timeout=60,
        )
        if completed.returncode != 0:
            detail = completed.stderr[:1024].decode("utf-8", errors="replace").strip()
            raise PreparationError(f"{label} native decode failed: {detail or completed.returncode}")
        if completed.stderr:
            raise PreparationError(f"{label} native decoder wrote unexpected stderr")
        if len(completed.stdout) > 64 * 1024:
            raise PreparationError(f"{label} native decoder receipt is too large")
        try:
            receipt = _mapping(json.loads(completed.stdout), f"{label} native decode receipt")
        except (UnicodeDecodeError, json.JSONDecodeError) as error:
            raise PreparationError(f"{label} native decoder receipt is invalid") from error
        expected_fields = {
            "contract",
            "executable_bytes",
            "executable_sha256",
            "height",
            "metallib_bytes",
            "metallib_sha256",
            "mode",
            "mode_version",
            "msplat_source_commit",
            "output_bytes",
            "output_sha256",
            "pixel_sha256",
            "schema_version",
            "source_bytes",
            "source_sha256",
            "status",
            "trainer_build_digest",
            "width",
        }
        _exact_keys(receipt, expected_fields, f"{label} native decode receipt")
        fixed = {
            "contract": NATIVE_DECODE_CONTRACT,
            "mode": "benchmark_decode",
            "mode_version": 1,
            "msplat_source_commit": MSPLAT_SOURCE_COMMIT,
            "schema_version": 1,
            "source_bytes": len(source_bytes),
            "source_sha256": sha256_bytes(source_bytes),
            "status": "completed",
            "width": width,
            "height": height,
        }
        if any(receipt.get(field) != value for field, value in fixed.items()) or any(
            receipt.get(field) != helper_identity[field]
            for field in (
                "executable_bytes",
                "executable_sha256",
                "metallib_bytes",
                "metallib_sha256",
                "trainer_build_digest",
            )
        ):
            raise PreparationError(f"{label} native decoder receipt does not match its identity")
        expected_bytes = width * height * 3
        if receipt["output_bytes"] != expected_bytes or receipt["pixel_sha256"] != receipt[
            "output_sha256"
        ]:
            raise PreparationError(f"{label} native decoder output dimensions are inconsistent")
        decoded, _ = _read_absolute_regular(
            output,
            expected_bytes,
            f"{label} native decoder output",
        )
        if len(decoded) != expected_bytes or sha256_bytes(decoded) != receipt["output_sha256"]:
            raise PreparationError(f"{label} native decoder output does not match its receipt")
        pixels = numpy.frombuffer(decoded, dtype=numpy.uint8).reshape((height, width, 3)).copy()
        return pixels, {
            "receipt_sha256": sha256_bytes(canonical_json_bytes(receipt)[:-1]),
            "pixel_sha256": receipt["pixel_sha256"],
        }
    except subprocess.TimeoutExpired as error:
        raise PreparationError(f"{label} native decoder timed out") from error
    finally:
        shutil.rmtree(invocation_root, ignore_errors=True)


def _encode_png(pixels: numpy.ndarray) -> bytes:
    buffer = io.BytesIO()
    Image.fromarray(pixels, mode="RGB").save(
        buffer,
        format="PNG",
        optimize=False,
        compress_level=9,
    )
    return buffer.getvalue()


def _prepare_view(
    raw: Any,
    position: int,
    artifact_root_fd: int,
    staging_root_fd: int,
    native_helper: Path,
    native_helper_identity: dict[str, Any],
    private_root: Path,
) -> dict[str, Any]:
    label = f"views[{position}]"
    view = _mapping(raw, label)
    _exact_keys(
        view,
        {"holdout_index", "source", "source_camera", "render_camera", "target_path"},
        label,
    )
    holdout_index = view["holdout_index"]
    if type(holdout_index) is not int or holdout_index < 0:
        raise PreparationError(f"{label}.holdout_index is invalid")
    source = _mapping(view["source"], f"{label}.source")
    _exact_keys(source, {"path", "sha256", "format", "width", "height"}, f"{label}.source")
    source_path = _relative_path(source["path"], f"{label}.source.path")
    source_digest = _digest(source["sha256"], f"{label}.source.sha256")
    source_width = _positive_dimension(source["width"], f"{label}.source.width")
    source_height = _positive_dimension(source["height"], f"{label}.source.height")
    if source_width * source_height > MAX_PIXELS:
        raise PreparationError(f"{label}.source exceeds the {MAX_PIXELS:,}-pixel limit")
    source_bytes = _read_relative_regular(
        artifact_root_fd,
        source_path,
        MAX_SOURCE_BYTES,
        f"{label}.source",
    )
    if sha256_bytes(source_bytes) != source_digest:
        raise PreparationError(f"{label}.source digest does not match")
    pixels, native_decode = _native_decode_source(
        source_bytes=source_bytes,
        declared_format=source["format"],
        width=source_width,
        height=source_height,
        helper=native_helper,
        helper_identity=native_helper_identity,
        private_root=private_root,
        label=f"{label}.source",
    )
    source_camera = _camera(view["source_camera"], f"{label}.source_camera")
    if source_camera["width"] != source_width or source_camera["height"] != source_height:
        raise PreparationError(f"{label}.source camera dimensions do not match the source image")
    render = _render_camera(view["render_camera"], f"{label}.render_camera")
    target_path = _relative_path(view["target_path"], f"{label}.target_path")
    if target_path.parent != PurePosixPath("rendering/ground-truth"):
        raise PreparationError(f"{label}.target_path must be inside rendering/ground-truth")
    if target_path.suffix.lower() != ".png":
        raise PreparationError(f"{label}.target_path must name a PNG")

    distortion = _distortion_parameters(source_camera)
    has_float32_distortion = any(
        struct.unpack(">I", struct.pack(">f", float(value)))[0] & 0x7FFF_FFFF != 0
        for value in distortion
    )
    if source_camera["model"] == "SIMPLE_RADIAL" and has_float32_distortion:
        roi = _native_alpha_zero_roi(source_camera)
        target_pixels = _native_undistort(pixels, source_camera, roi)
        transform_kind = "brown_conrady_alpha0"
    else:
        roi = (0, 0, source_width, source_height)
        target_pixels = pixels.copy()
        transform_kind = "identity"
    target_camera = _target_camera(source_camera, roi)
    _verify_render_camera(render, target_camera, f"{label}.render_camera")
    target_bytes = _encode_png(target_pixels)
    _write_exclusive(staging_root_fd, target_path.name, target_bytes)
    source_record = {
        "path": source_path.as_posix(),
        "sha256": source_digest,
        "pixel_sha256": sha256_bytes(pixels.tobytes(order="C")),
        "format": source["format"],
        "width": source_width,
        "height": source_height,
        "native_decode_receipt_sha256": native_decode["receipt_sha256"],
        "native_decoded_rgb8_sha256": native_decode["pixel_sha256"],
    }
    target_record = {
        "path": target_path.as_posix(),
        "sha256": sha256_bytes(target_bytes),
        "pixel_sha256": sha256_bytes(target_pixels.tobytes(order="C")),
        "format": "png_rgb8",
        "width": target_camera["width"],
        "height": target_camera["height"],
    }
    record = {
        "holdout_index": holdout_index,
        "source": source_record,
        "source_camera": source_camera,
        "transform": {"kind": transform_kind, "roi": list(roi)},
        "target": target_record,
        "target_camera": target_camera,
        "render_camera_digest": render_camera_digest(render),
    }
    record["preparation_view_sha256"] = sha256_bytes(canonical_json_bytes(record)[:-1])
    return record


def prepare_targets(
    spec_path: Path,
    artifact_root: Path,
    output_path: Path,
    native_helper_path: Path,
) -> dict[str, Any]:
    root = _ArtifactRoot(artifact_root)
    rendering_fd = -1
    staging_fd = -1
    staging_name = ""
    target_installed = False
    receipt_installed = False
    receipt_temporary = ""
    try:
        expected_output = root.caller_path / "ground-truth-preparation.json"
        supplied_output = Path(os.path.abspath(os.fspath(output_path)))
        if supplied_output != expected_output:
            raise PreparationError("output must be the canonical ground-truth-preparation.json path")
        if _entry_exists(root.fd, expected_output.name):
            raise PreparationError("ground-truth-preparation.json already exists")

        spec_relative = root.relative_argument(spec_path, "spec")
        spec_bytes = _read_relative_regular(root.fd, spec_relative, MAX_SPEC_BYTES, "spec")
        try:
            spec = _mapping(json.loads(spec_bytes), "spec")
        except (UnicodeDecodeError, json.JSONDecodeError) as error:
            raise PreparationError("spec is not valid UTF-8 JSON") from error
        _exact_keys(
            spec,
            {
                "schema_version",
                "input_digest",
                "selection_manifest",
                "producer",
                "native_decoder",
                "runtime",
                "views",
            },
            "spec",
        )
        if spec["schema_version"] != 2:
            raise PreparationError("spec schema_version must be 2")
        input_digest = _digest(spec["input_digest"], "spec.input_digest")

        selection = _mapping(spec["selection_manifest"], "spec.selection_manifest")
        _exact_keys(selection, {"path", "sha256"}, "spec.selection_manifest")
        selection_path = _relative_path(selection["path"], "spec.selection_manifest.path")
        selection_sha256 = _digest(selection["sha256"], "spec.selection_manifest.sha256")
        selection_bytes = _read_relative_regular(
            root.fd,
            selection_path,
            MAX_SPEC_BYTES,
            "selection manifest",
        )
        if sha256_bytes(selection_bytes) != selection_sha256:
            raise PreparationError("selection manifest does not match the protected spec")

        producer = _mapping(spec["producer"], "spec.producer")
        _exact_keys(producer, {"path", "sha256"}, "spec.producer")
        preparer_path = "scripts/benchmark/prepare_render_targets.py"
        preparer_bytes, _ = _read_absolute_regular(
            Path(__file__),
            MAX_SPEC_BYTES,
            "ground-truth preparer implementation",
        )
        preparer_sha256 = sha256_bytes(preparer_bytes)
        if producer != {"path": preparer_path, "sha256": preparer_sha256}:
            raise PreparationError("spec producer does not match the running preparer")

        runtime = _mapping(spec["runtime"], "spec.runtime")
        _exact_keys(
            runtime,
            {"implementation", "python_version", "numpy_version", "pillow_version"},
            "spec.runtime",
        )
        actual_runtime = {
            "implementation": platform.python_implementation().lower(),
            "python_version": platform.python_version(),
            "numpy_version": numpy.__version__,
            "pillow_version": Image.__version__,
        }
        if runtime != actual_runtime:
            raise PreparationError("spec runtime does not match the locked preparation runtime")

        native_decoder = _native_decoder_identity(spec["native_decoder"], "spec.native_decoder")
        views = spec["views"]
        if not isinstance(views, list) or not views:
            raise PreparationError("spec.views must be a non-empty array")

        rendering_fd = _open_or_create_directory(root.fd, "rendering", "rendering")
        if _entry_exists(rendering_fd, "ground-truth"):
            raise PreparationError("rendering/ground-truth already exists")
        staging_name = ".ground-truth-preparation-" + os.urandom(12).hex()
        os.mkdir(staging_name, mode=0o700, dir_fd=rendering_fd)
        staging_fd = os.open(
            staging_name,
            os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC,
            dir_fd=rendering_fd,
        )

        with tempfile.TemporaryDirectory(prefix="easysplat-render-targets-") as temporary:
            private_root = Path(temporary)
            if private_root.is_symlink() or not private_root.is_dir():
                raise PreparationError("private native-decoder workspace is unsafe")
            os.chmod(private_root, 0o700)
            native_helper, actual_native_decoder = _snapshot_native_decoder(
                native_helper_path,
                private_root,
                native_decoder,
            )
            records = [
                _prepare_view(
                    view,
                    position,
                    root.fd,
                    staging_fd,
                    native_helper,
                    actual_native_decoder,
                    private_root,
                )
                for position, view in enumerate(views)
            ]

        holdouts = [record["holdout_index"] for record in records]
        target_paths = [record["target"]["path"] for record in records]
        if holdouts != sorted(holdouts) or len(set(holdouts)) != len(holdouts):
            raise PreparationError("spec views must use sorted unique holdout indices")
        if len(set(target_paths)) != len(target_paths):
            raise PreparationError("spec target paths must be unique")

        if _read_relative_regular(root.fd, spec_relative, MAX_SPEC_BYTES, "spec") != spec_bytes:
            raise PreparationError("spec changed during preparation")
        if _read_relative_regular(
            root.fd,
            selection_path,
            MAX_SPEC_BYTES,
            "selection manifest",
        ) != selection_bytes:
            raise PreparationError("selection manifest changed during preparation")
        for position, record in enumerate(records):
            source_path = _relative_path(record["source"]["path"], f"views[{position}].source.path")
            source_bytes = _read_relative_regular(
                root.fd,
                source_path,
                MAX_SOURCE_BYTES,
                f"views[{position}].source",
            )
            if sha256_bytes(source_bytes) != record["source"]["sha256"]:
                raise PreparationError(f"views[{position}].source changed during preparation")
        root.verify()

        receipt = {
            "schema_version": 2,
            "input_digest": input_digest,
            "selection_manifest": {
                "path": selection_path.as_posix(),
                "sha256": selection_sha256,
            },
            "source_spec": {
                "path": spec_relative.as_posix(),
                "sha256": sha256_bytes(spec_bytes),
            },
            "algorithm": {
                "id": "native_msplat_decode_brown_conrady_alpha0",
                "version": 2,
                "float_precision": "float32",
                "inverse_iterations": INVERSE_ITERATIONS,
                "boundary_samples": BOUNDARY_SAMPLES,
                "interpolation": "bilinear",
                "boundary_mode": "clamp",
            },
            "producer": {
                "path": preparer_path,
                "sha256": preparer_sha256,
                "runtime": actual_runtime,
            },
            "native_decoder": native_decoder,
            "views": records,
        }
        receipt_bytes = canonical_json_bytes(receipt)

        os.close(staging_fd)
        staging_fd = -1
        _rename_directory_exclusive(rendering_fd, staging_name, "ground-truth")
        staging_name = ""
        target_installed = True
        os.fsync(rendering_fd)
        root.verify()

        receipt_temporary = ".ground-truth-preparation-" + os.urandom(12).hex() + ".json"
        _write_exclusive(root.fd, receipt_temporary, receipt_bytes)
        try:
            os.link(
                receipt_temporary,
                expected_output.name,
                src_dir_fd=root.fd,
                dst_dir_fd=root.fd,
                follow_symlinks=False,
            )
        except OSError as error:
            raise PreparationError("cannot publish ground-truth preparation receipt") from error
        receipt_installed = True
        os.unlink(receipt_temporary, dir_fd=root.fd)
        receipt_temporary = ""
        os.fsync(root.fd)
        root.verify()
        return receipt
    except BaseException:
        if receipt_temporary:
            try:
                os.unlink(receipt_temporary, dir_fd=root.fd)
            except OSError:
                pass
        if target_installed and rendering_fd >= 0:
            _remove_flat_directory(rendering_fd, "ground-truth")
        elif staging_name and rendering_fd >= 0:
            _remove_flat_directory(rendering_fd, staging_name)
        if receipt_installed:
            try:
                os.unlink("ground-truth-preparation.json", dir_fd=root.fd)
            except OSError:
                pass
        raise
    finally:
        if staging_fd >= 0:
            os.close(staging_fd)
        if rendering_fd >= 0:
            os.close(rendering_fd)
        root.close()


def _parse_arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--artifact-root", type=Path, required=True)
    parser.add_argument("--spec", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--native-helper", type=Path, required=True)
    return parser.parse_args()


def main() -> int:
    arguments = _parse_arguments()
    try:
        prepare_targets(
            arguments.spec,
            arguments.artifact_root,
            arguments.output,
            arguments.native_helper,
        )
    except (PreparationError, OSError) as error:
        print(f"prepare_render_targets: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
