#!/usr/bin/env python3
"""Create and authenticate development-only mapper-cadence requests."""

from __future__ import annotations

import argparse
import errno
import hashlib
import json
import math
import os
import re
import secrets
import stat
import struct
import sys
from pathlib import Path, PurePosixPath
from typing import Any, Iterable, Mapping, NoReturn, Sequence

try:
    from scripts.benchmark import easysplat_benchmark as benchmark
    from scripts.benchmark import measurement_runner_closure
except ModuleNotFoundError:
    import easysplat_benchmark as benchmark
    import measurement_runner_closure


SCHEMA_VERSION = 1
EVIDENCE_CLASS = "development_only"
REQUEST_KIND = "mapper_cadence_ab"
TOOLCHAIN_PROVENANCE = "local_adhoc_unsigned"
SOURCE_PROVENANCE_SCOPE = "binary_only_dirty_worktree"
INPUT_DIGEST_ALGORITHM = "easysplat-benchmark-input-v1"
MAXIMUM_CONTROL_BYTES = 16 * 1024 * 1024
MAXIMUM_ADAPTER_BYTES = 512 * 1024 * 1024
SAFE_TOKEN = re.compile(r"^[a-z0-9][a-z0-9_-]{0,127}$")
SHA256 = re.compile(r"^[0-9a-f]{64}$")
PREFIXED_SHA256 = re.compile(r"^sha256:[0-9a-f]{64}$")
GIT_COMMIT = re.compile(r"^[0-9a-f]{40}$")
SUPPORTED_VIDEO_EXTENSIONS = {".m4v", ".mov", ".mp4"}
SUPPORTED_INPUT_KINDS = {"video", "multi_video"}
ALLOWED_CATEGORIES = {
    "object_orbit",
    "interior_walkthrough",
    "professional_photos",
    "large_area_exterior",
    "low_light",
    "invalid",
}
COLMAP_RUNTIME_COMPONENT_PATHS = ("bin/colmap", "lib/libomp.dylib")

WARMUP = {
    "ordinal": 0,
    "name": "mapper-cadence-warmup-1p4",
    "mapper_cadence": "balanced-global",
    "ratio": 1.4,
    "discarded": True,
}
MEASURED_SCHEDULE = (
    {
        "ordinal": 1,
        "name": "mapper-cadence-01-1p1",
        "mapper_cadence": "frequent-global",
        "ratio": 1.1,
        "discarded": False,
    },
    {
        "ordinal": 2,
        "name": "mapper-cadence-02-1p4",
        "mapper_cadence": "balanced-global",
        "ratio": 1.4,
        "discarded": False,
    },
    {
        "ordinal": 3,
        "name": "mapper-cadence-03-1p4",
        "mapper_cadence": "balanced-global",
        "ratio": 1.4,
        "discarded": False,
    },
    {
        "ordinal": 4,
        "name": "mapper-cadence-04-1p1",
        "mapper_cadence": "frequent-global",
        "ratio": 1.1,
        "discarded": False,
    },
    {
        "ordinal": 5,
        "name": "mapper-cadence-05-1p1",
        "mapper_cadence": "frequent-global",
        "ratio": 1.1,
        "discarded": False,
    },
    {
        "ordinal": 6,
        "name": "mapper-cadence-06-1p4",
        "mapper_cadence": "balanced-global",
        "ratio": 1.4,
        "discarded": False,
    },
    {
        "ordinal": 7,
        "name": "mapper-cadence-07-1p4",
        "mapper_cadence": "balanced-global",
        "ratio": 1.4,
        "discarded": False,
    },
    {
        "ordinal": 8,
        "name": "mapper-cadence-08-1p1",
        "mapper_cadence": "frequent-global",
        "ratio": 1.1,
        "discarded": False,
    },
)
QUALITY_THRESHOLDS = {
    "maximum_within_arm_mapping_elapsed_range_seconds": 30.0,
    "maximum_registered_view_loss": 2,
    "maximum_registered_view_loss_fraction": 0.01,
    "maximum_point_count_loss_fraction": 0.01,
    "maximum_observation_count_loss_fraction": 0.01,
    "maximum_median_residual_regression_pixels": 0.05,
    "maximum_p90_residual_regression_pixels": 0.10,
    "maximum_median_residual_pixels": 1.5,
    "maximum_p90_residual_pixels": 3.0,
    "maximum_camera_center_p95_scene_radius_fraction": 0.01,
    "maximum_rotation_p95_degrees": 0.20,
}

CANDIDATE_CONFIGURATION_KEYS = {
    "detail_profile",
    "selected_frame_count",
    "capture_path",
    "input_topology",
    "camera_grouping",
    "lens_projection",
    "resource_policy",
    "compute_policy",
    "pairing_policy",
    "temporal_pairing",
    "temporal_offsets",
    "vocabulary_candidate_count",
    "vocabulary_returned_neighbor_count",
    "vocabulary_query_stride",
    "descriptor_matcher",
    "ba_global_frames_ratio",
    "ba_global_points_ratio",
    "ba_global_max_refinements",
    "ba_local_max_refinements",
    "ba_local_max_num_iterations",
    "ba_local_function_tolerance",
    "ba_global_function_tolerance",
    "ba_local_num_images",
    "trainer_iterations",
    "trainer_plateau_window",
    "feature_extraction_workers",
    "coupled_matching_workers",
    "vocabulary_retrieval_workers",
    "maximum_concurrent_video_source_analysis_tasks",
    "run_seed",
}
FIXED_MAPPER_OPTION_KEYS = {
    "local_max_refinements",
    "global_max_refinements",
    "global_max_num_iterations",
    "local_max_num_iterations",
    "local_function_tolerance",
    "global_function_tolerance",
    "local_image_count",
    "random_seed",
    "refine_focal_length",
    "minimum_pair_inlier_count",
}


class MapperCadenceRequestError(ValueError):
    """A development request is unsafe, malformed, or no longer bound."""


def _reject_constant(value: str) -> NoReturn:
    raise MapperCadenceRequestError(f"JSON contains non-finite constant {value}")


def _reject_duplicate_keys(pairs: Iterable[tuple[str, Any]]) -> dict[str, Any]:
    result: dict[str, Any] = {}
    for key, value in pairs:
        if key in result:
            raise MapperCadenceRequestError(f"JSON contains duplicate key {key!r}")
        result[key] = value
    return result


def _require_finite_numbers(value: Any, label: str = "value") -> None:
    if isinstance(value, float) and not math.isfinite(value):
        raise MapperCadenceRequestError(f"{label} contains a non-finite number")
    if isinstance(value, Mapping):
        for key, item in value.items():
            if not isinstance(key, str):
                raise MapperCadenceRequestError(f"{label} contains a non-string key")
            _require_finite_numbers(item, f"{label}.{key}")
    elif isinstance(value, (list, tuple)):
        for index, item in enumerate(value):
            _require_finite_numbers(item, f"{label}[{index}]")


def canonical_json_bytes(value: Any) -> bytes:
    _require_finite_numbers(value)
    try:
        return json.dumps(
            value,
            sort_keys=True,
            separators=(",", ":"),
            ensure_ascii=False,
            allow_nan=False,
        ).encode("utf-8")
    except (TypeError, ValueError, RecursionError) as error:
        raise MapperCadenceRequestError("value cannot be encoded as canonical JSON") from error


def sha256_canonical(value: Any) -> str:
    return hashlib.sha256(canonical_json_bytes(value)).hexdigest()


def fixed_mapper_options_sha256(value: Mapping[str, Any]) -> str:
    options = _validate_fixed_mapper_option_shape(value)
    hasher = hashlib.sha256()
    domain = b"easysplat-mapper-fixed-options-v1"
    hasher.update(len(domain).to_bytes(8, "big"))
    hasher.update(domain)
    for field in (
        "local_max_refinements",
        "global_max_refinements",
        "global_max_num_iterations",
        "local_max_num_iterations",
    ):
        hasher.update(struct.pack(">q", options[field]))
    for field in ("local_function_tolerance", "global_function_tolerance"):
        hasher.update(struct.pack(">d", float(options[field])))
    hasher.update(struct.pack(">q", options["local_image_count"]))
    hasher.update(struct.pack(">i", options["random_seed"]))
    hasher.update(b"\x01" if options["refine_focal_length"] else b"\x00")
    hasher.update(struct.pack(">q", options["minimum_pair_inlier_count"]))
    return hasher.hexdigest()


def _exact_keys(value: Mapping[str, Any], expected: Iterable[str], label: str) -> None:
    expected_set = set(expected)
    actual = set(value)
    if actual == expected_set:
        return
    details = []
    missing = sorted(expected_set - actual)
    unknown = sorted(actual - expected_set)
    if missing:
        details.append("missing " + ", ".join(missing))
    if unknown:
        details.append("unknown " + ", ".join(unknown))
    raise MapperCadenceRequestError(f"{label} has invalid fields: {'; '.join(details)}")


def _mapping(value: Any, label: str) -> dict[str, Any]:
    if not isinstance(value, dict):
        raise MapperCadenceRequestError(f"{label} must be an object")
    if any(not isinstance(key, str) for key in value):
        raise MapperCadenceRequestError(f"{label} keys must be strings")
    return value


def _string(value: Any, label: str) -> str:
    if not isinstance(value, str) or not value:
        raise MapperCadenceRequestError(f"{label} must be a nonempty string")
    return value


def _integer(
    value: Any,
    label: str,
    *,
    minimum: int | None = None,
    maximum: int | None = None,
) -> int:
    if type(value) is not int:
        raise MapperCadenceRequestError(f"{label} must be an integer")
    if minimum is not None and value < minimum:
        raise MapperCadenceRequestError(f"{label} must be at least {minimum}")
    if maximum is not None and value > maximum:
        raise MapperCadenceRequestError(f"{label} must be at most {maximum}")
    return value


def _number(
    value: Any,
    label: str,
    *,
    minimum: float | None = None,
    positive: bool = False,
) -> float:
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        raise MapperCadenceRequestError(f"{label} must be numeric")
    result = float(value)
    if not math.isfinite(result):
        raise MapperCadenceRequestError(f"{label} must be finite")
    if positive and result <= 0:
        raise MapperCadenceRequestError(f"{label} must be positive")
    if minimum is not None and result < minimum:
        raise MapperCadenceRequestError(f"{label} must be at least {minimum}")
    return result


def _boolean(value: Any, label: str) -> bool:
    if type(value) is not bool:
        raise MapperCadenceRequestError(f"{label} must be a boolean")
    return value


def _sha256(value: Any, label: str) -> str:
    result = _string(value, label)
    if SHA256.fullmatch(result) is None:
        raise MapperCadenceRequestError(f"{label} must be a lowercase SHA-256 digest")
    return result


def _prefixed_sha256(value: Any, label: str) -> str:
    result = _string(value, label)
    if PREFIXED_SHA256.fullmatch(result) is None:
        raise MapperCadenceRequestError(
            f"{label} must be a lowercase sha256:-prefixed digest"
        )
    return result


def _absolute_normalized(path: Path, label: str) -> Path:
    result = Path(path)
    if not result.is_absolute() or result != Path(os.path.abspath(result)):
        raise MapperCadenceRequestError(f"{label} must be a normalized absolute path")
    return result


def _owned_metadata(
    path: Path,
    label: str,
    *,
    regular: bool = False,
    directory: bool = False,
    executable: bool = False,
    single_link: bool = False,
) -> os.stat_result:
    path = _absolute_normalized(path, label)
    try:
        metadata = path.lstat()
    except OSError as error:
        raise MapperCadenceRequestError(f"{label} is unavailable") from error
    if stat.S_ISLNK(metadata.st_mode):
        raise MapperCadenceRequestError(f"{label} must not be a symbolic link")
    if metadata.st_uid != os.getuid():
        raise MapperCadenceRequestError(f"{label} must be owned by the current user")
    if regular and not stat.S_ISREG(metadata.st_mode):
        raise MapperCadenceRequestError(f"{label} must be a regular file")
    if directory and not stat.S_ISDIR(metadata.st_mode):
        raise MapperCadenceRequestError(f"{label} must be a directory")
    if single_link and metadata.st_nlink != 1:
        raise MapperCadenceRequestError(f"{label} must have exactly one hard link")
    if executable and not os.access(path, os.X_OK):
        raise MapperCadenceRequestError(f"{label} must be executable")
    return metadata


def _open_owned_directory(path: Path, label: str) -> int:
    before = _owned_metadata(path, label, directory=True)
    flags = os.O_RDONLY | getattr(os, "O_DIRECTORY", 0) | getattr(os, "O_NOFOLLOW", 0)
    try:
        descriptor = os.open(path, flags)
    except OSError as error:
        raise MapperCadenceRequestError(f"unable to open {label}") from error
    opened = os.fstat(descriptor)
    if (
        not stat.S_ISDIR(opened.st_mode)
        or opened.st_uid != os.getuid()
        or (opened.st_dev, opened.st_ino) != (before.st_dev, before.st_ino)
    ):
        os.close(descriptor)
        raise MapperCadenceRequestError(f"{label} changed while opening")
    return descriptor


def _open_owned_child_directory(parent_descriptor: int, name: str, label: str) -> int:
    flags = os.O_RDONLY | getattr(os, "O_DIRECTORY", 0) | getattr(os, "O_NOFOLLOW", 0)
    try:
        descriptor = os.open(name, flags, dir_fd=parent_descriptor)
    except OSError as error:
        raise MapperCadenceRequestError(
            f"{label} must be an owned directory and not a symbolic link"
        ) from error
    metadata = os.fstat(descriptor)
    if not stat.S_ISDIR(metadata.st_mode) or metadata.st_uid != os.getuid():
        os.close(descriptor)
        raise MapperCadenceRequestError(f"{label} must be owned by the current user")
    return descriptor


def _stable_file_measurement_at(
    parent_descriptor: int,
    name: str,
    label: str,
    *,
    maximum_bytes: int | None = None,
    executable: bool = False,
) -> tuple[int, str]:
    try:
        before = os.stat(name, dir_fd=parent_descriptor, follow_symlinks=False)
    except OSError as error:
        raise MapperCadenceRequestError(f"{label} is unavailable") from error
    if (
        not stat.S_ISREG(before.st_mode)
        or before.st_nlink != 1
        or before.st_uid != os.getuid()
    ):
        raise MapperCadenceRequestError(
            f"{label} must be an owned single-link regular file"
        )
    if executable and not before.st_mode & stat.S_IXUSR:
        raise MapperCadenceRequestError(f"{label} must be executable")
    if before.st_size < 0 or (
        maximum_bytes is not None and before.st_size > maximum_bytes
    ):
        raise MapperCadenceRequestError(f"{label} has an invalid size")
    try:
        descriptor = os.open(
            name,
            os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0),
            dir_fd=parent_descriptor,
        )
        try:
            opened = os.fstat(descriptor)
            if (opened.st_dev, opened.st_ino) != (before.st_dev, before.st_ino):
                raise MapperCadenceRequestError(f"{label} changed while opening")
            digest = hashlib.sha256()
            byte_count = 0
            while chunk := os.read(descriptor, 1024 * 1024):
                digest.update(chunk)
                byte_count += len(chunk)
            after = os.fstat(descriptor)
        finally:
            os.close(descriptor)
    except MapperCadenceRequestError:
        raise
    except OSError as error:
        raise MapperCadenceRequestError(f"unable to read {label}") from error
    stable_fields = (
        "st_dev",
        "st_ino",
        "st_mode",
        "st_nlink",
        "st_uid",
        "st_gid",
        "st_size",
        "st_mtime_ns",
        "st_ctime_ns",
    )
    if byte_count != before.st_size or any(
        getattr(before, field) != getattr(opened, field)
        or getattr(opened, field) != getattr(after, field)
        for field in stable_fields
    ):
        raise MapperCadenceRequestError(f"{label} changed while it was hashed")
    return byte_count, digest.hexdigest()


def _stable_file_measurement(
    path: Path,
    label: str,
    *,
    maximum_bytes: int | None = None,
    executable: bool = False,
    content_hasher: Any | None = None,
    include_size_in_content_hasher: bool = False,
) -> tuple[int, str]:
    before = _owned_metadata(
        path,
        label,
        regular=True,
        executable=executable,
        single_link=True,
    )
    if before.st_size < 0 or (
        maximum_bytes is not None and before.st_size > maximum_bytes
    ):
        raise MapperCadenceRequestError(f"{label} has an invalid size")
    if content_hasher is not None and include_size_in_content_hasher:
        content_hasher.update(before.st_size.to_bytes(8, "big"))
    flags = os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0)
    try:
        descriptor = os.open(path, flags)
        try:
            opened = os.fstat(descriptor)
            if (opened.st_dev, opened.st_ino) != (before.st_dev, before.st_ino):
                raise MapperCadenceRequestError(f"{label} changed while opening")
            digest = hashlib.sha256()
            bytes_read = 0
            while chunk := os.read(descriptor, 1024 * 1024):
                digest.update(chunk)
                if content_hasher is not None:
                    content_hasher.update(chunk)
                bytes_read += len(chunk)
            after = os.fstat(descriptor)
        finally:
            os.close(descriptor)
    except MapperCadenceRequestError:
        raise
    except OSError as error:
        raise MapperCadenceRequestError(f"unable to read {label}") from error
    stable_fields = (
        "st_dev",
        "st_ino",
        "st_mode",
        "st_nlink",
        "st_uid",
        "st_gid",
        "st_size",
        "st_mtime_ns",
        "st_ctime_ns",
    )
    if bytes_read != before.st_size or any(
        getattr(before, field) != getattr(opened, field)
        or getattr(opened, field) != getattr(after, field)
        for field in stable_fields
    ):
        raise MapperCadenceRequestError(f"{label} changed while it was hashed")
    return bytes_read, digest.hexdigest()


def sha256_file(path: Path) -> str:
    return _stable_file_measurement(path, "file", maximum_bytes=None)[1]


def _read_control_bytes(
    path: Path,
    label: str,
    *,
    private: bool = False,
) -> bytes:
    before = _owned_metadata(path, label, regular=True, single_link=True)
    if not 0 < before.st_size <= MAXIMUM_CONTROL_BYTES:
        raise MapperCadenceRequestError(f"{label} has an invalid size")
    if private and stat.S_IMODE(before.st_mode) != 0o600:
        raise MapperCadenceRequestError(f"{label} must have mode 0600")
    flags = os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0)
    try:
        descriptor = os.open(path, flags)
        try:
            opened = os.fstat(descriptor)
            if (opened.st_dev, opened.st_ino) != (before.st_dev, before.st_ino):
                raise MapperCadenceRequestError(f"{label} changed while opening")
            chunks: list[bytes] = []
            remaining = MAXIMUM_CONTROL_BYTES + 1
            while remaining > 0:
                chunk = os.read(descriptor, min(1024 * 1024, remaining))
                if not chunk:
                    break
                chunks.append(chunk)
                remaining -= len(chunk)
            after = os.fstat(descriptor)
        finally:
            os.close(descriptor)
    except MapperCadenceRequestError:
        raise
    except OSError as error:
        raise MapperCadenceRequestError(f"unable to read {label}") from error
    data = b"".join(chunks)
    stable_fields = (
        "st_dev",
        "st_ino",
        "st_mode",
        "st_nlink",
        "st_uid",
        "st_gid",
        "st_size",
        "st_mtime_ns",
        "st_ctime_ns",
    )
    if len(data) != before.st_size or any(
        getattr(before, field) != getattr(opened, field)
        or getattr(opened, field) != getattr(after, field)
        for field in stable_fields
    ):
        raise MapperCadenceRequestError(f"{label} changed while it was read")
    return data


def _load_json_mapping(
    path: Path,
    label: str,
    *,
    private: bool = False,
) -> dict[str, Any]:
    data = _read_control_bytes(path, label, private=private)
    return _decode_json_mapping(data, label)


def _decode_json_mapping(data: bytes, label: str) -> dict[str, Any]:
    try:
        value = json.loads(
            data.decode("utf-8"),
            object_pairs_hook=_reject_duplicate_keys,
            parse_constant=_reject_constant,
        )
    except MapperCadenceRequestError:
        raise
    except (UnicodeError, ValueError, RecursionError) as error:
        raise MapperCadenceRequestError(f"{label} is not strict JSON") from error
    _require_finite_numbers(value, label)
    if data != canonical_json_bytes(value) + b"\n":
        raise MapperCadenceRequestError(f"{label} must be canonical JSON")
    return _mapping(value, label)


def _safe_tree_files(root: Path) -> list[tuple[str, Path]]:
    root_metadata = _owned_metadata(root, "input", directory=True)
    if not stat.S_ISDIR(root_metadata.st_mode):
        raise MapperCadenceRequestError("input must be a directory")
    entries: list[tuple[str, Path]] = []
    try:
        candidates = sorted(
            root.rglob("*"), key=lambda item: item.relative_to(root).as_posix()
        )
    except OSError as error:
        raise MapperCadenceRequestError("unable to inventory input") from error
    for candidate in candidates:
        relative = candidate.relative_to(root).as_posix()
        metadata = _owned_metadata(candidate, f"input entry {relative}")
        if stat.S_ISDIR(metadata.st_mode):
            continue
        if not stat.S_ISREG(metadata.st_mode) or metadata.st_nlink != 1:
            raise MapperCadenceRequestError(
                f"input entry {relative} must be a single-link regular file"
            )
        entries.append((relative, candidate))
    if not entries:
        raise MapperCadenceRequestError("input directory is empty")
    return entries


def _length_prefixed(hasher: Any, value: bytes) -> None:
    benchmark._hash_length_prefixed(hasher, value)


class _DigestFanout:
    def __init__(self, hashers: Sequence[Any]) -> None:
        self.hashers = tuple(hashers)

    def update(self, value: bytes) -> None:
        for hasher in self.hashers:
            hasher.update(value)


def _capture_input_closure(
    input_path: Path,
    input_kind: str,
) -> tuple[dict[str, Any], int]:
    input_path = _absolute_normalized(input_path, "input")
    if input_kind not in SUPPORTED_INPUT_KINDS:
        raise MapperCadenceRequestError(
            "mapper-cadence development requests currently support video inputs only"
        )
    if input_kind == "video":
        _owned_metadata(input_path, "input", regular=True, single_link=True)
        if input_path.suffix.lower() not in SUPPORTED_VIDEO_EXTENSIONS:
            raise MapperCadenceRequestError("video input has an unsupported video extension")
        entries = [("input", input_path)]
        consumed = entries
    else:
        entries = _safe_tree_files(input_path)
        consumed = [
            (relative, path)
            for relative, path in entries
            if len(PurePosixPath(relative).parts) == 1
            and not PurePosixPath(relative).name.startswith(".")
            and path.suffix.lower() in SUPPORTED_VIDEO_EXTENSIONS
        ]
        if len(consumed) < 2:
            raise MapperCadenceRequestError(
                "multi_video input must contain at least two immediate supported videos"
            )
    consumed_paths = {relative for relative, _ in consumed}
    source_hasher = hashlib.sha256()
    consumed_hasher = hashlib.sha256()
    _length_prefixed(source_hasher, INPUT_DIGEST_ALGORITHM.encode("utf-8"))
    _length_prefixed(consumed_hasher, INPUT_DIGEST_ALGORITHM.encode("utf-8"))
    ignored_manifest = []
    for relative, path in entries:
        _length_prefixed(source_hasher, relative.encode("utf-8"))
        hashers = [source_hasher]
        if relative in consumed_paths:
            _length_prefixed(consumed_hasher, relative.encode("utf-8"))
            hashers.append(consumed_hasher)
        byte_count, sha256 = _stable_file_measurement(
            path,
            f"input media {relative}",
            content_hasher=_DigestFanout(hashers),
            include_size_in_content_hasher=True,
        )
        if relative not in consumed_paths:
            ignored_manifest.append(
                {
                    "relative_path": relative,
                    "bytes": byte_count,
                    "sha256": f"sha256:{sha256}",
                }
            )
    closure = {
        "digest_algorithm": INPUT_DIGEST_ALGORITHM,
        "source_input_digest": f"sha256:{source_hasher.hexdigest()}",
        "consumed_media_paths": [relative for relative, _ in consumed],
        "consumed_media_digest": f"sha256:{consumed_hasher.hexdigest()}",
        "ignored_input_manifest": ignored_manifest,
        "ignored_input_manifest_sha256": sha256_canonical(ignored_manifest),
    }
    return closure, len(consumed)


def _capture_colmap_runtime(root: Path) -> dict[str, Any]:
    root = _absolute_normalized(root, "COLMAP runtime root")
    root_descriptor = _open_owned_directory(root, "COLMAP runtime root")
    components = []
    child_descriptors: dict[str, int] = {}
    try:
        for relative in COLMAP_RUNTIME_COMPONENT_PATHS:
            relative_path = PurePosixPath(relative)
            directory_name, file_name = relative_path.parts
            if directory_name not in child_descriptors:
                child_descriptors[directory_name] = _open_owned_child_directory(
                    root_descriptor,
                    directory_name,
                    f"COLMAP runtime directory {directory_name}",
                )
            byte_count, sha256 = _stable_file_measurement_at(
                child_descriptors[directory_name],
                file_name,
                f"COLMAP runtime component {relative}",
                executable=relative == "bin/colmap",
            )
            if byte_count <= 0:
                raise MapperCadenceRequestError(
                    f"COLMAP runtime component {relative} is empty"
                )
            components.append(
                {"toolchain_relative_path": relative, "sha256": sha256}
            )
    finally:
        for descriptor in child_descriptors.values():
            os.close(descriptor)
        os.close(root_descriptor)
    hasher = hashlib.sha256()
    _length_prefixed(hasher, b"easysplat-colmap-runtime-closure-v1")
    for component in components:
        _length_prefixed(
            hasher, component["toolchain_relative_path"].encode("utf-8")
        )
        _length_prefixed(hasher, component["sha256"].encode("utf-8"))
    return {"components": components, "closure_sha256": hasher.hexdigest()}


def _runner_identity(
    path: Path | None,
    closure_root: Path | None,
) -> tuple[str | None, dict[str, Any] | None]:
    if path is None and closure_root is None:
        return None, None
    if path is None or closure_root is None:
        raise MapperCadenceRequestError(
            "runner closure identity and live closure root must be supplied together"
        )
    data = _read_control_bytes(path, "measurement runner closure identity")
    value = _decode_json_mapping(data, "measurement runner closure identity")
    _exact_keys(
        value,
        {
            "schema_version",
            "label",
            "source_commit",
            "xcode_version",
            "swift_version",
            "files",
            "sha256",
        },
        "measurement runner closure identity",
    )
    if (
        _integer(value["schema_version"], "runner identity schema_version") != 1
        or value["label"] != "tracked-measurement-runner"
        or GIT_COMMIT.fullmatch(_string(value["source_commit"], "runner source_commit"))
        is None
    ):
        raise MapperCadenceRequestError("measurement runner closure identity is invalid")
    _string(value["xcode_version"], "runner xcode_version")
    _string(value["swift_version"], "runner swift_version")
    files = _mapping(value["files"], "runner files")
    _exact_keys(files, measurement_runner_closure.EXPECTED_FILES, "runner files")
    for name, raw_record in files.items():
        record = _mapping(raw_record, f"runner files.{name}")
        _exact_keys(record, {"bytes", "sha256"}, f"runner files.{name}")
        _integer(record["bytes"], f"runner files.{name}.bytes", minimum=1)
        _sha256(record["sha256"], f"runner files.{name}.sha256")
    expected_self_digest = _sha256(value["sha256"], "runner identity sha256")
    unsigned = {key: item for key, item in value.items() if key != "sha256"}
    actual_self_digest = hashlib.sha256(canonical_json_bytes(unsigned) + b"\n").hexdigest()
    if expected_self_digest != actual_self_digest:
        raise MapperCadenceRequestError(
            "measurement runner closure identity self-digest is invalid"
        )
    root_descriptor = _open_owned_directory(
        closure_root, "measurement runner live closure root"
    )
    try:
        try:
            actual_names = sorted(os.listdir(root_descriptor))
        except OSError as error:
            raise MapperCadenceRequestError(
                "unable to inventory measurement runner live closure"
            ) from error
        if actual_names != sorted(measurement_runner_closure.EXPECTED_FILES):
            raise MapperCadenceRequestError(
                "runner closure live contents do not match the identity"
            )
        executable_names = {
            measurement_runner_closure.EXECUTABLE_NAME,
            measurement_runner_closure.CANDIDATE_ADAPTER_NAME,
            measurement_runner_closure.BASELINE_ADAPTER_NAME,
            measurement_runner_closure.REFERENCE_ADAPTER_NAME,
        }
        for name in measurement_runner_closure.EXPECTED_FILES:
            byte_count, sha256 = _stable_file_measurement_at(
                root_descriptor,
                name,
                f"runner closure file {name}",
                maximum_bytes=measurement_runner_closure.MAXIMUM_FILE_BYTES,
                executable=name in executable_names,
            )
            if files[name] != {"bytes": byte_count, "sha256": sha256}:
                raise MapperCadenceRequestError(
                    f"runner closure live file {name} differs from its identity"
                )
    finally:
        os.close(root_descriptor)
    return hashlib.sha256(data).hexdigest(), value


def _validate_runner_identity_adapter(
    identity: Mapping[str, Any],
    *,
    adapter_bytes: int,
    adapter_sha256: str,
) -> None:
    files = _mapping(identity["files"], "runner files")
    record = _mapping(
        files[measurement_runner_closure.CANDIDATE_ADAPTER_NAME],
        "runner candidate adapter",
    )
    if record != {"bytes": adapter_bytes, "sha256": adapter_sha256}:
        raise MapperCadenceRequestError(
            "runner closure identity does not describe the live candidate adapter"
        )


def _validate_input_closure(value: Any) -> dict[str, Any]:
    closure = _mapping(value, "input_closure")
    _exact_keys(
        closure,
        {
            "digest_algorithm",
            "source_input_digest",
            "consumed_media_paths",
            "consumed_media_digest",
            "ignored_input_manifest",
            "ignored_input_manifest_sha256",
        },
        "input_closure",
    )
    if closure["digest_algorithm"] != INPUT_DIGEST_ALGORITHM:
        raise MapperCadenceRequestError("input_closure digest algorithm is invalid")
    _prefixed_sha256(closure["source_input_digest"], "source input digest")
    _prefixed_sha256(closure["consumed_media_digest"], "consumed media digest")
    consumed = closure["consumed_media_paths"]
    if (
        not isinstance(consumed, list)
        or not consumed
        or consumed != sorted(consumed)
        or len(consumed) != len(set(consumed))
    ):
        raise MapperCadenceRequestError(
            "input_closure consumed media paths must be sorted and unique"
        )
    for index, relative in enumerate(consumed):
        _safe_relative_path(relative, f"consumed_media_paths[{index}]")
    manifest = closure["ignored_input_manifest"]
    if not isinstance(manifest, list):
        raise MapperCadenceRequestError("ignored input manifest must be an array")
    prior = ""
    ignored_paths: set[str] = set()
    for index, raw_record in enumerate(manifest):
        record = _mapping(raw_record, f"ignored_input_manifest[{index}]")
        _exact_keys(
            record,
            {"relative_path", "bytes", "sha256"},
            f"ignored_input_manifest[{index}]",
        )
        relative = _safe_relative_path(
            record["relative_path"], f"ignored_input_manifest[{index}].relative_path"
        )
        if relative <= prior or relative in ignored_paths:
            raise MapperCadenceRequestError(
                "ignored input manifest paths must be sorted and unique"
            )
        if relative in set(consumed):
            raise MapperCadenceRequestError(
                "ignored input manifest overlaps consumed media"
            )
        prior = relative
        ignored_paths.add(relative)
        _integer(record["bytes"], f"ignored_input_manifest[{index}].bytes", minimum=0)
        _prefixed_sha256(
            record["sha256"], f"ignored_input_manifest[{index}].sha256"
        )
    manifest_sha256 = _sha256(
        closure["ignored_input_manifest_sha256"],
        "ignored input manifest sha256",
    )
    if manifest_sha256 != sha256_canonical(manifest):
        raise MapperCadenceRequestError("ignored input manifest digest is invalid")
    return closure


def _safe_relative_path(value: Any, label: str) -> str:
    result = _string(value, label)
    if "\\" in result or "\x00" in result:
        raise MapperCadenceRequestError(f"{label} must be a safe relative path")
    relative = PurePosixPath(result)
    if (
        relative.is_absolute()
        or relative.as_posix() != result
        or not relative.parts
        or any(part in {"", ".", ".."} for part in relative.parts)
    ):
        raise MapperCadenceRequestError(f"{label} must be a safe relative path")
    return result


def _validate_candidate_configuration(
    value: Any,
    *,
    category: str,
    input_kind: str,
    scale: int,
) -> dict[str, Any]:
    configuration = _mapping(value, "candidate_run_configuration")
    _exact_keys(
        configuration,
        CANDIDATE_CONFIGURATION_KEYS,
        "candidate_run_configuration",
    )
    detail = _string(configuration["detail_profile"], "detail_profile")
    if detail not in {"fast", "balanced", "high_detail"}:
        raise MapperCadenceRequestError("detail_profile is unsupported")
    if (
        _integer(
            configuration["selected_frame_count"],
            "selected_frame_count",
            minimum=1,
        )
        != scale
    ):
        raise MapperCadenceRequestError("selected_frame_count does not match scale")
    capture = _string(configuration["capture_path"], "capture_path")
    if capture not in {"automatic", "around_subject", "through_space", "large_area"}:
        raise MapperCadenceRequestError("capture_path is unsupported")
    topology = _string(configuration["input_topology"], "input_topology")
    if topology not in {"continuous", "segmented_mixed", "unordered"}:
        raise MapperCadenceRequestError("input_topology is unsupported")
    expected_topology = "continuous" if input_kind == "video" else "segmented_mixed"
    if topology != expected_topology:
        raise MapperCadenceRequestError("input topology does not match input kind")
    grouping = _string(configuration["camera_grouping"], "camera_grouping")
    if grouping not in {
        "automatic",
        "same_camera_and_lens",
        "mixed_cameras_or_lenses",
    }:
        raise MapperCadenceRequestError("camera_grouping is unsupported")
    lens = _string(configuration["lens_projection"], "lens_projection")
    if lens not in {"automatic", "perspective", "fisheye"}:
        raise MapperCadenceRequestError("lens_projection is unsupported")
    resource = _string(configuration["resource_policy"], "resource_policy")
    if resource not in {"automatic", "conserve_memory", "maximum_performance"}:
        raise MapperCadenceRequestError("resource_policy is unsupported")
    if configuration["compute_policy"] != "metal_for_supported_stages":
        raise MapperCadenceRequestError("compute_policy must prefer Metal")
    if configuration["descriptor_matcher"] != "faiss":
        raise MapperCadenceRequestError("descriptor_matcher must be faiss")
    if category == "large_area_exterior" and capture != "large_area":
        raise MapperCadenceRequestError("capture path must be large_area for this category")
    if category == "object_orbit" and capture != "around_subject":
        raise MapperCadenceRequestError(
            "capture path must be around_subject for this category"
        )
    if category == "interior_walkthrough" and capture != "through_space":
        raise MapperCadenceRequestError(
            "capture path must be through_space for this category"
        )
    pairing = _string(configuration["pairing_policy"], "pairing_policy")
    temporal = _string(configuration["temporal_pairing"], "temporal_pairing")
    offsets_raw = configuration["temporal_offsets"]
    if not isinstance(offsets_raw, list):
        raise MapperCadenceRequestError("temporal_offsets must be an array")
    offsets = [
        _integer(item, f"temporal_offsets[{index}]", minimum=1, maximum=128)
        for index, item in enumerate(offsets_raw)
    ]
    if offsets != sorted(set(offsets)):
        raise MapperCadenceRequestError("temporal_offsets must be sorted and unique")
    if topology == "segmented_mixed":
        expected_offsets = list(range(1, min(6, scale - 1) + 1))
        if (
            pairing != "segmented_mixed"
            or temporal != "linear"
            or offsets != expected_offsets
        ):
            raise MapperCadenceRequestError(
                "segmented input pairing policy is inconsistent"
            )
        expected_retrieval = (20, 8, 1)
    else:
        if category == "object_orbit":
            expected_pairing = "object_orbit"
            expected_temporal = "multiscale"
            expected_retrieval = (20, 2, 5)
        elif category == "interior_walkthrough":
            expected_pairing = "walkthrough"
            expected_temporal = "linear"
            expected_retrieval = (20, 2, 10)
        elif category == "large_area_exterior":
            expected_pairing = "large_area"
            expected_temporal = "multiscale"
            expected_retrieval = (20, 4, 10)
        else:
            expected_pairing = "generic_continuous"
            expected_temporal = "multiscale"
            expected_retrieval = (20, 2, 10) if scale >= 120 else (0, 0, 10)
        expected_offsets = (
            list(range(1, min(6, scale - 1) + 1))
            if expected_temporal == "linear"
            else [item for item in (1, 2, 4, 8, 16, 32, 64, 128) if item < scale]
        )
        if (
            pairing != expected_pairing
            or temporal != expected_temporal
            or offsets != expected_offsets
        ):
            raise MapperCadenceRequestError("continuous input pairing policy is inconsistent")
    actual_retrieval = (
        _integer(
            configuration["vocabulary_candidate_count"],
            "vocabulary_candidate_count",
            minimum=0,
        ),
        _integer(
            configuration["vocabulary_returned_neighbor_count"],
            "vocabulary_returned_neighbor_count",
            minimum=0,
        ),
        _integer(
            configuration["vocabulary_query_stride"],
            "vocabulary_query_stride",
            minimum=1,
        ),
    )
    if actual_retrieval != expected_retrieval:
        raise MapperCadenceRequestError("vocabulary retrieval policy is inconsistent")
    frames_ratio = _number(
        configuration["ba_global_frames_ratio"],
        "ba_global_frames_ratio",
        positive=True,
    )
    points_ratio = _number(
        configuration["ba_global_points_ratio"],
        "ba_global_points_ratio",
        positive=True,
    )
    if frames_ratio != points_ratio:
        raise MapperCadenceRequestError("bundle-adjustment cadence ratios must match")
    if topology == "segmented_mixed" and frames_ratio != 1.4:
        raise MapperCadenceRequestError(
            "segmented input candidate cadence must start at 1.4"
        )
    if _integer(
        configuration["ba_global_max_refinements"],
        "ba_global_max_refinements",
        minimum=1,
    ) != 5:
        raise MapperCadenceRequestError("ba_global_max_refinements must be 5")
    for field in (
        "ba_local_max_refinements",
        "ba_local_max_num_iterations",
        "ba_local_num_images",
        "trainer_iterations",
        "trainer_plateau_window",
    ):
        _integer(configuration[field], field, minimum=1)
    for field in ("ba_local_function_tolerance", "ba_global_function_tolerance"):
        _number(configuration[field], field, minimum=0)
    for field in (
        "feature_extraction_workers",
        "coupled_matching_workers",
        "vocabulary_retrieval_workers",
        "maximum_concurrent_video_source_analysis_tasks",
    ):
        _integer(configuration[field], field, minimum=1, maximum=64)
    if _integer(configuration["run_seed"], "run_seed", minimum=0) != 42:
        raise MapperCadenceRequestError("run_seed must be 42")
    return configuration


def _validate_fixed_mapper_option_shape(value: Any) -> dict[str, Any]:
    options = _mapping(value, "fixed_mapper_options")
    _exact_keys(options, FIXED_MAPPER_OPTION_KEYS, "fixed_mapper_options")
    integer_fields = (
        "local_max_refinements",
        "global_max_refinements",
        "global_max_num_iterations",
        "local_max_num_iterations",
        "local_image_count",
    )
    for field in integer_fields:
        _integer(
            options[field],
            f"fixed_mapper_options.{field}",
            minimum=1,
            maximum=(1 << 63) - 1,
        )
    for field in ("local_function_tolerance", "global_function_tolerance"):
        _number(options[field], f"fixed_mapper_options.{field}", minimum=0)
    if _integer(
        options["random_seed"],
        "fixed_mapper_options.random_seed",
        minimum=0,
        maximum=(1 << 31) - 1,
    ) != 42:
        raise MapperCadenceRequestError("fixed mapper random_seed must be 42")
    if not _boolean(
        options["refine_focal_length"], "fixed_mapper_options.refine_focal_length"
    ):
        raise MapperCadenceRequestError("fixed mapper must refine focal length")
    if _integer(
        options["minimum_pair_inlier_count"],
        "fixed_mapper_options.minimum_pair_inlier_count",
        minimum=1,
        maximum=(1 << 63) - 1,
    ) != 15:
        raise MapperCadenceRequestError(
            "fixed mapper minimum_pair_inlier_count must be 15"
        )
    return options


def _validate_fixed_mapper_options(
    value: Any,
    candidate: Mapping[str, Any],
) -> dict[str, Any]:
    options = _validate_fixed_mapper_option_shape(value)
    correspondences = {
        "local_max_refinements": "ba_local_max_refinements",
        "global_max_refinements": "ba_global_max_refinements",
        "local_max_num_iterations": "ba_local_max_num_iterations",
        "local_function_tolerance": "ba_local_function_tolerance",
        "global_function_tolerance": "ba_global_function_tolerance",
        "local_image_count": "ba_local_num_images",
        "random_seed": "run_seed",
    }
    for option_field, configuration_field in correspondences.items():
        if options[option_field] != candidate[configuration_field]:
            raise MapperCadenceRequestError(
                f"fixed mapper {option_field} does not match candidate configuration"
            )
    return options


def _validate_quality_thresholds(value: Any) -> dict[str, Any]:
    thresholds = _mapping(value, "quality_thresholds")
    _exact_keys(thresholds, QUALITY_THRESHOLDS, "quality_thresholds")
    for field, expected in QUALITY_THRESHOLDS.items():
        if isinstance(expected, int):
            actual: int | float = _integer(
                thresholds[field], f"quality_thresholds.{field}", minimum=0
            )
        else:
            actual = _number(
                thresholds[field], f"quality_thresholds.{field}", minimum=0
            )
        if actual != expected:
            raise MapperCadenceRequestError(
                f"quality_thresholds.{field} does not match the experiment contract"
            )
    return thresholds


def _validate_trial(value: Any, expected: Mapping[str, Any], label: str) -> None:
    trial = _mapping(value, label)
    _exact_keys(
        trial,
        {"ordinal", "name", "mapper_cadence", "ratio", "discarded"},
        label,
    )
    _integer(trial["ordinal"], f"{label}.ordinal", minimum=0)
    _string(trial["name"], f"{label}.name")
    if trial["mapper_cadence"] not in {"balanced-global", "frequent-global"}:
        raise MapperCadenceRequestError(f"{label}.mapper_cadence is invalid")
    _number(trial["ratio"], f"{label}.ratio", positive=True)
    _boolean(trial["discarded"], f"{label}.discarded")
    if trial != expected:
        raise MapperCadenceRequestError(f"{label} does not match the fixed schedule")


def _validate_experiment(
    value: Any,
    candidate: Mapping[str, Any],
) -> dict[str, Any]:
    experiment = _mapping(value, "experiment")
    _exact_keys(
        experiment,
        {
            "deterministic_seed",
            "fixed_mapper_options",
            "fixed_mapper_options_sha256",
            "warmup",
            "measured_trials",
            "cadence_schedule_sha256",
            "quality_thresholds",
            "quality_thresholds_sha256",
            "experiment_contract_sha256",
        },
        "experiment",
    )
    seed = _integer(experiment["deterministic_seed"], "deterministic_seed", minimum=0)
    if seed != candidate["run_seed"] or seed != 42:
        raise MapperCadenceRequestError("deterministic seed does not match run_seed")
    options = _validate_fixed_mapper_options(
        experiment["fixed_mapper_options"], candidate
    )
    options_digest = _sha256(
        experiment["fixed_mapper_options_sha256"],
        "fixed_mapper_options_sha256",
    )
    if options_digest != fixed_mapper_options_sha256(options):
        raise MapperCadenceRequestError("fixed mapper options digest is invalid")
    _validate_trial(experiment["warmup"], WARMUP, "experiment.warmup")
    trials = experiment["measured_trials"]
    if not isinstance(trials, list) or len(trials) != len(MEASURED_SCHEDULE):
        raise MapperCadenceRequestError("experiment measured schedule is invalid")
    for index, expected in enumerate(MEASURED_SCHEDULE):
        _validate_trial(trials[index], expected, f"experiment.measured_trials[{index}]")
    schedule = {"warmup": experiment["warmup"], "measured_trials": trials}
    schedule_digest = _sha256(
        experiment["cadence_schedule_sha256"], "cadence_schedule_sha256"
    )
    if schedule_digest != sha256_canonical(schedule):
        raise MapperCadenceRequestError("cadence schedule digest is invalid")
    thresholds = _validate_quality_thresholds(experiment["quality_thresholds"])
    thresholds_digest = _sha256(
        experiment["quality_thresholds_sha256"], "quality_thresholds_sha256"
    )
    if thresholds_digest != sha256_canonical(thresholds):
        raise MapperCadenceRequestError("quality thresholds digest is invalid")
    contract = {
        "deterministic_seed": seed,
        "fixed_mapper_options_sha256": options_digest,
        "cadence_schedule_sha256": schedule_digest,
        "quality_thresholds_sha256": thresholds_digest,
    }
    if _sha256(
        experiment["experiment_contract_sha256"], "experiment_contract_sha256"
    ) != sha256_canonical(contract):
        raise MapperCadenceRequestError("experiment contract digest is invalid")
    return experiment


def _validate_runtime_closure(value: Any) -> dict[str, Any]:
    runtime = _mapping(value, "runtime_closure")
    _exact_keys(
        runtime,
        {
            "adapter_executable_name",
            "adapter_executable_bytes",
            "adapter_executable_sha256",
            "colmap_runtime_components",
            "colmap_runtime_closure_sha256",
            "toolchain_provenance_status",
        },
        "runtime_closure",
    )
    adapter_name = _string(
        runtime["adapter_executable_name"], "adapter_executable_name"
    )
    if Path(adapter_name).name != adapter_name or adapter_name in {".", ".."}:
        raise MapperCadenceRequestError("adapter executable name is invalid")
    _integer(
        runtime["adapter_executable_bytes"],
        "adapter_executable_bytes",
        minimum=1,
        maximum=MAXIMUM_ADAPTER_BYTES,
    )
    _sha256(runtime["adapter_executable_sha256"], "adapter_executable_sha256")
    components = runtime["colmap_runtime_components"]
    if not isinstance(components, list) or len(components) != len(
        COLMAP_RUNTIME_COMPONENT_PATHS
    ):
        raise MapperCadenceRequestError("COLMAP runtime components are invalid")
    for index, expected_path in enumerate(COLMAP_RUNTIME_COMPONENT_PATHS):
        component = _mapping(components[index], f"runtime component {index}")
        _exact_keys(
            component,
            {"toolchain_relative_path", "sha256"},
            f"runtime component {index}",
        )
        if component["toolchain_relative_path"] != expected_path:
            raise MapperCadenceRequestError("COLMAP runtime component order is invalid")
        _sha256(component["sha256"], f"runtime component {index} sha256")
    _sha256(
        runtime["colmap_runtime_closure_sha256"],
        "colmap_runtime_closure_sha256",
    )
    if runtime["toolchain_provenance_status"] != TOOLCHAIN_PROVENANCE:
        raise MapperCadenceRequestError(
            "toolchain provenance must be local_adhoc_unsigned"
        )
    return runtime


def _validate_build_identity(value: Any) -> dict[str, Any]:
    build = _mapping(value, "build_identity")
    _exact_keys(
        build,
        {
            "source_provenance_scope",
            "source_git_commit",
            "source_tree_state",
            "xcode_version",
            "swift_version",
            "measurement_runner_closure_identity_sha256",
        },
        "build_identity",
    )
    if build["source_provenance_scope"] != SOURCE_PROVENANCE_SCOPE:
        raise MapperCadenceRequestError(
            "source provenance must be binary_only_dirty_worktree"
        )
    if build["source_tree_state"] != "dirty":
        raise MapperCadenceRequestError(
            "development-only cadence requests must identify a dirty worktree"
        )
    if GIT_COMMIT.fullmatch(
        _string(build["source_git_commit"], "source_git_commit")
    ) is None:
        raise MapperCadenceRequestError("source_git_commit is invalid")
    _string(build["xcode_version"], "xcode_version")
    _string(build["swift_version"], "swift_version")
    runner_identity = build["measurement_runner_closure_identity_sha256"]
    if runner_identity is not None:
        _sha256(runner_identity, "measurement_runner_closure_identity_sha256")
    return build


def _validate_request_structure(value: Any) -> dict[str, Any]:
    request = _mapping(value, "mapper cadence request")
    _exact_keys(
        request,
        {
            "schema_version",
            "evidence_class",
            "request_kind",
            "binding",
            "category",
            "input_kind",
            "video_source_count",
            "holdout_indices",
            "candidate_run_configuration",
            "input_closure",
            "runtime_closure",
            "build_identity",
            "experiment",
        },
        "mapper cadence request",
    )
    if _integer(request["schema_version"], "schema_version") != SCHEMA_VERSION:
        raise MapperCadenceRequestError("schema_version is unsupported")
    if request["evidence_class"] != EVIDENCE_CLASS:
        raise MapperCadenceRequestError("evidence class must be development_only")
    if request["request_kind"] != REQUEST_KIND:
        raise MapperCadenceRequestError("request kind must be mapper_cadence_ab")
    binding = _mapping(request["binding"], "binding")
    _exact_keys(binding, {"scene_id", "scale"}, "binding")
    scene_id = _string(binding["scene_id"], "binding.scene_id")
    if SAFE_TOKEN.fullmatch(scene_id) is None:
        raise MapperCadenceRequestError("binding.scene_id is invalid")
    scale = _integer(binding["scale"], "binding.scale", minimum=1)
    if scale not in {30, 120, 250, 500, 3000}:
        raise MapperCadenceRequestError("binding.scale is not a supported benchmark scale")
    category = _string(request["category"], "category")
    if category not in ALLOWED_CATEGORIES:
        raise MapperCadenceRequestError("category is unsupported")
    input_kind = _string(request["input_kind"], "input_kind")
    if input_kind not in SUPPORTED_INPUT_KINDS:
        raise MapperCadenceRequestError(
            "mapper-cadence development requests currently support video inputs only"
        )
    video_count = _integer(
        request["video_source_count"], "video_source_count", minimum=1
    )
    if (input_kind == "video" and video_count != 1) or (
        input_kind == "multi_video" and video_count < 2
    ):
        raise MapperCadenceRequestError("video_source_count does not match input_kind")
    if request["holdout_indices"] != []:
        raise MapperCadenceRequestError(
            "development mapper-cadence requests must not claim rendering holdouts"
        )
    candidate = _validate_candidate_configuration(
        request["candidate_run_configuration"],
        category=category,
        input_kind=input_kind,
        scale=scale,
    )
    input_closure = _validate_input_closure(request["input_closure"])
    if len(input_closure["consumed_media_paths"]) != video_count:
        raise MapperCadenceRequestError(
            "video_source_count does not match consumed media closure"
        )
    _validate_runtime_closure(request["runtime_closure"])
    _validate_build_identity(request["build_identity"])
    _validate_experiment(request["experiment"], candidate)
    return request


def build_request(
    *,
    scene_id: str,
    category: str,
    input_kind: str,
    input_path: Path,
    scale: int,
    candidate_run_configuration: Mapping[str, Any],
    adapter_executable: Path,
    colmap_runtime_root: Path,
    colmap_runtime_closure_sha256: str,
    fixed_mapper_options: Mapping[str, Any],
    quality_thresholds: Mapping[str, Any],
    source_git_commit: str,
    source_tree_state: str,
    measurement_runner_closure_identity: Path | None,
    measurement_runner_closure_root: Path | None,
    xcode_version: str,
    swift_version: str,
) -> dict[str, Any]:
    if SAFE_TOKEN.fullmatch(_string(scene_id, "scene_id")) is None:
        raise MapperCadenceRequestError("scene_id is invalid")
    if category not in ALLOWED_CATEGORIES:
        raise MapperCadenceRequestError("category is unsupported")
    scale = _integer(scale, "scale", minimum=1)
    if scale not in {30, 120, 250, 500, 3000}:
        raise MapperCadenceRequestError("scale is not a supported benchmark scale")
    if input_kind not in SUPPORTED_INPUT_KINDS:
        raise MapperCadenceRequestError(
            "mapper-cadence development requests currently support video inputs only"
        )
    candidate = _validate_candidate_configuration(
        dict(candidate_run_configuration),
        category=category,
        input_kind=input_kind,
        scale=scale,
    )
    options = _validate_fixed_mapper_options(dict(fixed_mapper_options), candidate)
    thresholds = _validate_quality_thresholds(dict(quality_thresholds))
    input_closure, video_source_count = _capture_input_closure(input_path, input_kind)
    adapter_executable = _absolute_normalized(
        adapter_executable, "adapter executable"
    )
    adapter_bytes, adapter_sha256 = _stable_file_measurement(
        adapter_executable,
        "adapter executable",
        maximum_bytes=MAXIMUM_ADAPTER_BYTES,
        executable=True,
    )
    if adapter_bytes <= 0:
        raise MapperCadenceRequestError("adapter executable is empty")
    expected_runtime_sha256 = _sha256(
        colmap_runtime_closure_sha256, "COLMAP runtime closure sha256"
    )
    runtime = _capture_colmap_runtime(colmap_runtime_root)
    if runtime["closure_sha256"] != expected_runtime_sha256:
        raise MapperCadenceRequestError(
            "live COLMAP runtime closure does not match the expected SHA-256"
        )
    if GIT_COMMIT.fullmatch(_string(source_git_commit, "source_git_commit")) is None:
        raise MapperCadenceRequestError("source_git_commit is invalid")
    if source_tree_state != "dirty":
        raise MapperCadenceRequestError(
            "development-only cadence requests require source_tree_state dirty"
        )
    xcode_version = _string(xcode_version, "xcode_version")
    swift_version = _string(swift_version, "swift_version")
    runner_identity_sha256, identity = _runner_identity(
        measurement_runner_closure_identity,
        measurement_runner_closure_root,
    )
    if identity is not None:
        _validate_runner_identity_adapter(
            identity,
            adapter_bytes=adapter_bytes,
            adapter_sha256=adapter_sha256,
        )
        if (
            identity["source_commit"] != source_git_commit
            or identity["xcode_version"] != xcode_version
            or identity["swift_version"] != swift_version
        ):
            raise MapperCadenceRequestError(
                "measurement runner closure identity does not match build identity"
            )
    schedule = {
        "warmup": dict(WARMUP),
        "measured_trials": [dict(trial) for trial in MEASURED_SCHEDULE],
    }
    fixed_options_sha256 = fixed_mapper_options_sha256(options)
    schedule_sha256 = sha256_canonical(schedule)
    thresholds_sha256 = sha256_canonical(thresholds)
    contract = {
        "deterministic_seed": candidate["run_seed"],
        "fixed_mapper_options_sha256": fixed_options_sha256,
        "cadence_schedule_sha256": schedule_sha256,
        "quality_thresholds_sha256": thresholds_sha256,
    }
    request = {
        "schema_version": SCHEMA_VERSION,
        "evidence_class": EVIDENCE_CLASS,
        "request_kind": REQUEST_KIND,
        "binding": {"scene_id": scene_id, "scale": scale},
        "category": category,
        "input_kind": input_kind,
        "video_source_count": video_source_count,
        "holdout_indices": [],
        "candidate_run_configuration": dict(candidate),
        "input_closure": input_closure,
        "runtime_closure": {
            "adapter_executable_name": adapter_executable.name,
            "adapter_executable_bytes": adapter_bytes,
            "adapter_executable_sha256": adapter_sha256,
            "colmap_runtime_components": runtime["components"],
            "colmap_runtime_closure_sha256": runtime["closure_sha256"],
            "toolchain_provenance_status": TOOLCHAIN_PROVENANCE,
        },
        "build_identity": {
            "source_provenance_scope": SOURCE_PROVENANCE_SCOPE,
            "source_git_commit": source_git_commit,
            "source_tree_state": source_tree_state,
            "xcode_version": xcode_version,
            "swift_version": swift_version,
            "measurement_runner_closure_identity_sha256": runner_identity_sha256,
        },
        "experiment": {
            "deterministic_seed": candidate["run_seed"],
            "fixed_mapper_options": dict(options),
            "fixed_mapper_options_sha256": fixed_options_sha256,
            "warmup": schedule["warmup"],
            "measured_trials": schedule["measured_trials"],
            "cadence_schedule_sha256": schedule_sha256,
            "quality_thresholds": dict(thresholds),
            "quality_thresholds_sha256": thresholds_sha256,
            "experiment_contract_sha256": sha256_canonical(contract),
        },
    }
    return _validate_request_structure(request)


def validate_request(
    value: Any,
    *,
    input_path: Path,
    adapter_executable: Path,
    colmap_runtime_root: Path,
    colmap_runtime_closure_sha256: str,
    measurement_runner_closure_identity: Path | None = None,
    measurement_runner_closure_root: Path | None = None,
) -> dict[str, Any]:
    request = _validate_request_structure(value)
    input_closure = _mapping(request["input_closure"], "input_closure")
    live_input_closure, live_video_count = _capture_input_closure(
        input_path,
        request["input_kind"],
    )
    if live_input_closure["source_input_digest"] != input_closure["source_input_digest"]:
        raise MapperCadenceRequestError("source input digest mismatch")
    if (
        live_input_closure["consumed_media_paths"]
        != input_closure["consumed_media_paths"]
        or live_input_closure["consumed_media_digest"]
        != input_closure["consumed_media_digest"]
    ):
        raise MapperCadenceRequestError("consumed media digest mismatch")
    if (
        live_input_closure["ignored_input_manifest"]
        != input_closure["ignored_input_manifest"]
        or live_input_closure["ignored_input_manifest_sha256"]
        != input_closure["ignored_input_manifest_sha256"]
    ):
        raise MapperCadenceRequestError("ignored input manifest mismatch")
    if live_video_count != request["video_source_count"]:
        raise MapperCadenceRequestError("live video source count mismatch")
    runtime = _mapping(request["runtime_closure"], "runtime_closure")
    adapter_executable = _absolute_normalized(
        adapter_executable, "adapter executable"
    )
    adapter_bytes, adapter_sha256 = _stable_file_measurement(
        adapter_executable,
        "adapter executable",
        maximum_bytes=MAXIMUM_ADAPTER_BYTES,
        executable=True,
    )
    if (
        adapter_executable.name != runtime["adapter_executable_name"]
        or adapter_bytes != runtime["adapter_executable_bytes"]
        or adapter_sha256 != runtime["adapter_executable_sha256"]
    ):
        raise MapperCadenceRequestError("adapter executable binding mismatch")
    expected_runtime_sha256 = _sha256(
        colmap_runtime_closure_sha256, "COLMAP runtime closure sha256"
    )
    live_runtime = _capture_colmap_runtime(colmap_runtime_root)
    if (
        expected_runtime_sha256 != runtime["colmap_runtime_closure_sha256"]
        or live_runtime["closure_sha256"] != expected_runtime_sha256
        or live_runtime["components"] != runtime["colmap_runtime_components"]
    ):
        raise MapperCadenceRequestError("COLMAP runtime closure binding mismatch")
    build = _mapping(request["build_identity"], "build_identity")
    runner_identity_sha256, identity = _runner_identity(
        measurement_runner_closure_identity,
        measurement_runner_closure_root,
    )
    if (
        runner_identity_sha256
        != build["measurement_runner_closure_identity_sha256"]
    ):
        raise MapperCadenceRequestError("runner closure identity binding mismatch")
    if identity is not None:
        _validate_runner_identity_adapter(
            identity,
            adapter_bytes=adapter_bytes,
            adapter_sha256=adapter_sha256,
        )
        if (
            identity["source_commit"] != build["source_git_commit"]
            or identity["xcode_version"] != build["xcode_version"]
            or identity["swift_version"] != build["swift_version"]
        ):
            raise MapperCadenceRequestError(
                "runner closure identity does not match build identity"
            )
    return request


def load_and_validate_request(
    path: Path,
    *,
    input_path: Path,
    adapter_executable: Path,
    colmap_runtime_root: Path,
    colmap_runtime_closure_sha256: str,
    measurement_runner_closure_identity: Path | None = None,
    measurement_runner_closure_root: Path | None = None,
) -> dict[str, Any]:
    request = _load_json_mapping(path, "mapper cadence request", private=True)
    return validate_request(
        request,
        input_path=input_path,
        adapter_executable=adapter_executable,
        colmap_runtime_root=colmap_runtime_root,
        colmap_runtime_closure_sha256=colmap_runtime_closure_sha256,
        measurement_runner_closure_identity=measurement_runner_closure_identity,
        measurement_runner_closure_root=measurement_runner_closure_root,
    )


def write_request(path: Path, value: Mapping[str, Any]) -> None:
    request = _validate_request_structure(dict(value))
    payload = canonical_json_bytes(request) + b"\n"
    destination = _absolute_normalized(path, "request output")
    parent = destination.parent
    parent_metadata = _owned_metadata(parent, "request output parent", directory=True)
    if destination.exists() or destination.is_symlink():
        raise MapperCadenceRequestError("request output already exists")
    flags = os.O_RDONLY | getattr(os, "O_DIRECTORY", 0) | getattr(os, "O_NOFOLLOW", 0)
    try:
        parent_descriptor = os.open(parent, flags)
    except OSError as error:
        raise MapperCadenceRequestError("unable to open request output parent") from error
    temporary_name = f".request-{secrets.token_hex(12)}.tmp"
    temporary_created = False
    try:
        opened_parent = os.fstat(parent_descriptor)
        if (opened_parent.st_dev, opened_parent.st_ino) != (
            parent_metadata.st_dev,
            parent_metadata.st_ino,
        ):
            raise MapperCadenceRequestError("request output parent changed while opening")
        temporary_flags = (
            os.O_WRONLY
            | os.O_CREAT
            | os.O_EXCL
            | getattr(os, "O_NOFOLLOW", 0)
        )
        temporary_descriptor = os.open(
            temporary_name,
            temporary_flags,
            0o600,
            dir_fd=parent_descriptor,
        )
        temporary_created = True
        try:
            os.fchmod(temporary_descriptor, 0o600)
            offset = 0
            while offset < len(payload):
                written = os.write(temporary_descriptor, payload[offset:])
                if written <= 0:
                    raise MapperCadenceRequestError("unable to write request output")
                offset += written
            os.fsync(temporary_descriptor)
        finally:
            os.close(temporary_descriptor)
        try:
            os.link(
                temporary_name,
                destination.name,
                src_dir_fd=parent_descriptor,
                dst_dir_fd=parent_descriptor,
                follow_symlinks=False,
            )
        except FileExistsError as error:
            raise MapperCadenceRequestError("request output already exists") from error
        os.fsync(parent_descriptor)
    except MapperCadenceRequestError:
        raise
    except OSError as error:
        if error.errno == errno.EEXIST:
            raise MapperCadenceRequestError("request output already exists") from error
        raise MapperCadenceRequestError("unable to publish request output") from error
    finally:
        if temporary_created:
            try:
                os.unlink(temporary_name, dir_fd=parent_descriptor)
            except FileNotFoundError:
                pass
        os.close(parent_descriptor)


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser()
    commands = parser.add_subparsers(dest="command", required=True)
    create = commands.add_parser("create")
    create.add_argument("--input", type=Path, required=True)
    create.add_argument("--scene-id", required=True)
    create.add_argument("--category", required=True)
    create.add_argument("--input-kind", required=True)
    create.add_argument("--scale", type=int, required=True)
    create.add_argument("--candidate-configuration", type=Path, required=True)
    create.add_argument("--fixed-mapper-options", type=Path, required=True)
    create.add_argument("--adapter-executable", type=Path, required=True)
    create.add_argument("--colmap-runtime-root", type=Path, required=True)
    create.add_argument("--colmap-runtime-closure-sha256", required=True)
    create.add_argument("--source-git-commit", required=True)
    create.add_argument("--source-tree-state", choices=("dirty",), required=True)
    create.add_argument("--measurement-runner-closure-identity", type=Path)
    create.add_argument("--measurement-runner-closure-root", type=Path)
    create.add_argument("--xcode-version", required=True)
    create.add_argument("--swift-version", required=True)
    create.add_argument("--output", type=Path, required=True)
    validate = commands.add_parser("validate")
    validate.add_argument("--request", type=Path, required=True)
    validate.add_argument("--input", type=Path, required=True)
    validate.add_argument("--adapter-executable", type=Path, required=True)
    validate.add_argument("--colmap-runtime-root", type=Path, required=True)
    validate.add_argument("--colmap-runtime-closure-sha256", required=True)
    validate.add_argument("--measurement-runner-closure-identity", type=Path)
    validate.add_argument("--measurement-runner-closure-root", type=Path)
    return parser


def _status(path: Path, status: str) -> dict[str, str]:
    return {
        "status": status,
        "evidence_class": EVIDENCE_CLASS,
        "request_sha256": sha256_file(path),
    }


def main(arguments: Sequence[str] | None = None) -> int:
    try:
        parsed = _parser().parse_args(arguments)
        if parsed.command == "create":
            candidate = _load_json_mapping(
                parsed.candidate_configuration,
                "candidate configuration",
            )
            fixed_options = _load_json_mapping(
                parsed.fixed_mapper_options,
                "fixed mapper options",
            )
            request = build_request(
                scene_id=parsed.scene_id,
                category=parsed.category,
                input_kind=parsed.input_kind,
                input_path=parsed.input,
                scale=parsed.scale,
                candidate_run_configuration=candidate,
                adapter_executable=parsed.adapter_executable,
                colmap_runtime_root=parsed.colmap_runtime_root,
                colmap_runtime_closure_sha256=parsed.colmap_runtime_closure_sha256,
                fixed_mapper_options=fixed_options,
                quality_thresholds=QUALITY_THRESHOLDS,
                source_git_commit=parsed.source_git_commit,
                source_tree_state=parsed.source_tree_state,
                measurement_runner_closure_identity=(
                    parsed.measurement_runner_closure_identity
                ),
                measurement_runner_closure_root=(
                    parsed.measurement_runner_closure_root
                ),
                xcode_version=parsed.xcode_version,
                swift_version=parsed.swift_version,
            )
            write_request(parsed.output, request)
            result = _status(parsed.output, "created")
        else:
            load_and_validate_request(
                parsed.request,
                input_path=parsed.input,
                adapter_executable=parsed.adapter_executable,
                colmap_runtime_root=parsed.colmap_runtime_root,
                colmap_runtime_closure_sha256=parsed.colmap_runtime_closure_sha256,
                measurement_runner_closure_identity=(
                    parsed.measurement_runner_closure_identity
                ),
                measurement_runner_closure_root=(
                    parsed.measurement_runner_closure_root
                ),
            )
            result = _status(parsed.request, "valid")
        print(canonical_json_bytes(result).decode("utf-8"))
        return 0
    except MapperCadenceRequestError as error:
        print(f"mapper cadence request: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
