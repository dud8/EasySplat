#!/usr/bin/env python3
"""Run private unordered-photo filename permutations through fresh geometry solves.

This is a development evidence producer. It deliberately keeps source paths, raw
content hashes, materialization maps, and project paths outside public evidence.
"""

from __future__ import annotations

import argparse
import ctypes
import errno
import hashlib
import hmac
import importlib.machinery
import json
import math
import os
import secrets
import shutil
import signal
import stat
import subprocess
import sys
import tempfile
import threading
import unicodedata
import time
import types
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Callable, Mapping

if __package__ in {None, ""}:
    repository_root = Path(__file__).resolve().parents[2]
    sys.path.insert(0, str(repository_root))

_IMPORTED_PRODUCER_SOURCE = Path(__file__).read_bytes()
_EVIDENCE_SOURCE_PATH = Path(__file__).resolve().parent / "evidence_protocol.py"
_IMPORTED_EVIDENCE_SOURCE = _EVIDENCE_SOURCE_PATH.read_bytes()
_EVIDENCE_MODULE_NAME = "scripts.benchmark._photo_permutation_evidence_protocol_source"
evidence = types.ModuleType(_EVIDENCE_MODULE_NAME)
evidence.__file__ = str(_EVIDENCE_SOURCE_PATH)
evidence.__package__ = "scripts.benchmark"
evidence.__loader__ = None
evidence.__spec__ = importlib.machinery.ModuleSpec(
    _EVIDENCE_MODULE_NAME,
    loader=None,
    origin=str(_EVIDENCE_SOURCE_PATH),
)
sys.modules[_EVIDENCE_MODULE_NAME] = evidence
exec(
    compile(
        _IMPORTED_EVIDENCE_SOURCE,
        str(_EVIDENCE_SOURCE_PATH),
        "exec",
        dont_inherit=True,
    ),
    evidence.__dict__,
)
_IMPORTED_IMPLEMENTATION_RECORDS = (
    {
        "label": "photo_permutation_producer.py",
        "bytes": len(_IMPORTED_PRODUCER_SOURCE),
        "sha256": "sha256:" + hashlib.sha256(_IMPORTED_PRODUCER_SOURCE).hexdigest(),
    },
    {
        "label": "evidence_protocol.py",
        "bytes": len(_IMPORTED_EVIDENCE_SOURCE),
        "sha256": "sha256:" + hashlib.sha256(_IMPORTED_EVIDENCE_SOURCE).hexdigest(),
    },
)


MAXIMUM_PRIVATE_JSON_BYTES = 16 * 1024 * 1024
PAIR_GRAPH_EVIDENCE_SCHEMA_VERSION = 20
PAIR_GRAPH_PLAN_BINDING_FIELDS = {
    "pairingPolicy",
    "geometryBackend",
    "modelIdentifier",
    "temporalPairing",
    "temporalOffsets",
    "retrievalEngine",
    "retrievalCandidateCount",
    "retrievalNeighborCount",
    "retrievalQueryStride",
    "requiresCrossClipRetrieval",
    "normalDescriptorMatcher",
    "cameraInitializationRecipe",
    "runSeed",
}
MEASUREMENT_PROJECT_LEAF = "project.easysplatproj"
OWNED_MARKER = ".easysplat-photo-permutation-owned"
BOUND_TOOLCHAIN_MARKER = ".easysplat-bound-toolchain-staging"
BOUND_TOOLCHAIN_TRANSACTION = "bound-toolchain-transaction.json"
PUBLIC_UNAVAILABLE_FIELDS = {"schema_version", "status", "variant_id", "reason"}
PUBLIC_VARIANT_FIELDS = {
    "group_id",
    "variant_id",
    "permutation",
    "order_commitment",
    "content_set_attestation",
    "canonical_observation_attestation",
    "source_kind",
    "selected_content_ids",
    "registered_content_ids",
    "selected_content_set_sha256",
    "registered_content_set_sha256",
    "normalized_pair_graph_sha256",
    "normalized_pair_edges",
    "requested_plan_sha256",
    "scale",
    "run_seed",
    "pairing_policy",
    "accepted_attempt",
    "scheduled_pair_count",
    "scheduled_pair_graph_sha256",
    "attempted_pair_count",
    "attempted_pair_graph_sha256",
    "raw_matched_pair_count",
    "raw_matched_pair_graph_sha256",
    "spatially_verified_pair_count",
    "retrieval_worker_executed",
    "pair_counts",
    "registered_views",
    "point_count",
    "observation_count",
    "residual_median_pixels",
    "residual_p90_pixels",
    "camera_center_p95_scene_radius_fraction",
    "rotation_p95_degrees",
}
PRIVATE_OBSERVATION_FIELDS = {
    "schema_version",
    "private_order_manifest_sha256",
    "order_commitment",
    "content_set_attestation",
    "selected_content_ids",
    "registered_content_ids",
    "normalized_pair_edges",
    "pairing_policy",
    "accepted_attempt",
    "scheduled_pair_count",
    "scheduled_pair_graph_sha256",
    "attempted_pair_count",
    "attempted_pair_graph_sha256",
    "raw_matched_pair_count",
    "raw_matched_pair_graph_sha256",
    "spatially_verified_pair_count",
    "retrieval_worker_executed",
    "pair_counts",
    "registered_views",
    "point_count",
    "observation_count",
    "residual_median_pixels",
    "residual_p90_pixels",
    "poses",
}
PRIVATE_PAIR_COUNT_FIELDS = {
    "temporal",
    "vocabulary_retrieval",
    "loop_revisit",
    "exhaustive_primary",
    "exhaustive_recovery",
}
GEOMETRY_ONLY_ENVELOPE_FIELDS = {
    "schema_version",
    "measurement_scope",
    "variant",
    "started_monotonic_seconds",
    "ended_monotonic_seconds",
    "project_root",
    "geometry_manifest",
    "selection_manifest",
    "pair_graph_evidence",
    "canonical_text_model",
    "pipeline_log",
    "registered_views",
    "point_count",
    "observation_count",
    "median_residual_pixels",
    "p90_residual_pixels",
    "geometry_completed_monotonic_seconds",
    "pipeline_stage_seconds",
    "stage_seconds",
}
SUPPORTED_STILL_EXTENSIONS = {
    ".arw",
    ".cr2",
    ".cr3",
    ".dng",
    ".heic",
    ".heif",
    ".jpg",
    ".jpeg",
    ".nef",
    ".orf",
    ".png",
    ".raf",
    ".rw2",
    ".tif",
    ".tiff",
}
MAXIMUM_SOURCE_FILE_BYTES = 4 * 1024 * 1024 * 1024
MAXIMUM_SOURCE_CLOSURE_BYTES = 64 * 1024 * 1024 * 1024
MINIMUM_MODEL_IMAGES_BYTES = 128 * 1024 * 1024
MODEL_IMAGES_BYTES_PER_SELECTED_VIEW = 1024 * 1024
MAXIMUM_MODEL_IMAGES_BYTES = 512 * 1024 * 1024
CALIBRATION_DATASET_SOURCE_KIND = "calibration_dataset_derived_stills"
TUMVI_SUPPORTED_CROP_MANIFEST_SHA256 = (
    "sha256:4057520e0ceea43fef5c80839cfff55a34bdddb4caedc099abb25364e81529ce"
)
TUMVI_SUPPORTED_CROP_OUTPUT_SET_SHA256 = (
    "sha256:1c9b19e450250539e18fe7694c0ae25bc7a84f5696dcf5e6512065eefc7ba501"
)
TUMVI_SUPPORTED_CROP_OUTPUT_COUNT = 120
TUMVI_SUPPORTED_CROP_TOTAL_BYTES = 23_067_069


class ProducerError(RuntimeError):
    pass


class ProducerUnavailable(ProducerError):
    def __init__(self, reason: str):
        self.reason = reason
        super().__init__(reason)


class ProducerInterrupted(ProducerError):
    def __init__(self, signal_number: int):
        self.signal_number = signal_number
        super().__init__("geometry adapter was interrupted")


def _model_images_maximum_bytes(selected_view_count: int) -> int:
    if type(selected_view_count) is not int or selected_view_count <= 0:
        raise ProducerUnavailable("selection_artifact_invalid")
    return max(
        MINIMUM_MODEL_IMAGES_BYTES,
        min(
            MAXIMUM_MODEL_IMAGES_BYTES,
            selected_view_count * MODEL_IMAGES_BYTES_PER_SELECTED_VIEW,
        ),
    )


@dataclass(frozen=True)
class VariantSpec:
    variant_id: str
    permutation_index: int
    permutation_seed: int

    @property
    def public_permutation(self) -> dict[str, Any]:
        if self.permutation_index == 0:
            return {"kind": "canonical"}
        return {
            "kind": "shuffled",
            "index": self.permutation_index,
            "seed": self.permutation_seed,
        }


@dataclass(frozen=True)
class FileSnapshot:
    sha256: str
    byte_count: int
    device: int
    inode: int
    mtime_ns: int
    ctime_ns: int
    link_count: int
    permission_mode: int


@dataclass(frozen=True)
class DirectorySnapshot:
    relative_path: str
    device: int
    inode: int
    mtime_ns: int
    ctime_ns: int
    permission_mode: int


@dataclass(frozen=True)
class RuntimeGroupContext:
    contract: dict[str, Any]
    source_root: Path
    source_files: tuple[tuple[str, FileSnapshot], ...]
    request_path: Path
    request_snapshot: FileSnapshot
    adapter_path: Path
    adapter_snapshot: FileSnapshot
    toolchain_root: Path
    toolchain_files: tuple[tuple[str, FileSnapshot], ...]
    toolchain_directories: tuple[DirectorySnapshot, ...]
    producer_files: tuple[tuple[Path, FileSnapshot], ...]


@dataclass(frozen=True)
class BoundToolchainContext:
    root: Path
    files: tuple[tuple[str, FileSnapshot], ...]
    directories: tuple[DirectorySnapshot, ...]
    closure_sha256: str


@dataclass(frozen=True)
class OwnedRun:
    root: Path
    parent: Path
    device: int
    inode: int
    token: str
    ownership_receipt: Path
    group_contract_sha256: str


@dataclass(frozen=True)
class DirectoryLocation:
    path: Path
    identity: tuple[int, int] | None
    ancestor_identities: frozenset[tuple[int, int]]
    parent_identity: tuple[int, int]
    leaf_name: str | None
    parent_is_case_sensitive: bool


class _ProcBSDInfo(ctypes.Structure):
    _fields_ = [
        ("flags", ctypes.c_uint32),
        ("status", ctypes.c_uint32),
        ("xstatus", ctypes.c_uint32),
        ("pid", ctypes.c_uint32),
        ("ppid", ctypes.c_uint32),
        ("uid", ctypes.c_uint32),
        ("gid", ctypes.c_uint32),
        ("ruid", ctypes.c_uint32),
        ("rgid", ctypes.c_uint32),
        ("svuid", ctypes.c_uint32),
        ("svgid", ctypes.c_uint32),
        ("reserved", ctypes.c_uint32),
        ("command", ctypes.c_char * 16),
        ("name", ctypes.c_char * 32),
        ("file_count", ctypes.c_uint32),
        ("process_group", ctypes.c_uint32),
        ("job_control_count", ctypes.c_uint32),
        ("terminal_device", ctypes.c_uint32),
        ("terminal_process_group", ctypes.c_uint32),
        ("nice", ctypes.c_int32),
        ("start_seconds", ctypes.c_uint64),
        ("start_microseconds", ctypes.c_uint64),
    ]


def _libproc() -> ctypes.CDLL:
    try:
        library = ctypes.CDLL("/usr/lib/libproc.dylib", use_errno=True)
    except OSError as error:
        raise ProducerUnavailable(
            "geometry_adapter_process_tracking_unavailable"
        ) from error
    library.proc_listchildpids.argtypes = [
        ctypes.c_int,
        ctypes.c_void_p,
        ctypes.c_int,
    ]
    library.proc_listchildpids.restype = ctypes.c_int
    library.proc_pidinfo.argtypes = [
        ctypes.c_int,
        ctypes.c_int,
        ctypes.c_uint64,
        ctypes.c_void_p,
        ctypes.c_int,
    ]
    library.proc_pidinfo.restype = ctypes.c_int
    return library


def _process_identity(
    library: ctypes.CDLL,
    process_id: int,
) -> tuple[int, int, int] | None:
    info = _ProcBSDInfo()
    size = library.proc_pidinfo(
        process_id,
        3,
        0,
        ctypes.byref(info),
        ctypes.sizeof(info),
    )
    if size != ctypes.sizeof(info) or info.pid != process_id:
        return None
    return (int(info.uid), int(info.start_seconds), int(info.start_microseconds))


def _child_process_ids(library: ctypes.CDLL, process_id: int) -> list[int]:
    capacity = 4_096
    buffer = (ctypes.c_int * capacity)()
    count = library.proc_listchildpids(
        process_id,
        ctypes.byref(buffer),
        ctypes.sizeof(buffer),
    )
    if count < 0 or count >= capacity:
        raise ProducerUnavailable("geometry_adapter_process_tracking_unavailable")
    return [int(buffer[index]) for index in range(count) if buffer[index] > 0]


def _development_seed(index: int) -> int:
    digest = hashlib.sha256(
        b"easysplat-photo-permutation-development-seed-v1\0" + index.to_bytes(4, "big")
    ).digest()
    return int.from_bytes(digest[:8], "big") & ((1 << 63) - 1)


def variant_schedule(
    *,
    mode: str,
    shuffle_count: int,
    development_seeds: list[int] | None = None,
) -> list[VariantSpec]:
    if mode == "release":
        if shuffle_count != 19 or development_seeds is not None:
            raise ProducerError("release mode requires exactly 19 shuffles")
        seeds = [
            evidence.photo_permutation_release_seed(index) for index in range(1, 20)
        ]
    elif mode == "development":
        if type(shuffle_count) is not int or not 2 <= shuffle_count <= 99:
            raise ProducerError("development mode requires 2 through 99 shuffles")
        if development_seeds is None:
            seeds = [_development_seed(index) for index in range(1, shuffle_count + 1)]
        else:
            if len(development_seeds) != shuffle_count or any(
                type(seed) is not int or seed < 0 for seed in development_seeds
            ):
                raise ProducerError("development seeds are invalid")
            seeds = list(development_seeds)
    else:
        raise ProducerError("producer mode must be development or release")
    if len(seeds) != len(set(seeds)):
        raise ProducerError("photo permutation seeds must be unique")
    return [VariantSpec("canonical", 0, 0)] + [
        VariantSpec(f"shuffle-{index:02d}", index, seed)
        for index, seed in enumerate(seeds, start=1)
    ]


def single_variant_spec(
    *,
    mode: str,
    index: int,
    seed: int | None,
) -> VariantSpec:
    if index == 0:
        if seed not in (None, 0):
            raise ProducerError("canonical permutation seed must be zero")
        return VariantSpec("canonical", 0, 0)
    if mode == "release":
        if not 1 <= index <= 19:
            raise ProducerError("formal release permutation index is invalid")
        required_seed = evidence.photo_permutation_release_seed(index)
        if seed is not None and seed != required_seed:
            raise ProducerError(
                "formal release seed does not match the reviewed schedule"
            )
        return VariantSpec(f"shuffle-{index:02d}", index, required_seed)
    if mode != "development" or not 1 <= index <= 99:
        raise ProducerError("development permutation index is invalid")
    resolved_seed = _development_seed(index) if seed is None else seed
    if type(resolved_seed) is not int or resolved_seed < 0:
        raise ProducerError("development permutation seed is invalid")
    return VariantSpec(f"shuffle-{index:02d}", index, resolved_seed)


def _validated_manifest(
    manifest: Any,
    *,
    expected_source_kind: str | None = None,
) -> tuple[str, list[dict[str, str]]]:
    if not isinstance(manifest, dict) or set(manifest) != {
        "schema_version",
        "corpus_id",
        "provenance",
        "entries",
    }:
        raise ProducerError("private source manifest fields are invalid")
    if manifest["schema_version"] != 2:
        raise ProducerError("private source manifest schema is invalid")
    corpus_id = manifest["corpus_id"]
    provenance = manifest["provenance"]
    entries = manifest["entries"]
    if (
        not isinstance(corpus_id, str)
        or not corpus_id
        or not isinstance(entries, list)
        or not 2 <= len(entries) <= 100_000
    ):
        raise ProducerError("private source manifest is invalid")
    if not isinstance(provenance, dict) or set(provenance) != {
        "source_kind",
        "video_origin_count",
        "photo_origin_count",
        "origin_closure_sha256",
    }:
        raise ProducerError("private source origin provenance is invalid")
    source_kind = provenance["source_kind"]
    video_origin_count = provenance["video_origin_count"]
    photo_origin_count = provenance["photo_origin_count"]
    origin_closure = provenance["origin_closure_sha256"]
    if (
        source_kind not in evidence.PHOTO_PERMUTATION_SOURCE_KINDS
        or type(video_origin_count) is not int
        or video_origin_count < 0
        or type(photo_origin_count) is not int
        or photo_origin_count < 0
        or not isinstance(origin_closure, str)
        or evidence.SHA256_PATTERN.fullmatch(origin_closure) is None
    ):
        raise ProducerError("private source origin provenance is invalid")
    expected_counts = {
        "native_photos": video_origin_count == 0 and photo_origin_count == len(entries),
        "single_video_derived_stills": video_origin_count == 1
        and photo_origin_count == 0,
        "multi_video_derived_stills": video_origin_count >= 2
        and photo_origin_count == 0,
        "mixed_derived_stills": video_origin_count >= 1 and photo_origin_count >= 1,
        CALIBRATION_DATASET_SOURCE_KIND: video_origin_count == 0
        and photo_origin_count == 0,
    }
    if not expected_counts[source_kind]:
        raise ProducerError("private source origin provenance counts are invalid")
    if expected_source_kind is not None and source_kind != expected_source_kind:
        raise ProducerError(
            "declared source kind does not match bound origin provenance"
        )
    if source_kind == "native_photos":
        expected_origin_closure = evidence.sha256_bytes(
            evidence.canonical_json_bytes(
                [
                    {"kind": "native_photo", "source_sha256": source_sha256}
                    for source_sha256 in sorted(
                        entry["source_sha256"] for entry in entries
                    )
                ]
            )
        )
        if origin_closure != expected_origin_closure:
            raise ProducerError("native photo origin provenance closure is invalid")
    elif source_kind == CALIBRATION_DATASET_SOURCE_KIND:
        if origin_closure != TUMVI_SUPPORTED_CROP_MANIFEST_SHA256:
            raise ProducerError("calibration crop origin provenance closure is invalid")
        output_set_digest = evidence.sha256_bytes(
            evidence.canonical_json_bytes(entries)
        )
        if (
            len(entries) != TUMVI_SUPPORTED_CROP_OUTPUT_COUNT
            or output_set_digest != TUMVI_SUPPORTED_CROP_OUTPUT_SET_SHA256
        ):
            raise ProducerError("calibration crop output set is invalid")
    # Reuse the protocol's strict path, extension, uniqueness, and digest checks.
    try:
        evidence.build_photo_permutation_mapping(
            {
                "schema_version": 1,
                "corpus_id": corpus_id,
                "entries": entries,
            },
            scale=max(2, len(entries)),
            permutation_index=1,
            permutation_seed=0,
        )
    except evidence.EvidenceError as error:
        raise ProducerError(str(error)) from error
    return corpus_id, [dict(entry) for entry in entries]


def _directory_metadata_identity(
    metadata: os.stat_result,
) -> tuple[int, int, int, int, int]:
    return (
        metadata.st_dev,
        metadata.st_ino,
        metadata.st_mtime_ns,
        metadata.st_ctime_ns,
        metadata.st_nlink,
    )


def _inventory_source_provenance(
    entries: list[dict[str, str]],
    *,
    source_kind: str,
    origin_manifest: Any | None,
    origin_manifest_file_sha256: str | None = None,
    entry_byte_counts: Mapping[str, int] | None = None,
) -> dict[str, Any]:
    if source_kind not in evidence.PHOTO_PERMUTATION_SOURCE_KINDS:
        raise ProducerError("inventory source kind is invalid")
    if source_kind == CALIBRATION_DATASET_SOURCE_KIND:
        return _validated_calibration_crop_provenance(
            entries,
            origin_manifest=origin_manifest,
            origin_manifest_file_sha256=origin_manifest_file_sha256,
            entry_byte_counts=entry_byte_counts,
        )
    if (
        not isinstance(origin_manifest, dict)
        or set(origin_manifest) != {"schema_version", "sources"}
        or origin_manifest.get("schema_version") != 1
        or not isinstance(origin_manifest.get("sources"), list)
        or not 1 <= len(origin_manifest["sources"]) <= 10_000
    ):
        raise ProducerError("derived origin manifest is invalid")
    normalized: list[dict[str, str]] = []
    digests: set[str] = set()
    for index, raw in enumerate(origin_manifest["sources"]):
        if (
            not isinstance(raw, dict)
            or set(raw) != {"kind", "source_sha256"}
            or raw.get("kind") not in {"video", "native_photo"}
            or not isinstance(raw.get("source_sha256"), str)
            or evidence.SHA256_PATTERN.fullmatch(raw["source_sha256"]) is None
            or raw["source_sha256"] in digests
        ):
            raise ProducerError(f"derived origin manifest source {index} is invalid")
        digests.add(raw["source_sha256"])
        normalized.append(dict(raw))
    normalized.sort(key=lambda item: (item["kind"], item["source_sha256"]))
    video_count = sum(item["kind"] == "video" for item in normalized)
    photo_count = sum(item["kind"] == "native_photo" for item in normalized)
    valid_class = {
        "native_photos": video_count == 0 and photo_count == len(entries),
        "single_video_derived_stills": video_count == 1 and photo_count == 0,
        "multi_video_derived_stills": video_count >= 2 and photo_count == 0,
        "mixed_derived_stills": video_count >= 1 and photo_count >= 1,
    }[source_kind]
    if not valid_class:
        raise ProducerError("derived origin class does not match the source kind")
    if source_kind == "native_photos" and [
        item["source_sha256"] for item in normalized
    ] != sorted(entry["source_sha256"] for entry in entries):
        raise ProducerError("native photo origins do not match the inventoried files")
    return {
        "source_kind": source_kind,
        "video_origin_count": video_count,
        "photo_origin_count": photo_count,
        "origin_closure_sha256": evidence.sha256_bytes(
            evidence.canonical_json_bytes(normalized)
        ),
    }


def _validated_calibration_crop_provenance(
    entries: list[dict[str, str]],
    *,
    origin_manifest: Any,
    origin_manifest_file_sha256: str | None,
    entry_byte_counts: Mapping[str, int] | None,
) -> dict[str, Any]:
    fields = {
        "schema_version",
        "source",
        "purpose",
        "source_directory",
        "crop_pixels",
        "maximum_corner_bearing_degrees",
        "maximum_diagonal_field_of_view_degrees",
        "official_camera_model",
        "official_parameters",
        "entries",
    }
    if not isinstance(origin_manifest, dict) or set(origin_manifest) != fields:
        raise ProducerError("calibration crop manifest fields are invalid")
    expected_scalars = {
        "schema_version": 1,
        "source": "TUM-VI room1 512x512 camera 0 deterministic 120-frame subset",
        "purpose": "COLMAP forward-hemisphere positive fisheye control",
        "maximum_corner_bearing_degrees": 87.45876195189696,
        "maximum_diagonal_field_of_view_degrees": 174.91752390379392,
        "official_camera_model": "equidistant",
    }
    if any(
        origin_manifest.get(key) != value for key, value in expected_scalars.items()
    ):
        raise ProducerError("calibration crop manifest identity is invalid")
    if origin_manifest.get("crop_pixels") != {
        "left": 52,
        "top": 52,
        "width": 408,
        "height": 408,
    }:
        raise ProducerError("calibration crop rectangle is invalid")
    if origin_manifest.get("official_parameters") != [
        190.97847715128717,
        190.9733070521226,
        254.93170605935475,
        256.8974428996504,
        0.0034823894022493434,
        0.0007150348452162257,
        -0.0020532361418706202,
        0.00020293673591811182,
    ]:
        raise ProducerError("calibration crop camera parameters are invalid")
    source_directory = origin_manifest.get("source_directory")
    if (
        not isinstance(source_directory, str)
        or not source_directory.startswith("/")
        or "\x00" in source_directory
    ):
        raise ProducerError("calibration crop source directory is invalid")
    raw_outputs = origin_manifest.get("entries")
    if (
        not isinstance(raw_outputs, list)
        or len(raw_outputs) != TUMVI_SUPPORTED_CROP_OUTPUT_COUNT
    ):
        raise ProducerError("calibration crop output set is invalid")
    outputs: list[dict[str, Any]] = []
    names: set[str] = set()
    output_hashes: set[str] = set()
    source_hashes: set[str] = set()
    for index, raw in enumerate(raw_outputs):
        if not isinstance(raw, dict) or set(raw) != {
            "name",
            "output_bytes",
            "output_sha256",
            "source_sha256",
        }:
            raise ProducerError(f"calibration crop output {index} fields are invalid")
        name = raw.get("name")
        output_bytes = raw.get("output_bytes")
        output_sha256 = raw.get("output_sha256")
        source_sha256 = raw.get("source_sha256")
        if (
            not isinstance(name, str)
            or not name
            or Path(name).name != name
            or Path(name).suffix.lower() != ".png"
            or type(output_bytes) is not int
            or output_bytes <= 0
            or not isinstance(output_sha256, str)
            or evidence.SHA256_PATTERN.fullmatch("sha256:" + output_sha256) is None
            or not isinstance(source_sha256, str)
            or evidence.SHA256_PATTERN.fullmatch("sha256:" + source_sha256) is None
            or name in names
            or output_sha256 in output_hashes
            or source_sha256 in source_hashes
        ):
            raise ProducerError(f"calibration crop output {index} is invalid")
        names.add(name)
        output_hashes.add(output_sha256)
        source_hashes.add(source_sha256)
        outputs.append(dict(raw))
    if [item["name"] for item in outputs] != sorted(names):
        raise ProducerError(
            "calibration crop outputs are not deterministically ordered"
        )
    if (
        sum(item["output_bytes"] for item in outputs)
        != TUMVI_SUPPORTED_CROP_TOTAL_BYTES
    ):
        raise ProducerError("calibration crop output byte closure is invalid")

    expected_entries = [
        {
            "relative_path": output["name"],
            "source_sha256": "sha256:" + output["output_sha256"],
        }
        for output in outputs
    ]
    if entries != expected_entries:
        raise ProducerError("calibration crop output set is invalid")
    if entry_byte_counts is None or any(
        entry_byte_counts.get(output["name"]) != output["output_bytes"]
        for output in outputs
    ):
        raise ProducerError("calibration crop output byte set is invalid")
    output_set_digest = evidence.sha256_bytes(
        evidence.canonical_json_bytes(expected_entries)
    )
    if output_set_digest != TUMVI_SUPPORTED_CROP_OUTPUT_SET_SHA256:
        raise ProducerError("calibration crop output set is invalid")

    canonical_origin_bytes = evidence.canonical_json_bytes(origin_manifest) + b"\n"
    canonical_origin_sha256 = evidence.sha256_bytes(canonical_origin_bytes)
    if (
        origin_manifest_file_sha256 != canonical_origin_sha256
        or canonical_origin_sha256 != TUMVI_SUPPORTED_CROP_MANIFEST_SHA256
    ):
        raise ProducerError("calibration crop manifest digest is invalid")
    return {
        "source_kind": CALIBRATION_DATASET_SOURCE_KIND,
        "video_origin_count": 0,
        "photo_origin_count": 0,
        "origin_closure_sha256": canonical_origin_sha256,
    }


def inventory_source_manifest(
    source_root: Path,
    *,
    corpus_id: str,
    source_kind: str,
    origin_manifest: Any,
    origin_manifest_file_sha256: str | None = None,
) -> dict[str, Any]:
    if (
        not isinstance(corpus_id, str)
        or evidence.SAFE_TOKEN_PATTERN.fullmatch(corpus_id) is None
    ):
        raise ProducerError("inventory corpus ID is invalid")
    source_root = _require_plain_directory(source_root, "inventory source root")
    root_descriptor = _open_plain_directory_descriptor(source_root)
    root_before = os.fstat(root_descriptor)
    entries: list[dict[str, str]] = []
    seen_digests: set[str] = set()
    path_count = 0
    total_bytes = 0
    entry_byte_counts: dict[str, int] = {}

    def walk(directory_descriptor: int, relative_parts: tuple[str, ...]) -> None:
        nonlocal path_count, total_bytes
        directory_before = os.fstat(directory_descriptor)
        try:
            children = sorted(
                os.scandir(directory_descriptor), key=lambda item: item.name
            )
        except OSError as error:
            raise ProducerUnavailable("inventory_directory_read_failed") from error
        for child in children:
            path_count += 1
            if path_count > 100_000:
                raise ProducerUnavailable("inventory_too_large")
            try:
                child_before = child.stat(follow_symlinks=False)
            except OSError as error:
                raise ProducerUnavailable("inventory_entry_unavailable") from error
            if stat.S_ISLNK(child_before.st_mode):
                raise ProducerUnavailable("inventory_symlink_rejected")
            child_parts = (*relative_parts, child.name)
            if stat.S_ISDIR(child_before.st_mode):
                if source_kind == CALIBRATION_DATASET_SOURCE_KIND:
                    raise ProducerUnavailable("calibration_crop_output_set_mismatch")
                try:
                    child_descriptor = os.open(
                        child.name,
                        os.O_RDONLY
                        | os.O_CLOEXEC
                        | getattr(os, "O_DIRECTORY", 0)
                        | getattr(os, "O_NOFOLLOW", 0),
                        dir_fd=directory_descriptor,
                    )
                except OSError as error:
                    raise ProducerUnavailable("inventory_entry_unavailable") from error
                try:
                    if (
                        child_before.st_dev,
                        child_before.st_ino,
                    ) != (
                        os.fstat(child_descriptor).st_dev,
                        os.fstat(child_descriptor).st_ino,
                    ):
                        raise ProducerUnavailable("inventory_path_changed")
                    walk(child_descriptor, child_parts)
                finally:
                    os.close(child_descriptor)
                try:
                    child_after = os.stat(
                        child.name,
                        dir_fd=directory_descriptor,
                        follow_symlinks=False,
                    )
                except OSError as error:
                    raise ProducerUnavailable("inventory_path_changed") from error
                if _directory_metadata_identity(
                    child_before
                ) != _directory_metadata_identity(child_after):
                    raise ProducerUnavailable("inventory_path_changed")
                continue
            if not stat.S_ISREG(child_before.st_mode):
                raise ProducerUnavailable("inventory_unsafe_entry")
            relative_path = Path(*child_parts)
            if relative_path.suffix.lower() not in SUPPORTED_STILL_EXTENSIONS:
                if source_kind == CALIBRATION_DATASET_SOURCE_KIND:
                    raise ProducerUnavailable("calibration_crop_output_set_mismatch")
                continue
            try:
                descriptor = os.open(
                    child.name,
                    os.O_RDONLY | os.O_CLOEXEC | getattr(os, "O_NOFOLLOW", 0),
                    dir_fd=directory_descriptor,
                )
            except OSError as error:
                raise ProducerUnavailable("inventory_entry_unavailable") from error
            try:
                opened = os.fstat(descriptor)
                if (
                    child_before.st_dev,
                    child_before.st_ino,
                ) != (opened.st_dev, opened.st_ino):
                    raise ProducerUnavailable("inventory_path_changed")
                snapshot, _ = _hash_open_descriptor(
                    descriptor,
                    maximum_bytes=MAXIMUM_SOURCE_FILE_BYTES,
                    capture_bytes=False,
                    require_single_link=False,
                )
            finally:
                os.close(descriptor)
            try:
                child_after = os.stat(
                    child.name,
                    dir_fd=directory_descriptor,
                    follow_symlinks=False,
                )
            except OSError as error:
                raise ProducerUnavailable("inventory_path_changed") from error
            if not _snapshot_matches_metadata(snapshot, child_after):
                raise ProducerUnavailable("inventory_path_changed")
            if snapshot.sha256 in seen_digests:
                raise ProducerUnavailable("inventory_duplicate_content")
            seen_digests.add(snapshot.sha256)
            total_bytes += snapshot.byte_count
            if total_bytes > MAXIMUM_SOURCE_CLOSURE_BYTES:
                raise ProducerUnavailable("inventory_too_large")
            entries.append(
                {
                    "relative_path": relative_path.as_posix(),
                    "source_sha256": snapshot.sha256,
                }
            )
            entry_byte_counts[relative_path.as_posix()] = snapshot.byte_count
        if _directory_metadata_identity(
            directory_before
        ) != _directory_metadata_identity(os.fstat(directory_descriptor)):
            raise ProducerUnavailable("inventory_path_changed")

    try:
        walk(root_descriptor, ())
    finally:
        os.close(root_descriptor)
    final_root_descriptor = _open_plain_directory_descriptor(source_root)
    try:
        root_after = os.fstat(final_root_descriptor)
    finally:
        os.close(final_root_descriptor)
    if _directory_metadata_identity(root_before) != _directory_metadata_identity(
        root_after
    ):
        raise ProducerUnavailable("inventory_path_changed")
    sorted_entries = sorted(entries, key=lambda item: item["relative_path"])
    manifest = {
        "schema_version": 2,
        "corpus_id": corpus_id,
        "provenance": _inventory_source_provenance(
            sorted_entries,
            source_kind=source_kind,
            origin_manifest=origin_manifest,
            origin_manifest_file_sha256=origin_manifest_file_sha256,
            entry_byte_counts=entry_byte_counts,
        ),
        "entries": sorted_entries,
    }
    _validated_manifest(manifest)
    return manifest


def dry_run_plan(
    manifest: Any,
    request: Mapping[str, Any],
    *,
    mode: str,
    shuffle_count: int,
    source_kind: str,
) -> dict[str, Any]:
    _, entries = _validated_manifest(
        manifest,
        expected_source_kind=source_kind,
    )
    try:
        scale, _, _ = evidence._photo_permutation_request_contract(request)
    except evidence.EvidenceError as error:
        raise ProducerError(str(error)) from error
    if source_kind not in evidence.PHOTO_PERMUTATION_SOURCE_KINDS:
        raise ProducerError("source kind is invalid")
    schedule = variant_schedule(mode=mode, shuffle_count=shuffle_count)
    return {
        "schema_version": 1,
        "evidence_status": (
            "unsealed_formal_schedule" if mode == "release" else "development_only"
        ),
        "mode": mode,
        "source_kind": source_kind,
        "closure_claims": (
            ["order_mechanics"]
            if source_kind != "native_photos"
            else ["order_mechanics"]
        ),
        "source_count": len(entries),
        "selected_scale": scale,
        "variant_count": len(schedule),
        "variants": [
            {"variant_id": spec.variant_id, "permutation": spec.public_permutation}
            for spec in schedule
        ],
    }


GROUP_CONTRACT_FIELDS = {
    "schema_version",
    "kind",
    "producer_version",
    "producer_implementation_sha256",
    "protocol_version",
    "source_manifest_sha256",
    "source_content_set_sha256",
    "request_file_sha256",
    "request_semantic_sha256",
    "request_binding_sha256",
    "source_authorization_sha256",
    "requested_plan_sha256",
    "group_id",
    "source_kind",
    "mode",
    "variant_schedule",
    "adapter_sha256",
    "toolchain_closure_sha256",
    "contract_sha256",
}

SOURCE_AUTHORIZATION_FIELDS = {
    "schema_version",
    "kind",
    "request_binding_sha256",
    "source_kind",
    "source_manifest_sha256",
    "source_content_set_sha256",
    "origin_evidence_sha256",
    "adapter_sha256",
    "toolchain_closure_sha256",
    "containment_supervisor_sha256",
    "containment_policy_sha256",
    "dedicated_uid",
    "gh_verifier_sha256",
    "source_commit",
    "source_ref",
}


def _validated_source_authorization_digest(
    authorization: Any,
    *,
    manifest: Mapping[str, Any],
    entries: list[dict[str, Any]],
    request: Mapping[str, Any],
    source_kind: str,
    adapter_sha256: str,
    toolchain_closure_sha256: str,
) -> str:
    if (
        not isinstance(authorization, dict)
        or set(authorization) != SOURCE_AUTHORIZATION_FIELDS
    ):
        raise ProducerError("formal source authorization fields are invalid")
    binding = request.get("binding")
    if (
        not isinstance(binding, Mapping)
        or binding.get("profile") != "release"
        or binding.get("lane") != evidence.LANE_REFERENCE
        or not isinstance(binding.get("git_commit"), str)
        or len(binding["git_commit"]) != 40
        or any(
            character not in "0123456789abcdef" for character in binding["git_commit"]
        )
    ):
        raise ProducerError("formal source authorization request binding is invalid")
    expected = {
        "schema_version": 1,
        "kind": "easysplat-photo-permutation-source-authorization",
        "request_binding_sha256": evidence.photo_permutation_request_binding_sha256(
            request
        ),
        "source_kind": source_kind,
        "source_manifest_sha256": evidence.sha256_bytes(
            evidence.canonical_json_bytes(manifest) + b"\n"
        ),
        "source_content_set_sha256": evidence.sha256_bytes(
            evidence.canonical_json_bytes(
                sorted(entry["source_sha256"] for entry in entries)
            )
        ),
        "origin_evidence_sha256": evidence.sha256_bytes(
            evidence.canonical_json_bytes(manifest["provenance"])
        ),
        "adapter_sha256": adapter_sha256,
        "toolchain_closure_sha256": toolchain_closure_sha256,
        "source_commit": binding.get("git_commit"),
        "source_ref": "refs/heads/main",
    }
    if any(authorization.get(field) != value for field, value in expected.items()):
        raise ProducerError(
            "formal source authorization does not match protected inputs"
        )
    for field in (
        "containment_supervisor_sha256",
        "containment_policy_sha256",
        "gh_verifier_sha256",
    ):
        value = authorization.get(field)
        if (
            not isinstance(value, str)
            or evidence.SHA256_PATTERN.fullmatch(value) is None
        ):
            raise ProducerError(
                "formal source authorization runtime authority is invalid"
            )
    if (
        type(authorization.get("dedicated_uid")) is not int
        or authorization["dedicated_uid"] <= 0
    ):
        raise ProducerError("formal source authorization dedicated UID is invalid")
    return evidence.sha256_bytes(evidence.canonical_json_bytes(authorization) + b"\n")


def build_group_contract(
    *,
    manifest: Any,
    request: Mapping[str, Any],
    request_file_sha256: str,
    group_id: str,
    source_kind: str,
    mode: str,
    shuffle_count: int,
    adapter_sha256: str,
    toolchain_closure_sha256: str,
    producer_implementation_sha256: str | None = None,
    source_authorization_sha256: str | None = None,
    source_authorization: Mapping[str, Any] | None = None,
) -> dict[str, Any]:
    _, entries = _validated_manifest(
        manifest,
        expected_source_kind=source_kind,
    )
    try:
        _, _, plan_digest = evidence._photo_permutation_request_contract(request)
    except evidence.EvidenceError as error:
        raise ProducerError(str(error)) from error
    implementation_digest = (
        _producer_implementation_closure()[0]
        if producer_implementation_sha256 is None
        else producer_implementation_sha256
    )
    for value, label in (
        (request_file_sha256, "request file"),
        (adapter_sha256, "adapter"),
        (toolchain_closure_sha256, "toolchain closure"),
        (implementation_digest, "producer implementation"),
    ):
        if (
            not isinstance(value, str)
            or evidence.SHA256_PATTERN.fullmatch(value) is None
        ):
            raise ProducerError(f"{label} digest is invalid")
    if source_authorization_sha256 is not None and (
        not isinstance(source_authorization_sha256, str)
        or evidence.SHA256_PATTERN.fullmatch(source_authorization_sha256) is None
    ):
        raise ProducerError("source authorization digest is invalid")
    if mode == "release" and source_authorization is None:
        raise ProducerError("formal source authorization is required")
    if source_authorization is not None:
        validated_authorization_digest = _validated_source_authorization_digest(
            source_authorization,
            manifest=manifest,
            entries=entries,
            request=request,
            source_kind=source_kind,
            adapter_sha256=adapter_sha256,
            toolchain_closure_sha256=toolchain_closure_sha256,
        )
        if (
            source_authorization_sha256 is not None
            and source_authorization_sha256 != validated_authorization_digest
        ):
            raise ProducerError(
                "source authorization digest does not match its artifact"
            )
        source_authorization_sha256 = validated_authorization_digest
    if (
        not isinstance(group_id, str)
        or evidence.SAFE_TOKEN_PATTERN.fullmatch(group_id) is None
    ):
        raise ProducerError("group ID is invalid")
    if source_kind not in evidence.PHOTO_PERMUTATION_SOURCE_KINDS:
        raise ProducerError("source kind is invalid")
    schedule = variant_schedule(mode=mode, shuffle_count=shuffle_count)
    unsigned = {
        "schema_version": 1,
        "kind": "easysplat-private-photo-permutation-group-contract",
        "producer_version": evidence.PRODUCER_VERSION,
        "producer_implementation_sha256": implementation_digest,
        "protocol_version": evidence.PROTOCOL_VERSION,
        "source_manifest_sha256": evidence.sha256_bytes(
            evidence.canonical_json_bytes(manifest) + b"\n"
        ),
        "source_content_set_sha256": evidence.sha256_bytes(
            evidence.canonical_json_bytes(
                sorted(entry["source_sha256"] for entry in entries)
            )
        ),
        "request_file_sha256": request_file_sha256,
        "request_semantic_sha256": evidence.sha256_bytes(
            evidence.canonical_json_bytes(request)
        ),
        "request_binding_sha256": evidence.photo_permutation_request_binding_sha256(
            request
        ),
        "source_authorization_sha256": (
            source_authorization_sha256
            if source_authorization_sha256 is not None
            else evidence.sha256_bytes(
                b"easysplat-untrusted-source-authorization-v1\0"
                + evidence.canonical_json_bytes(manifest["provenance"])
            )
        ),
        "requested_plan_sha256": plan_digest,
        "group_id": group_id,
        "source_kind": source_kind,
        "mode": mode,
        "variant_schedule": [
            {"variant_id": spec.variant_id, "permutation": spec.public_permutation}
            for spec in schedule
        ],
        "adapter_sha256": adapter_sha256,
        "toolchain_closure_sha256": toolchain_closure_sha256,
    }
    return {
        **unsigned,
        "contract_sha256": evidence.sha256_bytes(
            evidence.canonical_json_bytes(unsigned)
        ),
    }


def _validated_group_contract(contract: Any) -> dict[str, Any]:
    if not isinstance(contract, dict) or set(contract) != GROUP_CONTRACT_FIELDS:
        raise ProducerError("private group contract fields are invalid")
    unsigned = {
        key: value for key, value in contract.items() if key != "contract_sha256"
    }
    expected = evidence.sha256_bytes(evidence.canonical_json_bytes(unsigned))
    if contract.get("contract_sha256") != expected:
        raise ProducerError("private group contract digest is invalid")
    if (
        contract.get("schema_version") != 1
        or contract.get("kind") != "easysplat-private-photo-permutation-group-contract"
        or contract.get("producer_version") != evidence.PRODUCER_VERSION
        or contract.get("protocol_version") != evidence.PROTOCOL_VERSION
    ):
        raise ProducerError("private group contract version is invalid")
    return dict(contract)


def ensure_group_contract(state_root: Path, contract: Any) -> str:
    state_root = _ensure_private_directory(state_root, "producer state root")
    validated = _validated_group_contract(contract)
    contract_path = state_root / "group-contract.json"
    if contract_path.exists() or contract_path.is_symlink():
        existing = _load_bounded_json(
            contract_path,
            maximum_bytes=MAXIMUM_PRIVATE_JSON_BYTES,
        )
        existing = _validated_group_contract(existing)
        if existing != validated:
            raise ProducerError("private group contract mismatch")
        return validated["contract_sha256"]
    if any(state_root.iterdir()):
        raise ProducerError(
            "nonempty producer state root has no immutable group contract"
        )
    write_private_json(contract_path, validated)
    return validated["contract_sha256"]


def _metadata_identity(
    metadata: os.stat_result,
) -> tuple[int, int, int, int, int, int, int]:
    return (
        metadata.st_dev,
        metadata.st_ino,
        metadata.st_size,
        metadata.st_mtime_ns,
        metadata.st_ctime_ns,
        metadata.st_nlink,
        stat.S_IMODE(metadata.st_mode),
    )


def _snapshot_matches_metadata(
    snapshot: FileSnapshot, metadata: os.stat_result
) -> bool:
    return (
        snapshot.device,
        snapshot.inode,
        snapshot.byte_count,
        snapshot.mtime_ns,
        snapshot.ctime_ns,
        snapshot.link_count,
        snapshot.permission_mode,
    ) == _metadata_identity(metadata)


def _hash_open_descriptor(
    descriptor: int,
    *,
    maximum_bytes: int,
    capture_bytes: bool,
    require_single_link: bool,
) -> tuple[FileSnapshot, bytes | None]:
    before = os.fstat(descriptor)
    if (
        not stat.S_ISREG(before.st_mode)
        or not 0 < before.st_size <= maximum_bytes
        or require_single_link
        and before.st_nlink != 1
    ):
        raise ProducerUnavailable("source_file_unsafe")
    os.lseek(descriptor, 0, os.SEEK_SET)
    digest = hashlib.sha256()
    captured = bytearray() if capture_bytes else None
    byte_count = 0
    while True:
        chunk = os.read(descriptor, min(1024 * 1024, maximum_bytes + 1 - byte_count))
        if not chunk:
            break
        byte_count += len(chunk)
        if byte_count > maximum_bytes:
            raise ProducerUnavailable("source_file_unsafe")
        digest.update(chunk)
        if captured is not None:
            captured.extend(chunk)
    after = os.fstat(descriptor)
    if (
        _metadata_identity(before) != _metadata_identity(after)
        or byte_count != before.st_size
    ):
        raise ProducerUnavailable("source_changed_during_read")
    return (
        FileSnapshot(
            sha256="sha256:" + digest.hexdigest(),
            byte_count=byte_count,
            device=after.st_dev,
            inode=after.st_ino,
            mtime_ns=after.st_mtime_ns,
            ctime_ns=after.st_ctime_ns,
            link_count=after.st_nlink,
            permission_mode=stat.S_IMODE(after.st_mode),
        ),
        bytes(captured) if captured is not None else None,
    )


def _secure_regular_file(
    path: Path,
    *,
    maximum_bytes: int,
    capture_bytes: bool,
    require_single_link: bool,
) -> tuple[FileSnapshot, bytes | None]:
    try:
        path_before = path.lstat()
        descriptor = os.open(
            path,
            os.O_RDONLY | os.O_CLOEXEC | getattr(os, "O_NOFOLLOW", 0),
        )
    except OSError as error:
        raise ProducerUnavailable("source_read_failed") from error
    try:
        before = os.fstat(descriptor)
        if (
            stat.S_ISLNK(path_before.st_mode)
            or not stat.S_ISREG(path_before.st_mode)
            or (path_before.st_dev, path_before.st_ino)
            != (before.st_dev, before.st_ino)
        ):
            raise ProducerUnavailable("source_file_unsafe")
        snapshot, captured = _hash_open_descriptor(
            descriptor,
            maximum_bytes=maximum_bytes,
            capture_bytes=capture_bytes,
            require_single_link=require_single_link,
        )
        try:
            path_after = path.lstat()
        except OSError as error:
            raise ProducerUnavailable("source_changed_during_read") from error
        if not _snapshot_matches_metadata(snapshot, path_after):
            raise ProducerUnavailable("source_changed_during_read")
        return snapshot, captured
    finally:
        os.close(descriptor)


def _sha256_file(
    path: Path, *, maximum_bytes: int = MAXIMUM_SOURCE_FILE_BYTES
) -> tuple[str, FileSnapshot]:
    snapshot, _ = _secure_regular_file(
        path,
        maximum_bytes=maximum_bytes,
        capture_bytes=False,
        require_single_link=False,
    )
    return snapshot.sha256, snapshot


def _producer_implementation_closure() -> tuple[
    str, tuple[tuple[Path, FileSnapshot], ...]
]:
    paths = (
        (
            "photo_permutation_producer.py",
            Path(__file__).resolve(),
            _IMPORTED_IMPLEMENTATION_RECORDS[0],
        ),
        (
            "evidence_protocol.py",
            Path(evidence.__file__).resolve(),
            _IMPORTED_IMPLEMENTATION_RECORDS[1],
        ),
    )
    snapshots: list[tuple[Path, FileSnapshot]] = []
    for _label, path, imported in paths:
        snapshot, _ = _secure_regular_file(
            path,
            maximum_bytes=64 * 1024 * 1024,
            capture_bytes=False,
            require_single_link=True,
        )
        if (
            snapshot.byte_count != imported["bytes"]
            or snapshot.sha256 != imported["sha256"]
        ):
            raise ProducerUnavailable("producer_implementation_changed_after_import")
        snapshots.append((path, snapshot))
    return (
        evidence.sha256_bytes(
            evidence.canonical_json_bytes(list(_IMPORTED_IMPLEMENTATION_RECORDS))
        ),
        tuple(snapshots),
    )


def _open_plain_directory_descriptor(path: Path) -> int:
    try:
        path_metadata = path.lstat()
        descriptor = os.open(
            path,
            os.O_RDONLY
            | os.O_CLOEXEC
            | getattr(os, "O_DIRECTORY", 0)
            | getattr(os, "O_NOFOLLOW", 0),
        )
    except OSError as error:
        raise ProducerUnavailable("source_file_unavailable") from error
    metadata = os.fstat(descriptor)
    if (
        stat.S_ISLNK(path_metadata.st_mode)
        or not stat.S_ISDIR(path_metadata.st_mode)
        or not stat.S_ISDIR(metadata.st_mode)
        or (path_metadata.st_dev, path_metadata.st_ino)
        != (metadata.st_dev, metadata.st_ino)
    ):
        os.close(descriptor)
        raise ProducerUnavailable("source_file_unsafe")
    return descriptor


def _open_manifest_source_descriptor(source_root: Path, relative_path: str) -> int:
    parts = Path(relative_path).parts
    directory_descriptor = _open_plain_directory_descriptor(source_root)
    try:
        for component in parts[:-1]:
            try:
                next_descriptor = os.open(
                    component,
                    os.O_RDONLY
                    | os.O_CLOEXEC
                    | getattr(os, "O_DIRECTORY", 0)
                    | getattr(os, "O_NOFOLLOW", 0),
                    dir_fd=directory_descriptor,
                )
            except OSError as error:
                raise ProducerUnavailable("source_file_unavailable") from error
            next_metadata = os.fstat(next_descriptor)
            if not stat.S_ISDIR(next_metadata.st_mode):
                os.close(next_descriptor)
                raise ProducerUnavailable("source_file_unsafe")
            os.close(directory_descriptor)
            directory_descriptor = next_descriptor
        try:
            descriptor = os.open(
                parts[-1],
                os.O_RDONLY | os.O_CLOEXEC | getattr(os, "O_NOFOLLOW", 0),
                dir_fd=directory_descriptor,
            )
        except OSError as error:
            raise ProducerUnavailable("source_file_unavailable") from error
        if not stat.S_ISREG(os.fstat(descriptor).st_mode):
            os.close(descriptor)
            raise ProducerUnavailable("source_file_unsafe")
        return descriptor
    finally:
        os.close(directory_descriptor)


def _capture_manifest_sources(
    manifest: Any, source_root: Path
) -> tuple[str, tuple[tuple[str, FileSnapshot], ...]]:
    _, entries = _validated_manifest(manifest)
    source_root = _require_plain_directory(source_root, "source root")
    verified: list[dict[str, Any]] = []
    snapshots: list[tuple[str, FileSnapshot]] = []
    for entry in sorted(entries, key=lambda item: item["source_sha256"]):
        descriptor = _open_manifest_source_descriptor(
            source_root, entry["relative_path"]
        )
        try:
            snapshot, _ = _hash_open_descriptor(
                descriptor,
                maximum_bytes=MAXIMUM_SOURCE_FILE_BYTES,
                capture_bytes=False,
                require_single_link=False,
            )
        finally:
            os.close(descriptor)
        if snapshot.sha256 != entry["source_sha256"]:
            raise ProducerUnavailable("source_digest_mismatch")
        verified.append(
            {
                "source_sha256": snapshot.sha256,
                "byte_count": snapshot.byte_count,
            }
        )
        snapshots.append((entry["relative_path"], snapshot))
    return (
        evidence.sha256_bytes(evidence.canonical_json_bytes(verified)),
        tuple(snapshots),
    )


def _revalidate_manifest_sources(
    source_root: Path, snapshots: tuple[tuple[str, FileSnapshot], ...]
) -> None:
    source_root = _require_plain_directory(source_root, "source root")
    for relative_path, expected in snapshots:
        descriptor = _open_manifest_source_descriptor(source_root, relative_path)
        try:
            current = os.fstat(descriptor)
        finally:
            os.close(descriptor)
        if not _snapshot_matches_metadata(expected, current):
            raise ProducerUnavailable("source_changed_after_contract")


def _directory_snapshot(path: Path, relative_path: str) -> DirectorySnapshot:
    descriptor = _open_plain_directory_descriptor(path)
    try:
        metadata = os.fstat(descriptor)
    finally:
        os.close(descriptor)
    return DirectorySnapshot(
        relative_path=relative_path,
        device=metadata.st_dev,
        inode=metadata.st_ino,
        mtime_ns=metadata.st_mtime_ns,
        ctime_ns=metadata.st_ctime_ns,
        permission_mode=stat.S_IMODE(metadata.st_mode),
    )


def _capture_toolchain_closure(
    root: Path,
) -> tuple[
    str,
    tuple[tuple[str, FileSnapshot], ...],
    tuple[DirectorySnapshot, ...],
]:
    root = _require_plain_directory(root, "toolchain root")
    records: list[dict[str, Any]] = []
    files: list[tuple[str, FileSnapshot]] = []
    directories = [_directory_snapshot(root, ".")]
    total_bytes = 0
    path_count = 0
    for directory, directory_names, file_names in os.walk(root, followlinks=False):
        directory_path = Path(directory)
        directory_names.sort()
        file_names.sort()
        for name in directory_names:
            path = directory_path / name
            metadata = path.lstat()
            if stat.S_ISLNK(metadata.st_mode) or not stat.S_ISDIR(metadata.st_mode):
                raise ProducerError("toolchain closure contains an unsafe directory")
            records.append(
                {
                    "kind": "directory",
                    "path": path.relative_to(root).as_posix(),
                    "mode": stat.S_IMODE(metadata.st_mode),
                }
            )
            directories.append(
                _directory_snapshot(path, path.relative_to(root).as_posix())
            )
            path_count += 1
        for name in file_names:
            path = directory_path / name
            try:
                snapshot, _ = _secure_regular_file(
                    path,
                    maximum_bytes=32 * 1024 * 1024 * 1024,
                    capture_bytes=False,
                    require_single_link=True,
                )
            except ProducerUnavailable as error:
                raise ProducerError(
                    "toolchain closure contains an unsafe file"
                ) from error
            records.append(
                {
                    "kind": "file",
                    "path": path.relative_to(root).as_posix(),
                    "byte_count": snapshot.byte_count,
                    "sha256": snapshot.sha256,
                    "mode": snapshot.permission_mode,
                }
            )
            files.append((path.relative_to(root).as_posix(), snapshot))
            path_count += 1
            total_bytes += snapshot.byte_count
        if path_count > 100_000 or total_bytes > 64 * 1024 * 1024 * 1024:
            raise ProducerError("toolchain closure exceeds the producer boundary")
    if not records:
        raise ProducerError("toolchain closure is empty")
    return (
        evidence.sha256_bytes(evidence.canonical_json_bytes(records)),
        tuple(files),
        tuple(sorted(directories, key=lambda item: item.relative_path)),
    )


def _directory_identity(snapshot: DirectorySnapshot) -> tuple[int, int, int, int, int]:
    return (
        snapshot.device,
        snapshot.inode,
        snapshot.mtime_ns,
        snapshot.ctime_ns,
        snapshot.permission_mode,
    )


def _revalidate_toolchain_snapshot(
    root: Path,
    files: tuple[tuple[str, FileSnapshot], ...],
    directories: tuple[DirectorySnapshot, ...],
) -> None:
    root = _require_plain_directory(root, "toolchain root")
    expected_files = dict(files)
    expected_directories = {item.relative_path: item for item in directories}
    current_file_paths: set[str] = set()
    current_directory_paths = {"."}
    if _directory_identity(_directory_snapshot(root, ".")) != _directory_identity(
        expected_directories.get(".", DirectorySnapshot(".", -1, -1, -1, -1, -1))
    ):
        raise ProducerUnavailable("toolchain_changed_after_contract")
    for directory, directory_names, file_names in os.walk(root, followlinks=False):
        directory_path = Path(directory)
        directory_names.sort()
        file_names.sort()
        for name in directory_names:
            path = directory_path / name
            relative = path.relative_to(root).as_posix()
            expected = expected_directories.get(relative)
            if expected is None or _directory_identity(
                _directory_snapshot(path, relative)
            ) != _directory_identity(expected):
                raise ProducerUnavailable("toolchain_changed_after_contract")
            current_directory_paths.add(relative)
        for name in file_names:
            path = directory_path / name
            relative = path.relative_to(root).as_posix()
            expected = expected_files.get(relative)
            if expected is None:
                raise ProducerUnavailable("toolchain_changed_after_contract")
            try:
                path_metadata = path.lstat()
                descriptor = os.open(
                    path,
                    os.O_RDONLY | os.O_CLOEXEC | getattr(os, "O_NOFOLLOW", 0),
                )
            except OSError as error:
                raise ProducerUnavailable("toolchain_changed_after_contract") from error
            try:
                metadata = os.fstat(descriptor)
            finally:
                os.close(descriptor)
            if (
                stat.S_ISLNK(path_metadata.st_mode)
                or not stat.S_ISREG(path_metadata.st_mode)
                or (path_metadata.st_dev, path_metadata.st_ino)
                != (metadata.st_dev, metadata.st_ino)
                or not _snapshot_matches_metadata(expected, metadata)
            ):
                raise ProducerUnavailable("toolchain_changed_after_contract")
            current_file_paths.add(relative)
    if current_file_paths != set(expected_files) or current_directory_paths != set(
        expected_directories
    ):
        raise ProducerUnavailable("toolchain_changed_after_contract")


def _revalidate_toolchain_closure(context: RuntimeGroupContext) -> None:
    _revalidate_toolchain_snapshot(
        context.toolchain_root,
        context.toolchain_files,
        context.toolchain_directories,
    )


def _revalidate_file_snapshot(
    path: Path, expected: FileSnapshot, *, reason: str
) -> None:
    try:
        path_metadata = path.lstat()
        descriptor = os.open(
            path,
            os.O_RDONLY | os.O_CLOEXEC | getattr(os, "O_NOFOLLOW", 0),
        )
    except OSError as error:
        raise ProducerUnavailable(reason) from error
    try:
        metadata = os.fstat(descriptor)
    finally:
        os.close(descriptor)
    if (
        stat.S_ISLNK(path_metadata.st_mode)
        or not stat.S_ISREG(path_metadata.st_mode)
        or (path_metadata.st_dev, path_metadata.st_ino)
        != (metadata.st_dev, metadata.st_ino)
        or not _snapshot_matches_metadata(expected, metadata)
    ):
        raise ProducerUnavailable(reason)


def revalidate_runtime_group_context(context: RuntimeGroupContext) -> None:
    _revalidate_manifest_sources(context.source_root, context.source_files)
    _revalidate_file_snapshot(
        context.request_path,
        context.request_snapshot,
        reason="request_changed_after_contract",
    )
    _revalidate_file_snapshot(
        context.adapter_path,
        context.adapter_snapshot,
        reason="adapter_changed_after_contract",
    )
    _revalidate_toolchain_closure(context)
    for path, snapshot in context.producer_files:
        _revalidate_file_snapshot(
            path,
            snapshot,
            reason="producer_implementation_changed_after_contract",
        )


def _directory_closure_digest(root: Path) -> str:
    digest, _, _ = _capture_toolchain_closure(root)
    return digest


def capture_runtime_group_context(
    *,
    manifest: Any,
    source_root: Path,
    request: Mapping[str, Any],
    request_path: Path,
    group_id: str,
    source_kind: str,
    mode: str,
    shuffle_count: int,
    adapter: Path,
    toolchain_root: Path,
    source_authorization_sha256: str | None = None,
    source_authorization: Mapping[str, Any] | None = None,
) -> RuntimeGroupContext:
    request_from_disk = _load_bounded_json(request_path, maximum_bytes=16 * 1024 * 1024)
    if request_from_disk != request:
        raise ProducerError("measurement request bytes do not match the parsed request")
    _, source_files = _capture_manifest_sources(manifest, source_root)
    request_digest, request_snapshot = _sha256_file(request_path)
    adapter_digest, adapter_snapshot = _sha256_file(adapter)
    toolchain_digest, toolchain_files, toolchain_directories = (
        _capture_toolchain_closure(toolchain_root)
    )
    implementation_digest, producer_files = _producer_implementation_closure()
    contract = build_group_contract(
        manifest=manifest,
        request=request,
        request_file_sha256=request_digest,
        group_id=group_id,
        source_kind=source_kind,
        mode=mode,
        shuffle_count=shuffle_count,
        adapter_sha256=adapter_digest,
        toolchain_closure_sha256=toolchain_digest,
        producer_implementation_sha256=implementation_digest,
        source_authorization_sha256=source_authorization_sha256,
        source_authorization=source_authorization,
    )
    context = RuntimeGroupContext(
        contract=contract,
        source_root=_require_plain_directory(source_root, "source root"),
        source_files=source_files,
        request_path=request_path.resolve(),
        request_snapshot=request_snapshot,
        adapter_path=adapter.resolve(),
        adapter_snapshot=adapter_snapshot,
        toolchain_root=_require_plain_directory(toolchain_root, "toolchain root"),
        toolchain_files=toolchain_files,
        toolchain_directories=toolchain_directories,
        producer_files=producer_files,
    )
    revalidate_runtime_group_context(context)
    return context


def runtime_group_contract(
    *,
    manifest: Any,
    source_root: Path,
    request: Mapping[str, Any],
    request_path: Path,
    group_id: str,
    source_kind: str,
    mode: str,
    shuffle_count: int,
    adapter: Path,
    toolchain_root: Path,
    source_authorization_sha256: str | None = None,
    source_authorization: Mapping[str, Any] | None = None,
) -> dict[str, Any]:
    return capture_runtime_group_context(
        manifest=manifest,
        source_root=source_root,
        request=request,
        request_path=request_path,
        group_id=group_id,
        source_kind=source_kind,
        mode=mode,
        shuffle_count=shuffle_count,
        adapter=adapter,
        toolchain_root=toolchain_root,
        source_authorization_sha256=source_authorization_sha256,
        source_authorization=source_authorization,
    ).contract


def _prospective_plain_directory(path: Path, label: str) -> Path:
    if path.exists() or path.is_symlink():
        return _require_plain_directory(path, label)
    parent = _require_plain_directory(path.parent, f"{label} parent")
    if not path.name or path.name in {".", ".."}:
        raise ProducerError(f"{label} is invalid")
    return parent / path.name


def _directory_identity_chain(path: Path) -> frozenset[tuple[int, int]]:
    identities: set[tuple[int, int]] = set()
    current = _require_plain_directory(path, "directory identity path")
    while True:
        descriptor = _open_plain_directory_descriptor(current)
        try:
            metadata = os.fstat(descriptor)
        finally:
            os.close(descriptor)
        identities.add((metadata.st_dev, metadata.st_ino))
        parent = current.parent
        if parent == current:
            break
        current = parent
    return frozenset(identities)


def _directory_location(path: Path, label: str) -> DirectoryLocation:
    if path.exists() or path.is_symlink():
        resolved = _require_plain_directory(path, label)
        descriptor = _open_plain_directory_descriptor(resolved)
        try:
            metadata = os.fstat(descriptor)
        finally:
            os.close(descriptor)
        parent = _require_plain_directory(resolved.parent, f"{label} parent")
        parent_descriptor = _open_plain_directory_descriptor(parent)
        try:
            parent_metadata = os.fstat(parent_descriptor)
            case_sensitive = bool(os.fpathconf(parent_descriptor, 11))
        finally:
            os.close(parent_descriptor)
        return DirectoryLocation(
            path=resolved,
            identity=(metadata.st_dev, metadata.st_ino),
            ancestor_identities=_directory_identity_chain(resolved),
            parent_identity=(parent_metadata.st_dev, parent_metadata.st_ino),
            leaf_name=None,
            parent_is_case_sensitive=case_sensitive,
        )
    parent = _require_plain_directory(path.parent, f"{label} parent")
    if not path.name or path.name in {".", ".."}:
        raise ProducerError(f"{label} is invalid")
    descriptor = _open_plain_directory_descriptor(parent)
    try:
        metadata = os.fstat(descriptor)
        case_sensitive = bool(os.fpathconf(descriptor, 11))
    finally:
        os.close(descriptor)
    return DirectoryLocation(
        path=parent / path.name,
        identity=None,
        ancestor_identities=_directory_identity_chain(parent),
        parent_identity=(metadata.st_dev, metadata.st_ino),
        leaf_name=path.name,
        parent_is_case_sensitive=case_sensitive,
    )


def _directory_locations_overlap(
    first: DirectoryLocation, second: DirectoryLocation
) -> bool:
    if first.identity is not None and first.identity in second.ancestor_identities:
        return True
    if second.identity is not None and second.identity in first.ancestor_identities:
        return True
    if first.identity is not None or second.identity is not None:
        return False
    if first.parent_identity != second.parent_identity:
        return False
    if first.leaf_name == second.leaf_name:
        return True
    if first.parent_is_case_sensitive and second.parent_is_case_sensitive:
        return False
    first_name = unicodedata.normalize("NFC", first.leaf_name).casefold()
    second_name = unicodedata.normalize("NFC", second.leaf_name).casefold()
    return first_name == second_name


def _plain_file_path(path: Path, label: str) -> Path:
    try:
        metadata = path.lstat()
    except OSError as error:
        raise ProducerError(f"{label} is unavailable") from error
    if stat.S_ISLNK(metadata.st_mode) or not stat.S_ISREG(metadata.st_mode):
        raise ProducerError(f"{label} must be a plain file")
    return path.resolve()


def validate_runtime_path_separation(
    *,
    source_root: Path,
    state_root: Path,
    run_parent: Path,
    toolchain_root: Path,
    request_path: Path,
    adapter: Path,
) -> None:
    directories = {
        "source root": _directory_location(source_root, "source root"),
        "state root": _directory_location(state_root, "state root"),
        "run parent": _directory_location(run_parent, "run parent"),
        "toolchain root": _directory_location(toolchain_root, "toolchain root"),
    }
    items = list(directories.items())
    for index, (first_label, first) in enumerate(items):
        for second_label, second in items[index + 1 :]:
            if _directory_locations_overlap(first, second):
                raise ProducerError(
                    f"{first_label} and {second_label} must not overlap"
                )
    for label, file_path in (
        ("measurement request", _plain_file_path(request_path, "measurement request")),
        ("geometry adapter", _plain_file_path(adapter, "geometry adapter")),
    ):
        file_parent_identities = _directory_identity_chain(file_path.parent)
        for directory_label, directory in directories.items():
            if (
                directory.identity is not None
                and directory.identity in file_parent_identities
            ):
                raise ProducerError(f"{label} must be outside the {directory_label}")


def prepare_bound_toolchain(
    context: RuntimeGroupContext,
    *,
    state_root: Path,
    group_contract_sha256: str,
) -> BoundToolchainContext:
    state_root = _ensure_private_directory(state_root, "producer state root")
    destination = state_root / "bound-toolchain"
    receipt_path = state_root / "bound-toolchain.json"
    expected_digest = context.contract["toolchain_closure_sha256"]
    _recover_bound_toolchain_transaction(
        state_root=state_root,
        destination=destination,
        receipt_path=receipt_path,
        group_contract_sha256=group_contract_sha256,
        expected_digest=expected_digest,
    )
    destination_exists = destination.exists() or destination.is_symlink()
    receipt_exists = receipt_path.exists() or receipt_path.is_symlink()
    if destination_exists and not receipt_exists:
        digest, files, directories = _capture_toolchain_closure(destination)
        if digest != expected_digest:
            raise ProducerError("bound toolchain state is incomplete")
        write_private_json(
            receipt_path,
            {
                "schema_version": 1,
                "group_contract_sha256": group_contract_sha256,
                "toolchain_closure_sha256": expected_digest,
            },
        )
        return BoundToolchainContext(destination.resolve(), files, directories, digest)
    if destination_exists or receipt_exists:
        if not destination_exists or not receipt_exists:
            raise ProducerError("bound toolchain state is incomplete")
        receipt = _load_bounded_json(
            receipt_path, maximum_bytes=MAXIMUM_PRIVATE_JSON_BYTES
        )
        if (
            not isinstance(receipt, dict)
            or set(receipt)
            != {
                "schema_version",
                "group_contract_sha256",
                "toolchain_closure_sha256",
            }
            or receipt.get("schema_version") != 1
            or receipt.get("group_contract_sha256") != group_contract_sha256
            or receipt.get("toolchain_closure_sha256") != expected_digest
        ):
            raise ProducerError("bound toolchain receipt is invalid")
        digest, files, directories = _capture_toolchain_closure(destination)
        if digest != expected_digest:
            raise ProducerError("bound toolchain closure does not match the contract")
        return BoundToolchainContext(destination.resolve(), files, directories, digest)

    temporary = Path(tempfile.mkdtemp(prefix=".bound-toolchain-", dir=state_root))
    temporary_metadata = temporary.stat()
    transaction_token = secrets.token_hex(32)
    try:
        os.chmod(temporary, 0o700)
        write_private_json(
            temporary / BOUND_TOOLCHAIN_MARKER,
            {
                "schema_version": 1,
                "kind": "bound_toolchain_staging",
                "token": transaction_token,
            },
        )
        write_private_json(
            state_root / BOUND_TOOLCHAIN_TRANSACTION,
            {
                "schema_version": 1,
                "group_contract_sha256": group_contract_sha256,
                "toolchain_closure_sha256": expected_digest,
                "staging_name": temporary.name,
                "device": temporary_metadata.st_dev,
                "inode": temporary_metadata.st_ino,
                "token": transaction_token,
            },
        )
        directory_modes = {
            item.relative_path: item.permission_mode
            for item in context.toolchain_directories
            if item.relative_path != "."
        }
        for relative in sorted(
            directory_modes,
            key=lambda value: (len(Path(value).parts), value),
        ):
            path = temporary.joinpath(*Path(relative).parts)
            path.mkdir(mode=0o700)
        staged_files: list[tuple[str, FileSnapshot]] = []
        for relative, expected in context.toolchain_files:
            parts = tuple(Path(relative).parts)
            source = context.toolchain_root.joinpath(*parts)
            source_descriptor = _open_controlled_artifact_descriptor(
                context.toolchain_root,
                str(source),
                parts,
                directory=False,
            )
            try:
                if not _snapshot_matches_metadata(
                    expected, os.fstat(source_descriptor)
                ):
                    raise ProducerUnavailable("toolchain_changed_before_staging")
                target_parent = temporary.joinpath(*parts[:-1])
                parent_descriptor = _open_plain_directory_descriptor(target_parent)
                try:
                    _fclonefileat(source_descriptor, parent_descriptor, parts[-1])
                finally:
                    os.close(parent_descriptor)
                if not _snapshot_matches_metadata(
                    expected, os.fstat(source_descriptor)
                ):
                    raise ProducerUnavailable("toolchain_changed_during_staging")
            finally:
                os.close(source_descriptor)
            target = temporary.joinpath(*parts)
            os.chmod(target, expected.permission_mode)
            staged, _ = _secure_regular_file(
                target,
                maximum_bytes=32 * 1024 * 1024 * 1024,
                capture_bytes=False,
                require_single_link=True,
            )
            if (
                staged.sha256 != expected.sha256
                or staged.byte_count != expected.byte_count
                or staged.permission_mode != expected.permission_mode
            ):
                raise ProducerUnavailable("bound_toolchain_digest_mismatch")
            staged_files.append((relative, staged))
        for relative, mode in sorted(
            directory_modes.items(),
            key=lambda item: (-len(Path(item[0]).parts), item[0]),
        ):
            os.chmod(temporary.joinpath(*Path(relative).parts), mode)
        os.replace(temporary, destination)
        _remove_bound_toolchain_marker(
            destination,
            expected_device=temporary_metadata.st_dev,
            expected_inode=temporary_metadata.st_ino,
            expected_token=transaction_token,
        )
        staged_directories = tuple(
            sorted(
                [
                    _directory_snapshot(destination, "."),
                    *(
                        _directory_snapshot(
                            destination.joinpath(*Path(relative).parts), relative
                        )
                        for relative in directory_modes
                    ),
                ],
                key=lambda item: item.relative_path,
            )
        )
        bound = BoundToolchainContext(
            destination.resolve(),
            tuple(staged_files),
            staged_directories,
            expected_digest,
        )
        _revalidate_toolchain_snapshot(bound.root, bound.files, bound.directories)
        write_private_json(
            receipt_path,
            {
                "schema_version": 1,
                "group_contract_sha256": group_contract_sha256,
                "toolchain_closure_sha256": expected_digest,
            },
        )
        _unlink_private_receipt(state_root / BOUND_TOOLCHAIN_TRANSACTION)
        return bound
    except Exception:
        _recover_bound_toolchain_transaction(
            state_root=state_root,
            destination=destination,
            receipt_path=receipt_path,
            group_contract_sha256=group_contract_sha256,
            expected_digest=expected_digest,
        )
        raise


def _fclonefileat(
    source_descriptor: int,
    destination_directory_descriptor: int,
    destination_name: str,
) -> None:
    libc = ctypes.CDLL("/usr/lib/libSystem.B.dylib", use_errno=True)
    clonefile = libc.fclonefileat
    clonefile.argtypes = [
        ctypes.c_int,
        ctypes.c_int,
        ctypes.c_char_p,
        ctypes.c_int,
    ]
    clonefile.restype = ctypes.c_int
    if (
        clonefile(
            source_descriptor,
            destination_directory_descriptor,
            os.fsencode(destination_name),
            0,
        )
        != 0
    ):
        error_number = ctypes.get_errno()
        if error_number in {errno.ENOTSUP, errno.EXDEV}:
            raise ProducerUnavailable("apfs_clone_unavailable")
        raise ProducerUnavailable("apfs_clone_failed")


def _canonical_mapping(manifest: dict[str, Any], *, scale: int) -> dict[str, Any]:
    corpus_id, entries = _validated_manifest(manifest)
    extension_aliases = {".jpeg": ".jpg", ".tiff": ".tif"}
    mapped = []
    for position, entry in enumerate(
        sorted(entries, key=lambda item: item["relative_path"]), start=1
    ):
        suffix = extension_aliases.get(
            Path(entry["relative_path"]).suffix.lower(),
            Path(entry["relative_path"]).suffix.lower(),
        )
        order_key = (
            "sha256:"
            + hashlib.sha256(
                b"easysplat-unordered-canonical-v1\0"
                + corpus_id.encode()
                + b"\0"
                + str(scale).encode()
                + b"\0"
                + str(position).encode()
                + b"\0"
                + entry["source_sha256"].encode()
            ).hexdigest()
        )
        mapped.append(
            {
                "source_sha256": entry["source_sha256"],
                "order_key_sha256": order_key,
                "target_relative_path": f"photo-{position:06d}{suffix}",
            }
        )
    return {
        "schema_version": 1,
        "operation": "mapping_only",
        "corpus_id": corpus_id,
        "scale": scale,
        "permutation_index": 0,
        "permutation_seed": 0,
        "order_manifest_sha256": evidence.sha256_bytes(
            evidence.canonical_json_bytes(
                [
                    {
                        "source_sha256": entry["source_sha256"],
                        "target_relative_path": entry["target_relative_path"],
                    }
                    for entry in mapped
                ]
            )
        ),
        "entries": mapped,
    }


def _protocol_mapping_manifest(manifest: dict[str, Any]) -> dict[str, Any]:
    corpus_id, entries = _validated_manifest(manifest)
    return {
        "schema_version": 1,
        "corpus_id": corpus_id,
        "entries": entries,
    }


def _require_plain_directory(path: Path, label: str) -> Path:
    try:
        metadata = path.lstat()
    except OSError as error:
        raise ProducerError(f"{label} is unavailable") from error
    if stat.S_ISLNK(metadata.st_mode) or not stat.S_ISDIR(metadata.st_mode):
        raise ProducerError(f"{label} must be a plain directory")
    return path.resolve()


def materialize_variant(
    manifest: dict[str, Any],
    *,
    source_root: Path,
    destination: Path,
    scale: int,
    permutation_index: int,
    permutation_seed: int,
    clone_file: Callable[[Path, Path], None] | None = None,
    pinned_sources: Mapping[str, FileSnapshot] | None = None,
) -> dict[str, Any]:
    _, source_entries = _validated_manifest(manifest)
    source_root = _require_plain_directory(source_root, "source root")
    run_root = _require_plain_directory(destination.parent, "owned run root")
    if (
        source_root == run_root
        or source_root.is_relative_to(run_root)
        or run_root.is_relative_to(source_root)
    ):
        raise ProducerError("source root cannot be inside the owned run root")
    if destination.exists() or destination.is_symlink():
        raise ProducerError("materialized input destination must not exist")
    mapping = (
        _canonical_mapping(manifest, scale=scale)
        if permutation_index == 0 and permutation_seed == 0
        else evidence.build_photo_permutation_mapping(
            _protocol_mapping_manifest(manifest),
            scale=scale,
            permutation_index=permutation_index,
            permutation_seed=permutation_seed,
        )
    )
    entry_by_digest = {entry["source_sha256"]: entry for entry in source_entries}
    pinned = dict(pinned_sources or {})
    try:
        destination.mkdir(mode=0o700)
        destination_descriptor = _open_plain_directory_descriptor(destination)
        try:
            for mapped in mapping["entries"]:
                source_entry = entry_by_digest[mapped["source_sha256"]]
                relative_path = source_entry["relative_path"]
                source = source_root.joinpath(*Path(relative_path).parts)
                source_descriptor = _open_manifest_source_descriptor(
                    source_root, relative_path
                )
                try:
                    expected = pinned.get(relative_path)
                    if expected is not None and not _snapshot_matches_metadata(
                        expected, os.fstat(source_descriptor)
                    ):
                        raise ProducerUnavailable("source_changed_after_contract")
                    source_snapshot, _ = _hash_open_descriptor(
                        source_descriptor,
                        maximum_bytes=MAXIMUM_SOURCE_FILE_BYTES,
                        capture_bytes=False,
                        require_single_link=False,
                    )
                    if source_snapshot.sha256 != source_entry["source_sha256"]:
                        raise ProducerUnavailable("source_digest_mismatch")
                    if expected is not None and source_snapshot != expected:
                        raise ProducerUnavailable("source_changed_after_contract")
                    target = destination / mapped["target_relative_path"]
                    if target.parent != destination:
                        raise ProducerUnavailable("materialized_file_unsafe")
                    if clone_file is None:
                        _fclonefileat(
                            source_descriptor,
                            destination_descriptor,
                            target.name,
                        )
                    else:
                        clone_file(source, target)
                    if not _snapshot_matches_metadata(
                        source_snapshot, os.fstat(source_descriptor)
                    ):
                        raise ProducerUnavailable(
                            "source_changed_during_materialization"
                        )
                finally:
                    os.close(source_descriptor)
                verification_descriptor = _open_manifest_source_descriptor(
                    source_root, relative_path
                )
                try:
                    if not _snapshot_matches_metadata(
                        source_snapshot, os.fstat(verification_descriptor)
                    ):
                        raise ProducerUnavailable(
                            "source_changed_during_materialization"
                        )
                finally:
                    os.close(verification_descriptor)
                target_metadata = target.lstat()
                if (
                    stat.S_ISLNK(target_metadata.st_mode)
                    or not stat.S_ISREG(target_metadata.st_mode)
                    or target_metadata.st_nlink != 1
                ):
                    raise ProducerUnavailable("materialized_file_unsafe")
                target_digest, target_snapshot = _sha256_file(target)
                if target_digest != source_entry["source_sha256"]:
                    raise ProducerUnavailable("materialized_digest_mismatch")
                if target_snapshot.link_count != 1:
                    raise ProducerUnavailable("materialized_file_unsafe")
        finally:
            os.close(destination_descriptor)
        return {
            "schema_version": 1,
            "status": "materialized",
            "materialization": "apfs_clone",
            "verified_file_count": len(mapping["entries"]),
            "mapping": mapping,
        }
    except Exception:
        if destination.exists() and not destination.is_symlink():
            shutil.rmtree(destination)
        raise


def write_private_json(path: Path, value: Any) -> None:
    data = evidence.canonical_json_bytes(value) + b"\n"
    if len(data) > MAXIMUM_PRIVATE_JSON_BYTES:
        raise ProducerError("private receipt exceeds its bounded size")
    parent = _require_plain_directory(path.parent, "private receipt parent")
    if path.exists() and (path.is_symlink() or not path.is_file()):
        raise ProducerError("private receipt destination is unsafe")
    descriptor, temporary_name = tempfile.mkstemp(
        prefix=f".{path.name}.", suffix=".tmp", dir=parent
    )
    temporary = Path(temporary_name)
    try:
        os.fchmod(descriptor, 0o600)
        with os.fdopen(descriptor, "wb") as handle:
            handle.write(data)
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temporary, path)
        os.chmod(path, 0o600)
    finally:
        temporary.unlink(missing_ok=True)


def _rename_private_no_replace(
    parent_descriptor: int,
    source_name: str,
    destination_name: str,
) -> bool:
    if (
        not source_name
        or Path(source_name).name != source_name
        or not destination_name
        or Path(destination_name).name != destination_name
    ):
        raise ProducerError("private receipt publication path is invalid")
    try:
        renameatx_np = ctypes.CDLL(None, use_errno=True).renameatx_np
    except (AttributeError, OSError) as error:
        raise ProducerError(
            "atomic private receipt publication is unavailable"
        ) from error
    renameatx_np.argtypes = [
        ctypes.c_int,
        ctypes.c_char_p,
        ctypes.c_int,
        ctypes.c_char_p,
        ctypes.c_uint,
    ]
    renameatx_np.restype = ctypes.c_int
    ctypes.set_errno(0)
    if (
        renameatx_np(
            parent_descriptor,
            os.fsencode(source_name),
            parent_descriptor,
            os.fsencode(destination_name),
            0x00000004,
        )
        == 0
    ):
        return True
    error_number = ctypes.get_errno()
    if error_number == errno.EEXIST:
        return False
    raise OSError(
        error_number,
        os.strerror(error_number),
        destination_name,
    )


def _write_new_private_json(path: Path, value: Any) -> bool:
    data = evidence.canonical_json_bytes(value) + b"\n"
    if len(data) > MAXIMUM_PRIVATE_JSON_BYTES:
        raise ProducerError("private receipt exceeds its bounded size")
    parent = _require_plain_directory(path.parent, "private receipt parent")
    if stat.S_IMODE(parent.stat().st_mode) & 0o077:
        raise ProducerError("private receipt parent must be private")
    descriptor, temporary_name = tempfile.mkstemp(
        prefix=f".{path.name}.", suffix=".tmp", dir=parent
    )
    temporary = Path(temporary_name)
    parent_descriptor = _open_plain_directory_descriptor(parent)
    published = False
    staged_identity: tuple[int, int] | None = None
    try:
        os.fchmod(descriptor, 0o600)
        with os.fdopen(descriptor, "wb") as handle:
            handle.write(data)
            handle.flush()
            os.fsync(handle.fileno())
        staged = os.stat(
            temporary.name,
            dir_fd=parent_descriptor,
            follow_symlinks=False,
        )
        staged_identity = (staged.st_dev, staged.st_ino)
        if not _rename_private_no_replace(
            parent_descriptor,
            temporary.name,
            path.name,
        ):
            return False
        published = True
        metadata = os.stat(
            path.name,
            dir_fd=parent_descriptor,
            follow_symlinks=False,
        )
        if (
            (metadata.st_dev, metadata.st_ino) != staged_identity
            or not stat.S_ISREG(metadata.st_mode)
            or metadata.st_nlink != 1
            or stat.S_IMODE(metadata.st_mode) != 0o600
        ):
            raise ProducerError("private receipt publication is unsafe")
        os.fsync(parent_descriptor)
        return True
    except Exception:
        if published and staged_identity is not None:
            try:
                current = os.stat(
                    path.name,
                    dir_fd=parent_descriptor,
                    follow_symlinks=False,
                )
            except FileNotFoundError:
                current = None
            if current is not None and (
                current.st_dev,
                current.st_ino,
            ) == staged_identity:
                os.unlink(path.name, dir_fd=parent_descriptor)
                os.fsync(parent_descriptor)
        raise
    finally:
        try:
            os.close(descriptor)
        except OSError:
            pass
        os.close(parent_descriptor)
        temporary.unlink(missing_ok=True)


def write_new_inventory_manifest(
    path: Path,
    manifest: Mapping[str, Any],
    *,
    source_root: Path,
) -> None:
    data = evidence.canonical_json_bytes(manifest) + b"\n"
    if len(data) > MAXIMUM_PRIVATE_JSON_BYTES:
        raise ProducerError("inventory manifest exceeds its bounded size")
    parent = _require_plain_directory(path.parent, "inventory manifest parent")
    if stat.S_IMODE(parent.stat().st_mode) & 0o077:
        raise ProducerError("inventory manifest parent must be private")
    output = parent / path.name
    source_root = _require_plain_directory(source_root, "inventory source root")
    source_descriptor = _open_plain_directory_descriptor(source_root)
    try:
        source_metadata = os.fstat(source_descriptor)
    finally:
        os.close(source_descriptor)
    if (source_metadata.st_dev, source_metadata.st_ino) in _directory_identity_chain(
        parent
    ):
        raise ProducerError("inventory manifest must be outside the source root")
    if output.exists() or output.is_symlink():
        raise ProducerError("inventory manifest output must be new")
    descriptor, temporary_name = tempfile.mkstemp(
        prefix=f".{path.name}.", suffix=".tmp", dir=parent
    )
    temporary = Path(temporary_name)
    published = False
    try:
        os.fchmod(descriptor, 0o600)
        with os.fdopen(descriptor, "wb") as handle:
            handle.write(data)
            handle.flush()
            os.fsync(handle.fileno())
        try:
            os.link(temporary, output, follow_symlinks=False)
        except FileExistsError as error:
            raise ProducerError("inventory manifest output must be new") from error
        published = True
        temporary.unlink()
        directory_descriptor = _open_plain_directory_descriptor(parent)
        try:
            os.fsync(directory_descriptor)
        finally:
            os.close(directory_descriptor)
        metadata = output.lstat()
        if (
            not stat.S_ISREG(metadata.st_mode)
            or metadata.st_nlink != 1
            or stat.S_IMODE(metadata.st_mode) != 0o600
        ):
            raise ProducerError("inventory manifest publication is unsafe")
    except Exception:
        if published:
            output.unlink(missing_ok=True)
        raise
    finally:
        temporary.unlink(missing_ok=True)


def stage_pinned_runtime_file(
    source: Path,
    expected: FileSnapshot,
    destination: Path,
    *,
    executable: bool,
) -> FileSnapshot:
    if destination.exists() or destination.is_symlink():
        raise ProducerUnavailable("staged_runtime_preexisted")
    snapshot, data = _secure_regular_file(
        source,
        maximum_bytes=MAXIMUM_SOURCE_FILE_BYTES,
        capture_bytes=True,
        require_single_link=False,
    )
    if snapshot != expected or data is None:
        raise ProducerUnavailable("runtime_source_changed_before_staging")
    descriptor = os.open(
        destination,
        os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_CLOEXEC,
        0o700 if executable else 0o600,
    )
    try:
        view = memoryview(data)
        written = 0
        while written < len(view):
            count = os.write(descriptor, view[written:])
            if count <= 0:
                raise ProducerUnavailable("staged_runtime_write_failed")
            written += count
        os.fsync(descriptor)
    finally:
        os.close(descriptor)
    os.chmod(destination, 0o700 if executable else 0o600)
    staged, _ = _secure_regular_file(
        destination,
        maximum_bytes=MAXIMUM_SOURCE_FILE_BYTES,
        capture_bytes=False,
        require_single_link=True,
    )
    if staged.sha256 != expected.sha256 or staged.byte_count != expected.byte_count:
        raise ProducerUnavailable("staged_runtime_digest_mismatch")
    return staged


def register_owned_run(
    run_root: Path,
    *,
    run_parent: Path,
    state_root: Path,
    group_contract_sha256: str,
) -> OwnedRun:
    run_parent = _require_plain_directory(run_parent, "owned-run parent")
    state_root = _ensure_private_directory(state_root, "producer state root")
    if run_root.parent.resolve() != run_parent:
        raise ProducerError("owned run must be a direct child of its parent")
    run_root = _require_plain_directory(run_root, "owned run root")
    metadata = run_root.stat()
    token = secrets.token_hex(32)
    ownership_root = _ensure_private_directory(
        state_root / "run-ownership", "run ownership root"
    )
    receipt = ownership_root / f"{run_root.name}.json"
    if receipt.exists() or receipt.is_symlink():
        raise ProducerError("owned run receipt already exists")
    marker = run_root / OWNED_MARKER
    if marker.exists() or marker.is_symlink():
        raise ProducerError("owned run marker already exists")
    owned = OwnedRun(
        root=run_root,
        parent=run_parent,
        device=metadata.st_dev,
        inode=metadata.st_ino,
        token=token,
        ownership_receipt=receipt,
        group_contract_sha256=group_contract_sha256,
    )
    try:
        write_private_json(
            marker,
            {"schema_version": 1, "token": token},
        )
        write_private_json(
            receipt,
            {
                "schema_version": 1,
                "group_contract_sha256": group_contract_sha256,
                "run_name": run_root.name,
                "device": metadata.st_dev,
                "inode": metadata.st_ino,
                "token": token,
            },
        )
    except Exception:
        marker.unlink(missing_ok=True)
        receipt.unlink(missing_ok=True)
        raise
    return owned


def _load_owned_marker(descriptor: int) -> dict[str, Any]:
    try:
        marker_descriptor = os.open(
            OWNED_MARKER,
            os.O_RDONLY | os.O_CLOEXEC | getattr(os, "O_NOFOLLOW", 0),
            dir_fd=descriptor,
        )
    except OSError as error:
        raise ProducerError("owned run marker is missing") from error
    try:
        snapshot, data = _hash_open_descriptor(
            marker_descriptor,
            maximum_bytes=1_024,
            capture_bytes=True,
            require_single_link=True,
        )
    finally:
        os.close(marker_descriptor)
    if snapshot.permission_mode != 0o600 or data is None:
        raise ProducerError("owned run marker is unsafe")
    try:
        value = json.loads(data)
    except (json.JSONDecodeError, UnicodeError) as error:
        raise ProducerError("owned run marker is invalid") from error
    if (
        not isinstance(value, dict)
        or set(value) != {"schema_version", "token"}
        or value.get("schema_version") != 1
        or not isinstance(value.get("token"), str)
        or len(value["token"]) != 64
    ):
        raise ProducerError("owned run marker is invalid")
    return value


def _load_bound_toolchain_marker(descriptor: int) -> dict[str, Any]:
    try:
        marker_descriptor = os.open(
            BOUND_TOOLCHAIN_MARKER,
            os.O_RDONLY | os.O_CLOEXEC | getattr(os, "O_NOFOLLOW", 0),
            dir_fd=descriptor,
        )
    except OSError as error:
        raise ProducerError("bound toolchain staging marker is missing") from error
    try:
        snapshot, data = _hash_open_descriptor(
            marker_descriptor,
            maximum_bytes=1_024,
            capture_bytes=True,
            require_single_link=True,
        )
    finally:
        os.close(marker_descriptor)
    if snapshot.permission_mode != 0o600 or data is None:
        raise ProducerError("bound toolchain staging marker is unsafe")
    try:
        value = json.loads(data)
    except (json.JSONDecodeError, UnicodeError) as error:
        raise ProducerError("bound toolchain staging marker is invalid") from error
    if (
        not isinstance(value, dict)
        or set(value) != {"schema_version", "kind", "token"}
        or value.get("schema_version") != 1
        or value.get("kind") != "bound_toolchain_staging"
        or not isinstance(value.get("token"), str)
        or len(value["token"]) != 64
    ):
        raise ProducerError("bound toolchain staging marker is invalid")
    return value


def _remove_descriptor_tree(
    directory_descriptor: int, *, preserve_names: frozenset[str] = frozenset()
) -> None:
    try:
        entries = sorted(os.scandir(directory_descriptor), key=lambda item: item.name)
    except OSError as error:
        raise ProducerError("owned run cannot be enumerated safely") from error
    for entry in entries:
        if entry.name in preserve_names:
            continue
        try:
            metadata = entry.stat(follow_symlinks=False)
        except FileNotFoundError:
            continue
        except OSError as error:
            raise ProducerError("owned run entry changed during cleanup") from error
        if stat.S_ISDIR(metadata.st_mode):
            try:
                child = os.open(
                    entry.name,
                    os.O_RDONLY
                    | os.O_CLOEXEC
                    | getattr(os, "O_DIRECTORY", 0)
                    | getattr(os, "O_NOFOLLOW", 0),
                    dir_fd=directory_descriptor,
                )
            except FileNotFoundError:
                continue
            except OSError as error:
                raise ProducerError("owned run entry changed during cleanup") from error
            try:
                opened = os.fstat(child)
                if (opened.st_dev, opened.st_ino) != (
                    metadata.st_dev,
                    metadata.st_ino,
                ):
                    raise ProducerError("owned run entry changed during cleanup")
                _remove_descriptor_tree(child)
            finally:
                os.close(child)
            try:
                final = os.stat(
                    entry.name,
                    dir_fd=directory_descriptor,
                    follow_symlinks=False,
                )
            except FileNotFoundError:
                continue
            except OSError as error:
                raise ProducerError("owned run entry changed during cleanup") from error
            if (final.st_dev, final.st_ino) != (metadata.st_dev, metadata.st_ino):
                raise ProducerError("owned run entry changed during cleanup")
            try:
                os.rmdir(entry.name, dir_fd=directory_descriptor)
            except FileNotFoundError:
                continue
            except OSError as error:
                raise ProducerError("owned run entry changed during cleanup") from error
        else:
            try:
                os.unlink(entry.name, dir_fd=directory_descriptor)
            except FileNotFoundError:
                continue
            except OSError as error:
                raise ProducerError("owned run entry changed during cleanup") from error


def _unlink_private_receipt(path: Path) -> None:
    parent = _require_plain_directory(path.parent, "private receipt root")
    descriptor = _open_plain_directory_descriptor(parent)
    try:
        try:
            os.unlink(path.name, dir_fd=descriptor)
        except FileNotFoundError:
            return
        os.fsync(descriptor)
    finally:
        os.close(descriptor)


def _unlink_ownership_receipt(path: Path) -> None:
    _unlink_private_receipt(path)


def _remove_bound_toolchain_marker(
    path: Path,
    *,
    expected_device: int,
    expected_inode: int,
    expected_token: str,
) -> None:
    parent = _require_plain_directory(path.parent, "bound toolchain parent")
    parent_descriptor = _open_plain_directory_descriptor(parent)
    try:
        metadata = os.stat(path.name, dir_fd=parent_descriptor, follow_symlinks=False)
        if not stat.S_ISDIR(metadata.st_mode) or (metadata.st_dev, metadata.st_ino) != (
            expected_device,
            expected_inode,
        ):
            raise ProducerError("bound toolchain staging identity changed")
        descriptor = os.open(
            path.name,
            os.O_RDONLY
            | os.O_CLOEXEC
            | getattr(os, "O_DIRECTORY", 0)
            | getattr(os, "O_NOFOLLOW", 0),
            dir_fd=parent_descriptor,
        )
        try:
            opened = os.fstat(descriptor)
            if (opened.st_dev, opened.st_ino) != (
                expected_device,
                expected_inode,
            ):
                raise ProducerError("bound toolchain staging identity changed")
            marker = _load_bound_toolchain_marker(descriptor)
            if not hmac.compare_digest(marker["token"], expected_token):
                raise ProducerError("bound toolchain staging token changed")
            os.unlink(BOUND_TOOLCHAIN_MARKER, dir_fd=descriptor)
            os.fsync(descriptor)
        finally:
            os.close(descriptor)
    finally:
        os.close(parent_descriptor)


def _validated_bound_toolchain_receipt(
    path: Path,
    *,
    group_contract_sha256: str,
    expected_digest: str,
) -> dict[str, Any]:
    value = _load_bounded_json(path, maximum_bytes=MAXIMUM_PRIVATE_JSON_BYTES)
    if (
        not isinstance(value, dict)
        or set(value)
        != {
            "schema_version",
            "group_contract_sha256",
            "toolchain_closure_sha256",
        }
        or value.get("schema_version") != 1
        or value.get("group_contract_sha256") != group_contract_sha256
        or value.get("toolchain_closure_sha256") != expected_digest
    ):
        raise ProducerError("bound toolchain receipt is invalid")
    return value


def _recover_bound_toolchain_transaction(
    *,
    state_root: Path,
    destination: Path,
    receipt_path: Path,
    group_contract_sha256: str,
    expected_digest: str,
) -> None:
    transaction_path = state_root / BOUND_TOOLCHAIN_TRANSACTION
    if not transaction_path.exists() and not transaction_path.is_symlink():
        return
    value = _load_bounded_json(
        transaction_path, maximum_bytes=MAXIMUM_PRIVATE_JSON_BYTES
    )
    if (
        not isinstance(value, dict)
        or set(value)
        != {
            "schema_version",
            "group_contract_sha256",
            "toolchain_closure_sha256",
            "staging_name",
            "device",
            "inode",
            "token",
        }
        or value.get("schema_version") != 1
        or value.get("group_contract_sha256") != group_contract_sha256
        or value.get("toolchain_closure_sha256") != expected_digest
        or not isinstance(value.get("staging_name"), str)
        or not value["staging_name"].startswith(".bound-toolchain-")
        or Path(value["staging_name"]).name != value["staging_name"]
        or type(value.get("device")) is not int
        or type(value.get("inode")) is not int
        or not isinstance(value.get("token"), str)
        or len(value["token"]) != 64
    ):
        raise ProducerError("bound toolchain transaction is invalid")
    expected_identity = (value["device"], value["inode"])
    staging = state_root / value["staging_name"]
    candidates: list[Path] = []
    for candidate in (staging, destination):
        try:
            metadata = candidate.lstat()
        except FileNotFoundError:
            continue
        if (
            stat.S_ISDIR(metadata.st_mode)
            and (
                metadata.st_dev,
                metadata.st_ino,
            )
            == expected_identity
        ):
            candidates.append(candidate)
    if len(candidates) != 1:
        raise ProducerError("bound toolchain transaction identity is unavailable")
    candidate = candidates[0]
    published = candidate.name == destination.name
    descriptor = _open_plain_directory_descriptor(candidate)
    try:
        opened = os.fstat(descriptor)
        if (opened.st_dev, opened.st_ino) != expected_identity:
            raise ProducerError("bound toolchain staging identity changed")
        marker_present = True
        try:
            marker = _load_bound_toolchain_marker(descriptor)
        except ProducerError as error:
            if "marker is missing" not in str(error) or not published:
                raise
            marker_present = False
        if marker_present:
            if not hmac.compare_digest(marker["token"], value["token"]):
                raise ProducerError("bound toolchain staging token changed")
            if published:
                os.unlink(BOUND_TOOLCHAIN_MARKER, dir_fd=descriptor)
                os.fsync(descriptor)
        if not published:
            _remove_descriptor_tree(
                descriptor,
                preserve_names=frozenset({BOUND_TOOLCHAIN_MARKER}),
            )
            marker = _load_bound_toolchain_marker(descriptor)
            if not hmac.compare_digest(marker["token"], value["token"]):
                raise ProducerError("bound toolchain staging token changed")
            os.unlink(BOUND_TOOLCHAIN_MARKER, dir_fd=descriptor)
    finally:
        os.close(descriptor)
    if not published:
        parent_descriptor = _open_plain_directory_descriptor(state_root)
        try:
            final = os.stat(
                candidate.name,
                dir_fd=parent_descriptor,
                follow_symlinks=False,
            )
            if (final.st_dev, final.st_ino) != expected_identity:
                raise ProducerError("bound toolchain staging identity changed")
            os.rmdir(candidate.name, dir_fd=parent_descriptor)
            os.fsync(parent_descriptor)
        finally:
            os.close(parent_descriptor)
        _unlink_private_receipt(transaction_path)
        return
    digest, _, _ = _capture_toolchain_closure(destination)
    if digest != expected_digest:
        raise ProducerError("bound toolchain transaction closure is invalid")
    if receipt_path.exists() or receipt_path.is_symlink():
        _validated_bound_toolchain_receipt(
            receipt_path,
            group_contract_sha256=group_contract_sha256,
            expected_digest=expected_digest,
        )
    else:
        write_private_json(
            receipt_path,
            {
                "schema_version": 1,
                "group_contract_sha256": group_contract_sha256,
                "toolchain_closure_sha256": expected_digest,
            },
        )
    _unlink_private_receipt(transaction_path)


def remove_owned_run(owned: OwnedRun) -> None:
    parent = _require_plain_directory(owned.parent, "owned-run parent")
    if owned.root.parent.resolve() != parent:
        raise ProducerError("refusing to clean outside the owned-run parent")
    parent_descriptor = _open_plain_directory_descriptor(parent)
    try:
        try:
            path_metadata = os.stat(
                owned.root.name,
                dir_fd=parent_descriptor,
                follow_symlinks=False,
            )
        except FileNotFoundError:
            _unlink_ownership_receipt(owned.ownership_receipt)
            return
        if not stat.S_ISDIR(path_metadata.st_mode) or (
            path_metadata.st_dev,
            path_metadata.st_ino,
        ) != (owned.device, owned.inode):
            raise ProducerError("owned run root identity changed before cleanup")
        run_descriptor = os.open(
            owned.root.name,
            os.O_RDONLY
            | os.O_CLOEXEC
            | getattr(os, "O_DIRECTORY", 0)
            | getattr(os, "O_NOFOLLOW", 0),
            dir_fd=parent_descriptor,
        )
        try:
            opened = os.fstat(run_descriptor)
            if (opened.st_dev, opened.st_ino) != (owned.device, owned.inode):
                raise ProducerError("owned run root identity changed before cleanup")
            marker = _load_owned_marker(run_descriptor)
            if not hmac.compare_digest(marker["token"], owned.token):
                raise ProducerError("owned run token changed before cleanup")
            _remove_descriptor_tree(
                run_descriptor, preserve_names=frozenset({OWNED_MARKER})
            )
            marker = _load_owned_marker(run_descriptor)
            if not hmac.compare_digest(marker["token"], owned.token):
                raise ProducerError("owned run token changed during cleanup")
            try:
                os.unlink(OWNED_MARKER, dir_fd=run_descriptor)
            except OSError as error:
                raise ProducerError(
                    "owned run marker changed during cleanup"
                ) from error
            final = os.fstat(run_descriptor)
            if (final.st_dev, final.st_ino) != (owned.device, owned.inode):
                raise ProducerError("owned run root identity changed during cleanup")
        finally:
            os.close(run_descriptor)
        final_path = os.stat(
            owned.root.name,
            dir_fd=parent_descriptor,
            follow_symlinks=False,
        )
        if (final_path.st_dev, final_path.st_ino) != (owned.device, owned.inode):
            raise ProducerError("owned run root identity changed during cleanup")
        os.rmdir(owned.root.name, dir_fd=parent_descriptor)
        os.fsync(parent_descriptor)
    finally:
        os.close(parent_descriptor)
    _unlink_ownership_receipt(owned.ownership_receipt)


def recover_stale_owned_runs(
    *,
    state_root: Path,
    run_parent: Path,
    group_contract_sha256: str,
) -> None:
    state_root = _ensure_private_directory(state_root, "producer state root")
    run_parent = _ensure_private_directory(run_parent, "producer run parent")
    ownership_root = state_root / "run-ownership"
    if not ownership_root.exists() and not ownership_root.is_symlink():
        return
    ownership_root = _require_plain_directory(ownership_root, "run ownership root")
    for path in sorted(ownership_root.iterdir(), key=lambda item: item.name):
        value = _load_bounded_json(path, maximum_bytes=4 * 1024)
        if (
            not isinstance(value, dict)
            or set(value)
            != {
                "schema_version",
                "group_contract_sha256",
                "run_name",
                "device",
                "inode",
                "token",
            }
            or value.get("schema_version") != 1
            or value.get("group_contract_sha256") != group_contract_sha256
            or not isinstance(value.get("run_name"), str)
            or Path(value["run_name"]).name != value["run_name"]
            or type(value.get("device")) is not int
            or type(value.get("inode")) is not int
            or not isinstance(value.get("token"), str)
            or len(value["token"]) != 64
        ):
            raise ProducerError("stale owned run receipt is invalid")
        remove_owned_run(
            OwnedRun(
                root=run_parent / value["run_name"],
                parent=run_parent,
                device=value["device"],
                inode=value["inode"],
                token=value["token"],
                ownership_receipt=path,
                group_contract_sha256=group_contract_sha256,
            )
        )


def unavailable_public_record(variant_id: str, reason: str) -> dict[str, Any]:
    record = {
        "schema_version": 1,
        "status": "producer_evidence_unavailable",
        "variant_id": variant_id,
        "reason": reason,
    }
    validate_public_record(record)
    return record


def _contains_absolute_path(value: Any) -> bool:
    if isinstance(value, dict):
        return any(_contains_absolute_path(item) for item in value.values())
    if isinstance(value, list):
        return any(_contains_absolute_path(item) for item in value)
    return isinstance(value, str) and (value.startswith("/") or value.startswith("~"))


def validate_public_record(record: Any) -> None:
    if not isinstance(record, dict) or _contains_absolute_path(record):
        raise ProducerError("public record contains private material")
    if record.get("status") == "producer_evidence_unavailable":
        if set(record) != PUBLIC_UNAVAILABLE_FIELDS:
            raise ProducerError("public unavailable record fields are invalid")
        if not all(
            isinstance(record[field], str) and record[field]
            for field in ("variant_id", "reason")
        ):
            raise ProducerError("public unavailable record values are invalid")
    elif set(record) != PUBLIC_VARIANT_FIELDS:
        raise ProducerError("public permutation variant fields are invalid")


def geometry_only_command(
    *,
    adapter: Path,
    request_path: Path,
    input_root: Path,
    toolchain_root: Path,
    project_root: Path,
    output_path: Path,
) -> list[str]:
    return [
        str(adapter),
        "--request",
        str(request_path),
        "--input",
        str(input_root),
        "--toolchain-root",
        str(toolchain_root),
        "--project-root",
        str(project_root),
        "--variant",
        "candidate",
        "--output",
        str(output_path),
        "--geometry-only",
        "true",
    ]


def _read_bounded(path: Path, *, maximum_bytes: int, directory: bool = False) -> bytes:
    try:
        metadata = path.lstat()
    except OSError as error:
        raise ProducerUnavailable("artifact_unavailable") from error
    if directory:
        if stat.S_ISLNK(metadata.st_mode) or not stat.S_ISDIR(metadata.st_mode):
            raise ProducerUnavailable("artifact_unsafe")
        return b""
    try:
        _, data = _secure_regular_file(
            path,
            maximum_bytes=maximum_bytes,
            capture_bytes=True,
            require_single_link=True,
        )
    except ProducerUnavailable as error:
        if error.reason.startswith("source_"):
            raise ProducerUnavailable("artifact_unsafe") from error
        raise
    if data is None:
        raise ProducerUnavailable("artifact_unavailable")
    return data


def _load_bounded_json(path: Path, *, maximum_bytes: int) -> Any:
    try:
        return json.loads(_read_bounded(path, maximum_bytes=maximum_bytes))
    except (json.JSONDecodeError, UnicodeError) as error:
        raise ProducerUnavailable("artifact_invalid") from error


def _opaque_hmac(key: bytes, domain: bytes, payload: bytes) -> str:
    if not isinstance(key, bytes) or len(key) < 32:
        raise ProducerError("opaque identity key must contain at least 32 bytes")
    return (
        "opaque-sha256:"
        + hmac.new(key, domain + b"\0" + payload, hashlib.sha256).hexdigest()
    )


def _validated_private_mapping(mapping: Any) -> tuple[str, list[dict[str, str]]]:
    if not isinstance(mapping, dict) or set(mapping) != {
        "schema_version",
        "operation",
        "corpus_id",
        "scale",
        "permutation_index",
        "permutation_seed",
        "order_manifest_sha256",
        "entries",
    }:
        raise ProducerUnavailable("mapping_invalid")
    entries = mapping["entries"]
    if (
        mapping["schema_version"] != 1
        or mapping["operation"] != "mapping_only"
        or not isinstance(entries, list)
        or len(entries) < 2
    ):
        raise ProducerUnavailable("mapping_invalid")
    sources: set[str] = set()
    targets: set[str] = set()
    normalized: list[dict[str, str]] = []
    for entry in entries:
        if not isinstance(entry, dict) or set(entry) != {
            "source_sha256",
            "order_key_sha256",
            "target_relative_path",
        }:
            raise ProducerUnavailable("mapping_invalid")
        source = entry["source_sha256"]
        target = entry["target_relative_path"]
        if (
            not isinstance(source, str)
            or evidence.SHA256_PATTERN.fullmatch(source) is None
            or not isinstance(target, str)
            or Path(target).name != target
            or source in sources
            or target in targets
        ):
            raise ProducerUnavailable("mapping_invalid")
        sources.add(source)
        targets.add(target)
        normalized.append(dict(entry))
    order_digest = mapping["order_manifest_sha256"]
    if (
        not isinstance(order_digest, str)
        or evidence.SHA256_PATTERN.fullmatch(order_digest) is None
    ):
        raise ProducerUnavailable("mapping_invalid")
    return order_digest, normalized


def _quaternion_rotation(values: list[float]) -> list[list[float]]:
    if len(values) != 4 or not all(math.isfinite(value) for value in values):
        raise ProducerUnavailable("pose_artifact_invalid")
    norm = math.sqrt(sum(value * value for value in values))
    if norm <= 1e-12:
        raise ProducerUnavailable("pose_artifact_invalid")
    w, x, y, z = (value / norm for value in values)
    return [
        [1 - 2 * (y * y + z * z), 2 * (x * y - z * w), 2 * (x * z + y * w)],
        [2 * (x * y + z * w), 1 - 2 * (x * x + z * z), 2 * (y * z - x * w)],
        [2 * (x * z - y * w), 2 * (y * z + x * w), 1 - 2 * (x * x + y * y)],
    ]


def _camera_center(
    rotation: list[list[float]], translation: list[float]
) -> list[float]:
    return [
        -sum(rotation[row][column] * translation[row] for row in range(3))
        for column in range(3)
    ]


def _open_controlled_artifact_descriptor(
    project_root: Path,
    supplied_path: Any,
    relative_parts: tuple[str, ...],
    *,
    directory: bool,
) -> int:
    expected = project_root.joinpath(*relative_parts)
    if (
        not isinstance(supplied_path, str)
        or supplied_path != os.path.normpath(supplied_path)
        or supplied_path != str(expected)
    ):
        raise ProducerUnavailable("adapter_envelope_project_mismatch")
    descriptor = _open_plain_directory_descriptor(project_root)
    try:
        for index, component in enumerate(relative_parts):
            final = index == len(relative_parts) - 1
            flags = os.O_RDONLY | os.O_CLOEXEC | getattr(os, "O_NOFOLLOW", 0)
            if not final or directory:
                flags |= getattr(os, "O_DIRECTORY", 0)
            try:
                child = os.open(component, flags, dir_fd=descriptor)
            except OSError as error:
                raise ProducerUnavailable("controlled_artifact_unavailable") from error
            metadata = os.fstat(child)
            expected_directory = not final or directory
            if (expected_directory and not stat.S_ISDIR(metadata.st_mode)) or (
                not expected_directory
                and (not stat.S_ISREG(metadata.st_mode) or metadata.st_nlink != 1)
            ):
                os.close(child)
                raise ProducerUnavailable("controlled_artifact_unsafe")
            os.close(descriptor)
            descriptor = child
        return descriptor
    except Exception:
        os.close(descriptor)
        raise


def _read_controlled_artifact(
    project_root: Path,
    supplied_path: Any,
    relative_parts: tuple[str, ...],
    *,
    maximum_bytes: int,
) -> bytes:
    descriptor = _open_controlled_artifact_descriptor(
        project_root,
        supplied_path,
        relative_parts,
        directory=False,
    )
    try:
        _, data = _hash_open_descriptor(
            descriptor,
            maximum_bytes=maximum_bytes,
            capture_bytes=True,
            require_single_link=True,
        )
    except ProducerUnavailable as error:
        raise ProducerUnavailable("controlled_artifact_unsafe") from error
    finally:
        os.close(descriptor)
    if data is None:
        raise ProducerUnavailable("controlled_artifact_unavailable")
    return data


def _load_controlled_json(
    project_root: Path,
    supplied_path: Any,
    relative_parts: tuple[str, ...],
    *,
    maximum_bytes: int,
) -> Any:
    try:
        return json.loads(
            _read_controlled_artifact(
                project_root,
                supplied_path,
                relative_parts,
                maximum_bytes=maximum_bytes,
            )
        )
    except (json.JSONDecodeError, UnicodeError) as error:
        raise ProducerUnavailable("controlled_artifact_invalid") from error


def _validate_controlled_artifact(
    project_root: Path,
    supplied_path: Any,
    relative_parts: tuple[str, ...],
    *,
    directory: bool,
) -> None:
    descriptor = _open_controlled_artifact_descriptor(
        project_root,
        supplied_path,
        relative_parts,
        directory=directory,
    )
    os.close(descriptor)


def _colmap_poses(
    images_text: bytes,
    selected_name_to_content: Mapping[str, str],
) -> dict[str, dict[str, Any]]:
    try:
        text = images_text.decode("utf-8")
    except UnicodeError as error:
        raise ProducerUnavailable("pose_artifact_invalid") from error
    poses: dict[str, dict[str, Any]] = {}
    for line in text.splitlines():
        stripped = line.strip()
        if not stripped or stripped.startswith("#"):
            continue
        fields = stripped.split()
        if len(fields) < 10 or fields[9] not in selected_name_to_content:
            continue
        try:
            int(fields[0])
            quaternion = [float(value) for value in fields[1:5]]
            translation = [float(value) for value in fields[5:8]]
            int(fields[8])
        except ValueError as error:
            raise ProducerUnavailable("pose_artifact_invalid") from error
        rotation = _quaternion_rotation(quaternion)
        content_id = selected_name_to_content[fields[9]]
        if content_id in poses:
            raise ProducerUnavailable("pose_artifact_invalid")
        poses[content_id] = {
            "center": _camera_center(rotation, translation),
            "rotation_cw": rotation,
        }
    if not poses:
        raise ProducerUnavailable("pose_artifact_unavailable")
    return poses


def _validated_scheduled_roles(
    schedule: Any,
    *,
    selected_names: set[str],
    require_exhaustive: bool,
) -> dict[frozenset[str], str]:
    if not isinstance(schedule, list) or not schedule:
        raise ProducerUnavailable("pair_graph_artifact_invalid")
    scheduled_roles: dict[frozenset[str], str] = {}
    for raw_pair in schedule:
        if not isinstance(raw_pair, dict) or set(raw_pair) != {
            "firstImageName",
            "secondImageName",
            "role",
        }:
            raise ProducerUnavailable("pair_graph_artifact_invalid")
        first_name = raw_pair["firstImageName"]
        second_name = raw_pair["secondImageName"]
        role = raw_pair["role"]
        if (
            not isinstance(first_name, str)
            or not isinstance(second_name, str)
            or first_name not in selected_names
            or second_name not in selected_names
            or first_name == second_name
            or role not in {"local", "retrieval", "loopRevisit"}
        ):
            raise ProducerUnavailable("pair_graph_artifact_invalid")
        key = frozenset((first_name, second_name))
        if len(key) != 2 or key in scheduled_roles:
            raise ProducerUnavailable("pair_graph_artifact_invalid")
        scheduled_roles[key] = role
    if require_exhaustive:
        ordered_names = sorted(selected_names)
        expected = {
            frozenset((ordered_names[first], ordered_names[second]))
            for first in range(len(ordered_names))
            for second in range(first + 1, len(ordered_names))
        }
        if set(scheduled_roles) != expected:
            raise ProducerUnavailable("pair_graph_artifact_invalid")
    return scheduled_roles


def _validated_retrieval_evidence(
    retrieval: Any,
    *,
    selected_names: list[str],
    expected_query_stride: int,
    expected_candidate_count: int,
    expected_neighbor_count: int,
) -> set[frozenset[str]]:
    fields = {
        "engine",
        "queryImageNames",
        "queryStride",
        "candidateCount",
        "returnedNeighborCount",
        "minimumFrameSeparation",
        "queryOutcomes",
        "directedPairLines",
        "outputDigest",
    }
    if not isinstance(retrieval, dict) or set(retrieval) != fields:
        raise ProducerUnavailable("pair_graph_artifact_invalid")
    if (
        not selected_names
        or len(selected_names) != len(set(selected_names))
        or type(expected_query_stride) is not int
        or expected_query_stride <= 0
        or type(expected_candidate_count) is not int
        or expected_candidate_count <= 0
        or type(expected_neighbor_count) is not int
        or not 0 < expected_neighbor_count <= expected_candidate_count
    ):
        raise ProducerUnavailable("pair_graph_artifact_invalid")
    selected_name_set = set(selected_names)
    expected_query_names = selected_names[::expected_query_stride]
    query_names = retrieval["queryImageNames"]
    query_stride = retrieval["queryStride"]
    candidate_count = retrieval["candidateCount"]
    neighbor_count = retrieval["returnedNeighborCount"]
    minimum_separation = retrieval["minimumFrameSeparation"]
    query_outcomes = retrieval["queryOutcomes"]
    directed_lines = retrieval["directedPairLines"]
    output_digest = retrieval["outputDigest"]
    if (
        retrieval["engine"] != "localSiftVocabularyV2"
        or not isinstance(query_names, list)
        or query_names != expected_query_names
        or type(query_stride) is not int
        or query_stride != expected_query_stride
        or type(candidate_count) is not int
        or candidate_count != expected_candidate_count
        or type(neighbor_count) is not int
        or neighbor_count != expected_neighbor_count
        or type(minimum_separation) is not int
        or minimum_separation != 0
        or not isinstance(query_outcomes, list)
        or len(query_outcomes) != len(query_names)
        or not isinstance(directed_lines, list)
        or len(directed_lines) != len(set(directed_lines))
        or directed_lines
        != sorted(directed_lines, key=lambda value: value.encode("utf-8"))
        or not isinstance(output_digest, str)
        or len(output_digest) != 64
        or any(character not in "0123456789abcdef" for character in output_digest)
    ):
        raise ProducerUnavailable("pair_graph_artifact_invalid")

    outcome_edges: set[frozenset[str]] = set()
    outcome_lines: list[str] = []
    for index, raw_outcome in enumerate(query_outcomes):
        if not isinstance(raw_outcome, dict) or set(raw_outcome) != {
            "queryImageName",
            "status",
            "rankedNeighborImageNames",
        }:
            raise ProducerUnavailable("pair_graph_artifact_invalid")
        query_name = raw_outcome["queryImageName"]
        status = raw_outcome["status"]
        neighbors = raw_outcome["rankedNeighborImageNames"]
        if (
            query_name != query_names[index]
            or status not in {"ranked", "noRankedNeighbors"}
            or not isinstance(neighbors, list)
            or (status == "ranked" and not neighbors)
            or (status == "noRankedNeighbors" and bool(neighbors))
            or len(neighbors) > expected_neighbor_count
            or len(neighbors) != len(set(neighbors))
            or neighbors != sorted(neighbors, key=lambda value: value.encode("utf-8"))
            or any(
                not isinstance(neighbor, str)
                or neighbor not in selected_name_set
                or neighbor == query_name
                for neighbor in neighbors
            )
        ):
            raise ProducerUnavailable("pair_graph_artifact_invalid")
        for neighbor in neighbors:
            outcome_edges.add(frozenset((query_name, neighbor)))
        outcome_lines.append(
            " ".join(("Q", status, query_name, str(len(neighbors)), *neighbors))
        )

    pairs: set[frozenset[str]] = set()
    for line in directed_lines:
        if not isinstance(line, str):
            raise ProducerUnavailable("pair_graph_artifact_invalid")
        names = line.split()
        if (
            len(names) != 2
            or names[0] not in selected_name_set
            or names[1] not in selected_name_set
            or names[0] == names[1]
        ):
            raise ProducerUnavailable("pair_graph_artifact_invalid")
        pair = frozenset(names)
        if pair in pairs or pair not in outcome_edges:
            raise ProducerUnavailable("pair_graph_artifact_invalid")
        pairs.add(pair)
    if pairs != outcome_edges:
        raise ProducerUnavailable("pair_graph_artifact_invalid")

    request_digest = _canonical_retrieval_string_digest(
        [
            retrieval["engine"],
            str(query_stride),
            str(candidate_count),
            str(neighbor_count),
            str(minimum_separation),
            *query_names,
        ]
    )
    contract_lines = [
        " ".join(
            (
                "EASYSPLAT_RETRIEVAL_OUTCOMES_V2",
                retrieval["engine"],
                str(query_stride),
                str(candidate_count),
                str(neighbor_count),
                str(minimum_separation),
                str(len(query_names)),
                request_digest,
            )
        ),
        *outcome_lines,
        *[f"P {line}" for line in directed_lines],
    ]
    if output_digest != _canonical_retrieval_string_digest(contract_lines):
        raise ProducerUnavailable("pair_graph_artifact_invalid")
    return pairs


def _canonical_retrieval_string_digest(fields: list[str]) -> str:
    payload = bytearray()
    for field in fields:
        encoded = field.encode("utf-8")
        payload.extend(f"{len(encoded)}:".encode("utf-8"))
        payload.extend(encoded)
    return hashlib.sha256(payload).hexdigest()


def _validated_inspection_pairs(
    inspection: Any,
    *,
    scheduled_roles: Mapping[frozenset[str], str],
) -> tuple[
    dict[frozenset[str], str],
    dict[frozenset[str], str],
    dict[frozenset[str], str],
]:
    if not isinstance(inspection, dict):
        raise ProducerUnavailable("pair_graph_artifact_invalid")

    def validated_pair_set(name: str) -> dict[frozenset[str], str]:
        count = inspection.get(f"{name}PairCount")
        values = inspection.get(f"{name}Pairs")
        if (
            type(count) is not int
            or not isinstance(values, list)
            or count != len(values)
        ):
            raise ProducerUnavailable("pair_graph_artifact_invalid")
        result: dict[frozenset[str], str] = {}
        for raw_pair in values:
            if not isinstance(raw_pair, dict) or set(raw_pair) != {
                "firstImageName",
                "secondImageName",
                "role",
            }:
                raise ProducerUnavailable("pair_graph_artifact_invalid")
            first_name = raw_pair["firstImageName"]
            second_name = raw_pair["secondImageName"]
            role = raw_pair["role"]
            if not isinstance(first_name, str) or not isinstance(second_name, str):
                raise ProducerUnavailable("pair_graph_artifact_invalid")
            key = frozenset((first_name, second_name))
            if len(key) != 2 or scheduled_roles.get(key) != role or key in result:
                raise ProducerUnavailable("pair_graph_artifact_invalid")
            result[key] = role
        return result

    if inspection.get("scheduledPairCount") != len(scheduled_roles):
        raise ProducerUnavailable("pair_graph_artifact_invalid")
    attempted = validated_pair_set("attempted")
    raw_matched = validated_pair_set("rawMatched")
    spatially_verified = validated_pair_set("spatiallyVerified")
    if (
        attempted != dict(scheduled_roles)
        or not set(raw_matched).issubset(attempted)
        or not set(spatially_verified).issubset(raw_matched)
    ):
        raise ProducerUnavailable("pair_graph_artifact_invalid")
    return attempted, raw_matched, spatially_verified


def _require_connected_content_graph(
    selected_content_ids: list[str],
    edges: list[Mapping[str, str]],
) -> None:
    adjacency = {content_id: set() for content_id in selected_content_ids}
    for edge in edges:
        adjacency[edge["content_a"]].add(edge["content_b"])
        adjacency[edge["content_b"]].add(edge["content_a"])
    reached = {selected_content_ids[0]}
    pending = [selected_content_ids[0]]
    while pending:
        current = pending.pop()
        for neighbor in adjacency[current]:
            if neighbor not in reached:
                reached.add(neighbor)
                pending.append(neighbor)
    if len(reached) != len(selected_content_ids):
        raise ProducerUnavailable("accepted_pair_graph_disconnected")


def _expected_pair_graph_plan_binding(
    requested_plan: Mapping[str, Any],
) -> dict[str, Any]:
    if not isinstance(requested_plan, Mapping):
        raise ProducerUnavailable("pair_graph_artifact_invalid")
    pairing_policy = requested_plan.get("pairing_policy")
    temporal_pairing = requested_plan.get("temporal_pairing")
    temporal_offsets = requested_plan.get("temporal_offsets")
    candidate_count = requested_plan.get("vocabulary_candidate_count")
    neighbor_count = requested_plan.get("vocabulary_returned_neighbor_count")
    query_stride = requested_plan.get("vocabulary_query_stride")
    descriptor_matcher = requested_plan.get("descriptor_matcher")
    camera_grouping = requested_plan.get("camera_grouping")
    lens_projection = requested_plan.get("lens_projection")
    run_seed = requested_plan.get("run_seed")
    if (
        pairing_policy not in {"unordered_exhaustive", "unordered_retrieval"}
        or temporal_pairing != "none"
        or temporal_offsets != []
        or type(candidate_count) is not int
        or candidate_count <= 0
        or type(neighbor_count) is not int
        or not 0 < neighbor_count <= candidate_count
        or type(query_stride) is not int
        or query_stride <= 0
        or descriptor_matcher != "faiss"
        or camera_grouping
        not in {"automatic", "same_camera_and_lens", "mixed_cameras_or_lenses"}
        or lens_projection not in {"automatic", "perspective", "fisheye"}
        or type(run_seed) is not int
        or not 0 <= run_seed <= (1 << 31) - 1
    ):
        raise ProducerUnavailable("pair_graph_artifact_invalid")
    camera_initializer = (
        "sharedOpenCVFisheyeEquidistantDiagonal150V1"
        if camera_grouping == "same_camera_and_lens" and lens_projection == "fisheye"
        else "colmapAutomatic"
    )
    return {
        "pairingPolicy": "unorderedRetrieval",
        "geometryBackend": "colmap",
        "modelIdentifier": "none",
        "temporalPairing": "none",
        "temporalOffsets": [],
        "retrievalEngine": "localSiftVocabularyV2",
        "retrievalCandidateCount": candidate_count,
        "retrievalNeighborCount": neighbor_count,
        "retrievalQueryStride": query_stride,
        "requiresCrossClipRetrieval": False,
        "normalDescriptorMatcher": "faiss",
        "cameraInitializationRecipe": camera_initializer,
        "runSeed": run_seed,
    }


def _pair_graph_plan_binding_matches(
    value: Any,
    expected: Mapping[str, Any],
) -> bool:
    return (
        isinstance(value, dict)
        and set(value) == PAIR_GRAPH_PLAN_BINDING_FIELDS
        and type(value.get("pairingPolicy")) is str
        and type(value.get("geometryBackend")) is str
        and type(value.get("modelIdentifier")) is str
        and type(value.get("temporalPairing")) is str
        and type(value.get("temporalOffsets")) is list
        and all(type(offset) is int for offset in value["temporalOffsets"])
        and type(value.get("retrievalEngine")) is str
        and type(value.get("retrievalCandidateCount")) is int
        and type(value.get("retrievalNeighborCount")) is int
        and type(value.get("retrievalQueryStride")) is int
        and type(value.get("requiresCrossClipRetrieval")) is bool
        and type(value.get("normalDescriptorMatcher")) is str
        and type(value.get("cameraInitializationRecipe")) is str
        and type(value.get("runSeed")) is int
        and value == expected
    )


def derive_private_geometry_observation(
    adapter_envelope: Any,
    *,
    mapping: Any,
    requested_plan: Mapping[str, Any],
    hmac_key: bytes,
    expected_project_root: Path,
    expected_variant: str,
) -> dict[str, Any]:
    expected_project_root = _require_plain_directory(
        expected_project_root, "fresh geometry project root"
    )
    if (
        not isinstance(adapter_envelope, dict)
        or set(adapter_envelope) != GEOMETRY_ONLY_ENVELOPE_FIELDS
        or adapter_envelope.get("schema_version") != 2
        or adapter_envelope.get("measurement_scope") != "geometry_only"
        or adapter_envelope.get("variant") != expected_variant
        or adapter_envelope.get("project_root") != str(expected_project_root)
    ):
        raise ProducerUnavailable("adapter_envelope_invalid")
    _validate_controlled_artifact(
        expected_project_root,
        adapter_envelope["geometry_manifest"],
        ("SfM", "geometry_manifest.json"),
        directory=False,
    )
    _validate_controlled_artifact(
        expected_project_root,
        adapter_envelope["pipeline_log"],
        ("Logs", "pipeline.log"),
        directory=False,
    )
    model_relative = (
        "Training",
        f"measurement-{expected_variant}-source-text",
    )
    _validate_controlled_artifact(
        expected_project_root,
        adapter_envelope["canonical_text_model"],
        model_relative,
        directory=True,
    )
    order_digest, mapping_entries = _validated_private_mapping(mapping)
    digest_to_content: dict[str, str] = {}
    all_content_ids: list[str] = []
    for entry in mapping_entries:
        content_id = _opaque_hmac(
            hmac_key,
            b"easysplat-photo-content-id-v1",
            entry["source_sha256"].encode("ascii"),
        )
        digest_to_content[entry["source_sha256"]] = content_id
        all_content_ids.append(content_id)
    selection = _load_controlled_json(
        expected_project_root,
        adapter_envelope["selection_manifest"],
        ("Frames", "selected_manifest.json"),
        maximum_bytes=4 * 1024 * 1024,
    )
    if not isinstance(selection, list) or not selection:
        raise ProducerUnavailable("selection_artifact_invalid")
    selected_name_to_content: dict[str, str] = {}
    for item in selection:
        if not isinstance(item, dict):
            raise ProducerUnavailable("selection_artifact_invalid")
        output_name = item.get("outputFileName")
        source_relative = item.get("sourceProjectRelativePath")
        source_digest = item.get("sourceSHA256")
        if source_relative is not None and not isinstance(source_relative, str):
            raise ProducerUnavailable("selection_artifact_invalid")
        if source_digest is not None and not isinstance(source_digest, str):
            raise ProducerUnavailable("selection_artifact_invalid")
        normalized_source_digest: str | None = None
        if isinstance(source_digest, str):
            if evidence.SHA256_PATTERN.fullmatch(source_digest) is not None:
                normalized_source_digest = source_digest
            elif len(source_digest) == 64 and all(
                character in "0123456789abcdef" for character in source_digest
            ):
                normalized_source_digest = "sha256:" + source_digest
            else:
                raise ProducerUnavailable("selection_artifact_invalid")
        path_content: str | None = None
        if source_relative is not None:
            parts = Path(source_relative).parts
            leaf = parts[-1] if parts else ""
            leaf_path = Path(leaf)
            stem = leaf_path.stem
            sequence = stem.removeprefix("photo-")
            if (
                len(parts) != 3
                or parts[:2] != ("Originals", "Photos")
                or leaf_path.name != leaf
                or not stem.startswith("photo-")
                or len(sequence) < 4
                or not sequence.isdigit()
                or leaf_path.suffix.lower() not in SUPPORTED_STILL_EXTENSIONS
            ):
                raise ProducerUnavailable("selection_artifact_invalid")
            supplied_path = str(expected_project_root.joinpath(*parts))
            descriptor = _open_controlled_artifact_descriptor(
                expected_project_root,
                supplied_path,
                tuple(parts),
                directory=False,
            )
            try:
                snapshot, _ = _hash_open_descriptor(
                    descriptor,
                    maximum_bytes=MAXIMUM_SOURCE_FILE_BYTES,
                    capture_bytes=False,
                    require_single_link=True,
                )
            except ProducerUnavailable as error:
                raise ProducerUnavailable(
                    "selection_artifact_identity_conflict"
                ) from error
            finally:
                os.close(descriptor)
            path_content = digest_to_content.get(snapshot.sha256)
            if (
                path_content is None
                or (
                    normalized_source_digest is not None
                    and snapshot.sha256 != normalized_source_digest
                )
            ):
                raise ProducerUnavailable("selection_artifact_identity_conflict")
        digest_content = (
            digest_to_content.get(normalized_source_digest)
            if normalized_source_digest is not None
            else None
        )
        if source_relative is not None and source_digest is not None:
            if digest_content is None or path_content != digest_content:
                raise ProducerUnavailable("selection_artifact_identity_conflict")
            content_id = digest_content
        else:
            content_id = path_content or digest_content
        if (
            not isinstance(output_name, str)
            or not output_name
            or Path(output_name).name != output_name
            or content_id is None
            or output_name in selected_name_to_content
            or content_id in selected_name_to_content.values()
        ):
            raise ProducerUnavailable("selection_artifact_invalid")
        selected_name_to_content[output_name] = content_id
    selected_names_in_order = list(selected_name_to_content)
    selected_content_ids = sorted(selected_name_to_content.values())

    pair_evidence = _load_controlled_json(
        expected_project_root,
        adapter_envelope["pair_graph_evidence"],
        ("SfM", "pair_graph_evidence.json"),
        maximum_bytes=64 * 1024 * 1024,
    )
    expected_plan_binding = _expected_pair_graph_plan_binding(requested_plan)
    plan_binding = (
        pair_evidence.get("planBinding")
        if isinstance(pair_evidence, dict)
        else None
    )
    if (
        not isinstance(pair_evidence, dict)
        or type(pair_evidence.get("schemaVersion")) is not int
        or pair_evidence["schemaVersion"] != PAIR_GRAPH_EVIDENCE_SCHEMA_VERSION
        or pair_evidence.get("pairingPolicy") != "unorderedRetrieval"
        or not _pair_graph_plan_binding_matches(plan_binding, expected_plan_binding)
        or not isinstance(pair_evidence.get("attempts"), list)
        or pair_evidence.get("acceptedAttemptNumber") != len(pair_evidence["attempts"])
        or not pair_evidence["attempts"]
    ):
        raise ProducerUnavailable("pair_graph_artifact_invalid")
    for recorded_attempt in pair_evidence["attempts"]:
        if (
            not isinstance(recorded_attempt, dict)
            or not isinstance(recorded_attempt.get("artifact"), dict)
            or recorded_attempt["artifact"].get("matcher") != "faiss"
            or recorded_attempt["artifact"].get("exactRecoveryReason") is not None
        ):
            raise ProducerUnavailable("pair_graph_artifact_invalid")
    attempt = pair_evidence["attempts"][-1]
    if not isinstance(attempt, dict) or not isinstance(attempt.get("artifact"), dict):
        raise ProducerUnavailable("pair_graph_artifact_invalid")
    artifact = attempt["artifact"]
    schedule = attempt.get("scheduledPairs")
    if (
        artifact.get("outcome") != "completed"
        or not isinstance(schedule, list)
        or not schedule
    ):
        raise ProducerUnavailable("pair_graph_artifact_invalid")
    recovery = artifact.get("recoveryLevel")
    retrieval = attempt.get("retrieval")
    retrieval_was_executed = attempt.get("retrievalWasExecuted")
    if type(retrieval_was_executed) is not bool:
        raise ProducerUnavailable("pair_graph_artifact_invalid")
    retrieval_pairs: set[frozenset[str]] | None = None
    if (
        len(selected_content_ids) <= 60
        and retrieval is None
        and retrieval_was_executed is False
        and recovery == "normal"
    ):
        accepted_attempt = "exhaustive_primary"
        pairing_policy = "unordered_exhaustive"
        exhaustive_field = "exhaustive_primary"
    elif (
        len(selected_content_ids) <= 250
        and retrieval is None
        and retrieval_was_executed is False
        and recovery == "maximum"
    ):
        accepted_attempt = "exhaustive_recovery"
        pairing_policy = "unordered_retrieval"
        exhaustive_field = "exhaustive_recovery"
    elif len(selected_content_ids) > 60 and retrieval_was_executed is True:
        request_stride = requested_plan.get("vocabulary_query_stride")
        request_candidates = requested_plan.get("vocabulary_candidate_count")
        request_neighbors = requested_plan.get("vocabulary_returned_neighbor_count")
        if recovery == "normal":
            expected_candidates = request_candidates
            expected_neighbors = request_neighbors
        elif recovery == "expanded":
            expected_candidates = 40
            expected_neighbors = 16
        elif recovery == "maximum" and len(selected_content_ids) > 250:
            expected_candidates = 80
            expected_neighbors = 32
        else:
            raise ProducerUnavailable("accepted_pair_policy_unavailable")
        retrieval_pairs = _validated_retrieval_evidence(
            retrieval,
            selected_names=selected_names_in_order,
            expected_query_stride=request_stride,
            expected_candidate_count=expected_candidates,
            expected_neighbor_count=expected_neighbors,
        )
        accepted_attempt = "vocabulary_retrieval"
        pairing_policy = "unordered_retrieval"
        exhaustive_field = None
    else:
        raise ProducerUnavailable("accepted_pair_policy_unavailable")
    scheduled_roles = _validated_scheduled_roles(
        schedule,
        selected_names=set(selected_name_to_content),
        require_exhaustive=accepted_attempt
        in {"exhaustive_primary", "exhaustive_recovery"},
    )
    if retrieval_pairs is not None and set(scheduled_roles) != retrieval_pairs:
        raise ProducerUnavailable("pair_graph_artifact_invalid")
    inspection = pair_evidence.get("acceptedInspection")
    attempted_roles, raw_matched_roles, verified_roles = _validated_inspection_pairs(
        inspection,
        scheduled_roles=scheduled_roles,
    )
    if not verified_roles:
        raise ProducerUnavailable("pair_graph_artifact_invalid")
    verified_pairs = inspection["spatiallyVerifiedPairs"]
    pair_counts = {
        "temporal": 0,
        "vocabulary_retrieval": 0,
        "loop_revisit": 0,
        "exhaustive_primary": 0,
        "exhaustive_recovery": 0,
    }
    edges_by_id: dict[str, dict[str, str]] = {}
    for raw_pair in verified_pairs:
        if not isinstance(raw_pair, dict) or set(raw_pair) != {
            "firstImageName",
            "secondImageName",
            "role",
        }:
            raise ProducerUnavailable("pair_graph_artifact_invalid")
        first_name = raw_pair.get("firstImageName")
        second_name = raw_pair.get("secondImageName")
        if not isinstance(first_name, str) or not isinstance(second_name, str):
            raise ProducerUnavailable("pair_graph_artifact_invalid")
        scheduled_role = scheduled_roles.get(frozenset((first_name, second_name)))
        if scheduled_role != raw_pair.get("role"):
            raise ProducerUnavailable("pair_graph_artifact_invalid")
        first = selected_name_to_content.get(first_name)
        second = selected_name_to_content.get(second_name)
        role = raw_pair.get("role")
        if first is None or second is None or first == second:
            raise ProducerUnavailable("pair_graph_artifact_invalid")
        content_a, content_b = sorted((first, second))
        edge_id = evidence._photo_pair_edge_id(content_a, content_b)
        if edge_id in edges_by_id:
            raise ProducerUnavailable("pair_graph_artifact_invalid")
        edges_by_id[edge_id] = {
            "content_a": content_a,
            "content_b": content_b,
            "edge_id": edge_id,
        }
        if exhaustive_field is not None:
            pair_counts[exhaustive_field] += 1
        elif role == "retrieval":
            pair_counts["vocabulary_retrieval"] += 1
        elif role == "loopRevisit":
            pair_counts["loop_revisit"] += 1
        else:
            raise ProducerUnavailable("unordered_temporal_pair_detected")
    edges = sorted(edges_by_id.values(), key=lambda edge: edge["edge_id"])
    _require_connected_content_graph(selected_content_ids, edges)

    def pair_graph_digest_for(pair_roles: Mapping[frozenset[str], str]) -> str:
        edge_ids: list[str] = []
        for pair in pair_roles:
            names = sorted(pair)
            first = selected_name_to_content[names[0]]
            second = selected_name_to_content[names[1]]
            content_a, content_b = sorted((first, second))
            edge_ids.append(evidence._photo_pair_edge_id(content_a, content_b))
        return evidence._photo_pair_graph_digest(sorted(edge_ids))

    scheduled_pair_graph_sha256 = pair_graph_digest_for(scheduled_roles)
    attempted_pair_graph_sha256 = pair_graph_digest_for(attempted_roles)
    raw_matched_pair_graph_sha256 = pair_graph_digest_for(raw_matched_roles)
    images_path = expected_project_root.joinpath(*model_relative, "images.txt")
    poses = _colmap_poses(
        _read_controlled_artifact(
            expected_project_root,
            str(images_path),
            (*model_relative, "images.txt"),
            maximum_bytes=_model_images_maximum_bytes(len(selected_content_ids)),
        ),
        selected_name_to_content,
    )
    registered_content_ids = sorted(poses)
    registered_views = adapter_envelope.get("registered_views")
    point_count = adapter_envelope.get("point_count")
    observation_count = adapter_envelope.get("observation_count")
    median = adapter_envelope.get("median_residual_pixels")
    p90 = adapter_envelope.get("p90_residual_pixels")
    if (
        type(registered_views) is not int
        or registered_views != len(registered_content_ids)
        or type(point_count) is not int
        or point_count <= 0
        or type(observation_count) is not int
        or observation_count <= 0
        or isinstance(median, bool)
        or not isinstance(median, (int, float))
        or isinstance(p90, bool)
        or not isinstance(p90, (int, float))
        or not math.isfinite(float(median))
        or not math.isfinite(float(p90))
        or median < 0
        or p90 < median
    ):
        raise ProducerUnavailable("geometry_metrics_invalid")
    return {
        "schema_version": 1,
        "private_order_manifest_sha256": order_digest,
        "order_commitment": _opaque_hmac(
            hmac_key,
            b"easysplat-photo-order-commitment-v1",
            evidence.canonical_json_bytes(
                [
                    digest_to_content[entry["source_sha256"]]
                    for entry in sorted(
                        mapping_entries,
                        key=lambda item: item["target_relative_path"],
                    )
                ]
            ),
        ),
        "content_set_attestation": _opaque_hmac(
            hmac_key,
            b"easysplat-photo-content-set-attestation-v1",
            evidence.canonical_json_bytes(sorted(all_content_ids)),
        ),
        "selected_content_ids": selected_content_ids,
        "registered_content_ids": registered_content_ids,
        "normalized_pair_edges": edges,
        "pairing_policy": pairing_policy,
        "accepted_attempt": accepted_attempt,
        "scheduled_pair_count": len(schedule),
        "scheduled_pair_graph_sha256": scheduled_pair_graph_sha256,
        "attempted_pair_count": len(attempted_roles),
        "attempted_pair_graph_sha256": attempted_pair_graph_sha256,
        "raw_matched_pair_count": len(raw_matched_roles),
        "raw_matched_pair_graph_sha256": raw_matched_pair_graph_sha256,
        "spatially_verified_pair_count": len(verified_roles),
        "retrieval_worker_executed": retrieval_was_executed,
        "pair_counts": pair_counts,
        "registered_views": registered_views,
        "point_count": point_count,
        "observation_count": observation_count,
        "residual_median_pixels": float(median),
        "residual_p90_pixels": float(p90),
        "poses": poses,
    }


def _pose_deviation(
    reference: Mapping[str, Any],
    candidate: Mapping[str, Any],
) -> tuple[float, float]:
    try:
        result = evidence.sim3_pose_deviation(reference["poses"], candidate["poses"])
    except evidence.PoseAlignmentError as error:
        raise ProducerUnavailable(error.reason) from error
    return (
        result.camera_center_p95_scene_radius_fraction,
        result.rotation_p95_degrees,
    )


def build_public_variant(
    observation: Mapping[str, Any],
    *,
    spec: VariantSpec,
    group_id: str,
    source_kind: str,
    request: Mapping[str, Any],
    canonical_observation: Mapping[str, Any] | None,
    canonical_observation_attestation: str,
) -> dict[str, Any]:
    try:
        scale, run_seed, plan_digest = evidence._photo_permutation_request_contract(
            request
        )
    except evidence.EvidenceError as error:
        raise ProducerError(str(error)) from error
    if len(observation["selected_content_ids"]) != scale:
        raise ProducerUnavailable("selected_scale_mismatch")
    if (
        not isinstance(canonical_observation_attestation, str)
        or evidence.OPAQUE_SHA256_PATTERN.fullmatch(
            canonical_observation_attestation
        )
        is None
    ):
        raise ProducerUnavailable("canonical_observation_unavailable")
    if spec.permutation_index == 0:
        if canonical_observation is not None:
            raise ProducerError("canonical observation cannot have a reference")
        center_p95, rotation_p95 = 0.0, 0.0
    else:
        if canonical_observation is None:
            raise ProducerUnavailable("canonical_observation_unavailable")
        center_p95, rotation_p95 = _pose_deviation(canonical_observation, observation)
    selected_ids = list(observation["selected_content_ids"])
    registered_ids = list(observation["registered_content_ids"])
    edge_ids = [edge["edge_id"] for edge in observation["normalized_pair_edges"]]
    public = {
        "group_id": group_id,
        "variant_id": spec.variant_id,
        "permutation": spec.public_permutation,
        "order_commitment": observation["order_commitment"],
        "content_set_attestation": observation["content_set_attestation"],
        "canonical_observation_attestation": canonical_observation_attestation,
        "source_kind": source_kind,
        "selected_content_ids": selected_ids,
        "registered_content_ids": registered_ids,
        "selected_content_set_sha256": evidence._photo_content_set_digest(selected_ids),
        "registered_content_set_sha256": evidence._photo_content_set_digest(
            registered_ids
        ),
        "normalized_pair_graph_sha256": evidence._photo_pair_graph_digest(edge_ids),
        "normalized_pair_edges": list(observation["normalized_pair_edges"]),
        "requested_plan_sha256": plan_digest,
        "scale": scale,
        "run_seed": run_seed,
        "pairing_policy": observation["pairing_policy"],
        "accepted_attempt": observation["accepted_attempt"],
        "scheduled_pair_count": observation["scheduled_pair_count"],
        "scheduled_pair_graph_sha256": observation["scheduled_pair_graph_sha256"],
        "attempted_pair_count": observation["attempted_pair_count"],
        "attempted_pair_graph_sha256": observation["attempted_pair_graph_sha256"],
        "raw_matched_pair_count": observation["raw_matched_pair_count"],
        "raw_matched_pair_graph_sha256": observation["raw_matched_pair_graph_sha256"],
        "spatially_verified_pair_count": observation["spatially_verified_pair_count"],
        "retrieval_worker_executed": observation["retrieval_worker_executed"],
        "pair_counts": dict(observation["pair_counts"]),
        "registered_views": observation["registered_views"],
        "point_count": observation["point_count"],
        "observation_count": observation["observation_count"],
        "residual_median_pixels": observation["residual_median_pixels"],
        "residual_p90_pixels": observation["residual_p90_pixels"],
        "camera_center_p95_scene_radius_fraction": center_p95,
        "rotation_p95_degrees": rotation_p95,
    }
    validate_public_record(public)
    return public


def _load_completed_variant(
    path: Path,
    *,
    group_contract_sha256: str,
    spec: VariantSpec,
    group_id: str,
    authentication_key: bytes,
) -> dict[str, Any] | None:
    validated = _load_completed_variant_receipt(
        path,
        group_contract_sha256=group_contract_sha256,
        spec=spec,
        group_id=group_id,
        authentication_key=authentication_key,
    )
    return None if validated is None else validated[0]


def _load_completed_variant_receipt(
    path: Path,
    *,
    group_contract_sha256: str,
    spec: VariantSpec,
    group_id: str,
    authentication_key: bytes,
) -> tuple[dict[str, Any], str] | None:
    if not path.exists() or path.is_symlink():
        return None
    try:
        snapshot, data = _secure_regular_file(
            path,
            maximum_bytes=MAXIMUM_PRIVATE_JSON_BYTES,
            capture_bytes=True,
            require_single_link=True,
        )
        if data is None or snapshot.permission_mode != 0o600:
            return None
        value = json.loads(data)
    except (ProducerUnavailable, json.JSONDecodeError, UnicodeError):
        return None
    if (
        not isinstance(value, dict)
        or set(value)
        != {
            "schema_version",
            "status",
            "group_contract_sha256",
            "public_variant",
            "authenticator",
        }
        or value.get("schema_version") != 1
        or value.get("status") != "complete"
        or value.get("group_contract_sha256") != group_contract_sha256
    ):
        return None
    public = value.get("public_variant")
    try:
        validate_public_record(public)
    except ProducerError:
        return None
    if (
        public.get("group_id") != group_id
        or public.get("variant_id") != spec.variant_id
        or public.get("permutation") != spec.public_permutation
    ):
        return None
    expected_authenticator = _opaque_hmac(
        authentication_key,
        b"easysplat-photo-permutation-cache-v1",
        evidence.canonical_json_bytes(
            {
                "group_contract_sha256": group_contract_sha256,
                "variant_id": spec.variant_id,
                "public_variant": public,
            }
        ),
    )
    if not isinstance(value.get("authenticator"), str) or not hmac.compare_digest(
        value["authenticator"], expected_authenticator
    ):
        return None
    return public, snapshot.sha256


def orchestrate_group(
    *,
    request: Mapping[str, Any],
    state_root: Path,
    mode: str,
    shuffle_count: int,
    source_kind: str,
    group_contract: Mapping[str, Any],
    receipt_authentication_key: bytes,
    execute_variant: Callable[[VariantSpec], dict[str, Any]],
) -> dict[str, Any]:
    schedule = variant_schedule(mode=mode, shuffle_count=shuffle_count)
    if source_kind not in evidence.PHOTO_PERMUTATION_SOURCE_KINDS:
        raise ProducerError("source kind is invalid")
    if state_root.exists() or state_root.is_symlink():
        _require_plain_directory(state_root, "producer state root")
    else:
        state_root.mkdir(mode=0o700)
    contract_digest = ensure_group_contract(state_root, group_contract)
    receipts = state_root / "receipts"
    if receipts.exists():
        _require_plain_directory(receipts, "producer receipt root")
    else:
        receipts.mkdir(mode=0o700)
    variants: list[dict[str, Any]] = []
    for spec in schedule:
        receipt_path = receipts / f"{spec.variant_id}.json"
        completed = _load_completed_variant(
            receipt_path,
            group_contract_sha256=contract_digest,
            spec=spec,
            group_id=group_contract["group_id"],
            authentication_key=receipt_authentication_key,
        )
        if completed is not None:
            variants.append(completed)
            continue
        try:
            public = execute_variant(spec)
            validate_public_record(public)
        except ProducerUnavailable as error:
            unavailable = unavailable_public_record(spec.variant_id, error.reason)
            write_private_json(
                receipt_path,
                {
                    "schema_version": 1,
                    "status": "producer_evidence_unavailable",
                    "group_contract_sha256": contract_digest,
                    "public": unavailable,
                },
            )
            return unavailable
        write_private_json(
            receipt_path,
            {
                "schema_version": 1,
                "status": "complete",
                "group_contract_sha256": contract_digest,
                "public_variant": public,
                "authenticator": _opaque_hmac(
                    receipt_authentication_key,
                    b"easysplat-photo-permutation-cache-v1",
                    evidence.canonical_json_bytes(
                        {
                            "group_contract_sha256": contract_digest,
                            "variant_id": spec.variant_id,
                            "public_variant": public,
                        }
                    ),
                ),
            },
        )
        variants.append(public)
    group_payload = {
        "schema_version": 1,
        "mode": mode,
        "expected_variant_count": len(schedule),
        "closure_claims": ["order_mechanics"],
        "variants": variants,
    }
    slot_receipts: list[dict[str, str]] = []
    for spec, expected_public in zip(schedule, variants, strict=True):
        validated_receipt = _load_completed_variant_receipt(
            receipts / f"{spec.variant_id}.json",
            group_contract_sha256=contract_digest,
            spec=spec,
            group_id=group_contract["group_id"],
            authentication_key=receipt_authentication_key,
        )
        if validated_receipt is None or validated_receipt[0] != expected_public:
            raise ProducerError(
                f"completed receipt {spec.variant_id} changed before group sealing"
            )
        slot_receipts.append(
            {
                "variant_id": spec.variant_id,
                "public_variant_sha256": evidence.sha256_bytes(
                    evidence.canonical_json_bytes(expected_public)
                ),
                "receipt_sha256": validated_receipt[1],
            }
        )
    variant_schedule_records = [
        {"variant_id": spec.variant_id, "permutation": spec.public_permutation}
        for spec in schedule
    ]
    execution_receipt = {
        "schema_version": 1,
        "kind": "easysplat-photo-permutation-execution-receipt",
        "group_contract_sha256": contract_digest,
        "request_binding_sha256": group_contract["request_binding_sha256"],
        "source_authorization_sha256": group_contract["source_authorization_sha256"],
        "source_kind": group_contract["source_kind"],
        "trust_boundary": "requires_github_artifact_attestation",
        "source_provenance_commitment": _opaque_hmac(
            receipt_authentication_key,
            b"easysplat-photo-source-provenance-v1",
            evidence.canonical_json_bytes(
                {
                    "source_manifest_sha256": group_contract["source_manifest_sha256"],
                    "source_content_set_sha256": group_contract[
                        "source_content_set_sha256"
                    ],
                    "source_kind": group_contract["source_kind"],
                }
            ),
        ),
        "producer_implementation_sha256": group_contract[
            "producer_implementation_sha256"
        ],
        "adapter_sha256": group_contract["adapter_sha256"],
        "toolchain_closure_sha256": group_contract["toolchain_closure_sha256"],
        "variant_schedule_sha256": evidence.sha256_bytes(
            evidence.canonical_json_bytes(variant_schedule_records)
        ),
        "variant_receipts": slot_receipts,
        "variant_receipts_sha256": evidence.sha256_bytes(
            evidence.canonical_json_bytes(slot_receipts)
        ),
        "group_payload_sha256": evidence.sha256_bytes(
            evidence.canonical_json_bytes(group_payload)
        ),
    }
    execution_receipt_digest = evidence.sha256_bytes(
        evidence.canonical_json_bytes(execution_receipt) + b"\n"
    )
    group = {
        **group_payload,
        "execution_provenance": {
            "schema_version": 1,
            "group_contract_sha256": contract_digest,
            "request_binding_sha256": group_contract["request_binding_sha256"],
            "source_authorization_sha256": execution_receipt[
                "source_authorization_sha256"
            ],
            "source_kind": execution_receipt["source_kind"],
            "trust_boundary": execution_receipt["trust_boundary"],
            "source_provenance_commitment": execution_receipt[
                "source_provenance_commitment"
            ],
            "producer_implementation_sha256": group_contract[
                "producer_implementation_sha256"
            ],
            "adapter_sha256": group_contract["adapter_sha256"],
            "toolchain_closure_sha256": group_contract["toolchain_closure_sha256"],
            "variant_schedule_sha256": execution_receipt["variant_schedule_sha256"],
            "variant_receipts_sha256": execution_receipt["variant_receipts_sha256"],
            "execution_receipt_sha256": execution_receipt_digest,
        },
    }
    try:
        evidence.validate_photo_permutation_group(
            group,
            request,
            formal_release=mode == "release",
            execution_receipt=execution_receipt,
        )
    except evidence.EvidenceError as error:
        raise ProducerError(
            f"completed permutation group is invalid: {error}"
        ) from error
    write_private_json(state_root / "execution-receipt.json", execution_receipt)
    write_private_json(state_root / "group.json", group)
    return group


def _ensure_private_directory(path: Path, label: str) -> Path:
    if path.exists() or path.is_symlink():
        resolved = _require_plain_directory(path, label)
    else:
        path.mkdir(mode=0o700)
        resolved = path.resolve()
    os.chmod(path, 0o700)
    return resolved


def load_or_create_opaque_key(state_root: Path) -> bytes:
    state_root = _ensure_private_directory(state_root, "producer state root")
    path = state_root / ".opaque-content-key"
    if not path.exists() and not path.is_symlink():
        descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        try:
            os.write(descriptor, os.urandom(32))
            os.fsync(descriptor)
        finally:
            os.close(descriptor)
    try:
        snapshot, key = _secure_regular_file(
            path,
            maximum_bytes=32,
            capture_bytes=True,
            require_single_link=True,
        )
        metadata = path.lstat()
    except (OSError, ProducerUnavailable) as error:
        raise ProducerError("opaque content key is unavailable") from error
    if (
        stat.S_ISLNK(metadata.st_mode)
        or not stat.S_ISREG(metadata.st_mode)
        or snapshot.link_count != 1
        or stat.S_IMODE(metadata.st_mode) != 0o600
        or key is None
        or len(key) != 32
    ):
        raise ProducerError("opaque content key is unsafe")
    return key


def _tail(path: Path, maximum_bytes: int = 16 * 1024) -> str:
    try:
        with path.open("rb") as handle:
            handle.seek(0, os.SEEK_END)
            size = handle.tell()
            handle.seek(max(0, size - maximum_bytes))
            return handle.read(maximum_bytes).decode("utf-8", errors="replace")
    except OSError:
        return ""


def _run_geometry_adapter(
    command: list[str],
    *,
    run_root: Path,
    timeout_seconds: int,
    formal_release: bool = False,
) -> tuple[str, str]:
    if formal_release:
        raise ProducerUnavailable("formal_execution_authority_unavailable")
    stdout_path = run_root / "adapter.stdout"
    stderr_path = run_root / "adapter.stderr"
    home = run_root / "home"
    temporary = run_root / "tmp"
    home.mkdir(mode=0o700)
    temporary.mkdir(mode=0o700)
    environment = {
        "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
        "HOME": str(home),
        "TMPDIR": str(temporary),
        "LANG": "C.UTF-8",
    }
    process: subprocess.Popen[bytes] | None = None
    process_group: int | None = None
    process_library = _libproc()
    tracked_descendants: dict[int, tuple[int, int, int]] = {}
    tracking_errors: list[BaseException] = []
    tracking_lock = threading.Lock()
    tracking_stop = threading.Event()
    tracking_thread: threading.Thread | None = None

    def capture_descendants() -> None:
        if process is None:
            return
        pending = [process.pid]
        visited: set[int] = set()
        while pending:
            parent_id = pending.pop()
            if parent_id in visited:
                continue
            visited.add(parent_id)
            for child_id in _child_process_ids(process_library, parent_id):
                identity = _process_identity(process_library, child_id)
                if identity is None:
                    continue
                if identity[0] != os.getuid():
                    raise ProducerUnavailable(
                        "geometry_adapter_process_group_uncontrollable"
                    )
                with tracking_lock:
                    tracked_descendants.setdefault(child_id, identity)
                pending.append(child_id)

    def monitor_descendants() -> None:
        while not tracking_stop.is_set():
            try:
                capture_descendants()
            except BaseException as error:
                tracking_errors.append(error)
                return
            tracking_stop.wait(0.005)
        try:
            capture_descendants()
        except BaseException as error:
            tracking_errors.append(error)

    def terminate_tracked_descendants() -> None:
        tracking_stop.set()
        if tracking_thread is not None:
            tracking_thread.join(timeout=2)
            if tracking_thread.is_alive():
                raise ProducerUnavailable(
                    "geometry_adapter_process_tracking_unavailable"
                )
        if tracking_errors:
            error = tracking_errors[0]
            if isinstance(error, ProducerUnavailable):
                raise error
            raise ProducerUnavailable(
                "geometry_adapter_process_tracking_unavailable"
            ) from error

        def live_descendants() -> list[int]:
            with tracking_lock:
                snapshot = dict(tracked_descendants)
            return [
                process_id
                for process_id, identity in snapshot.items()
                if _process_identity(process_library, process_id) == identity
            ]

        live = live_descendants()
        for process_id in live:
            try:
                os.kill(process_id, signal.SIGTERM)
            except ProcessLookupError:
                pass
            except PermissionError as error:
                raise ProducerUnavailable(
                    "geometry_adapter_process_group_uncontrollable"
                ) from error
        deadline = time.monotonic() + 2
        while live and time.monotonic() < deadline:
            time.sleep(0.01)
            live = live_descendants()
        for process_id in live:
            try:
                os.kill(process_id, signal.SIGKILL)
            except ProcessLookupError:
                pass
            except PermissionError as error:
                raise ProducerUnavailable(
                    "geometry_adapter_process_group_uncontrollable"
                ) from error
        deadline = time.monotonic() + 2
        while time.monotonic() < deadline:
            if not live_descendants():
                return
            time.sleep(0.01)
        if live_descendants():
            raise ProducerUnavailable("geometry_adapter_process_group_leaked")

    def terminate_group() -> None:
        if process is None or process_group is None:
            return
        try:
            os.killpg(process_group, signal.SIGTERM)
        except ProcessLookupError:
            return
        except PermissionError as error:
            raise ProducerUnavailable(
                "geometry_adapter_process_group_uncontrollable"
            ) from error
        try:
            process.wait(timeout=10)
        except subprocess.TimeoutExpired:
            try:
                os.killpg(process_group, signal.SIGKILL)
            except ProcessLookupError:
                pass
            process.wait()
        deadline = time.monotonic() + 2
        while time.monotonic() < deadline:
            try:
                os.killpg(process_group, 0)
            except (ProcessLookupError, PermissionError):
                return
            time.sleep(0.01)
        try:
            os.killpg(process_group, signal.SIGKILL)
        except (ProcessLookupError, PermissionError):
            return
        deadline = time.monotonic() + 2
        while time.monotonic() < deadline:
            try:
                os.killpg(process_group, 0)
            except (ProcessLookupError, PermissionError):
                return
            time.sleep(0.01)
        raise ProducerUnavailable("geometry_adapter_process_group_leaked")

    def interrupted(signal_number: int, _frame: Any) -> None:
        raise ProducerInterrupted(signal_number)

    prior_handlers = {
        signal_number: signal.getsignal(signal_number)
        for signal_number in (signal.SIGINT, signal.SIGTERM)
    }
    for signal_number in prior_handlers:
        signal.signal(signal_number, interrupted)
    try:
        with stdout_path.open("wb") as stdout, stderr_path.open("wb") as stderr:
            process = subprocess.Popen(
                [
                    "/bin/sh",
                    "-c",
                    'sleep 0.05; exec "$@"',
                    "easysplat-geometry-adapter",
                    *command,
                ],
                stdin=subprocess.DEVNULL,
                stdout=stdout,
                stderr=stderr,
                env=environment,
                start_new_session=True,
            )
            process_group = process.pid
            tracking_thread = threading.Thread(
                target=monitor_descendants,
                name="photo-permutation-process-monitor",
                daemon=True,
            )
            tracking_thread.start()
            try:
                return_code = process.wait(timeout=timeout_seconds)
            except subprocess.TimeoutExpired as error:
                try:
                    terminate_group()
                finally:
                    terminate_tracked_descendants()
                raise ProducerUnavailable("geometry_adapter_timeout") from error
            except KeyboardInterrupt as error:
                try:
                    terminate_group()
                finally:
                    terminate_tracked_descendants()
                raise ProducerInterrupted(signal.SIGINT) from error
            except ProducerInterrupted:
                try:
                    terminate_group()
                finally:
                    terminate_tracked_descendants()
                raise
            terminate_group()
            terminate_tracked_descendants()
    finally:
        tracking_stop.set()
        if tracking_thread is not None and tracking_thread.is_alive():
            tracking_thread.join(timeout=2)
        for signal_number, handler in prior_handlers.items():
            signal.signal(signal_number, handler)
    stdout_tail = _tail(stdout_path)
    stderr_tail = _tail(stderr_path)
    if return_code != 0:
        raise ProducerUnavailable("geometry_adapter_failed")
    return stdout_tail, stderr_tail


def _validated_private_observation(value: Any) -> dict[str, Any]:
    if (
        not isinstance(value, dict)
        or set(value) != PRIVATE_OBSERVATION_FIELDS
        or type(value.get("schema_version")) is not int
        or value["schema_version"] != 1
    ):
        raise ProducerUnavailable("private_observation_invalid")
    if (
        not isinstance(value["private_order_manifest_sha256"], str)
        or evidence.SHA256_PATTERN.fullmatch(
            value["private_order_manifest_sha256"]
        )
        is None
        or not isinstance(value["order_commitment"], str)
        or evidence.OPAQUE_SHA256_PATTERN.fullmatch(value["order_commitment"])
        is None
        or not isinstance(value["content_set_attestation"], str)
        or evidence.OPAQUE_SHA256_PATTERN.fullmatch(
            value["content_set_attestation"]
        )
        is None
    ):
        raise ProducerUnavailable("private_observation_invalid")

    selected = value["selected_content_ids"]
    registered = value["registered_content_ids"]
    if (
        not isinstance(selected, list)
        or len(selected) < 2
        or any(
            not isinstance(content_id, str)
            or evidence.OPAQUE_SHA256_PATTERN.fullmatch(content_id) is None
            for content_id in selected
        )
        or selected != sorted(set(selected))
        or not isinstance(registered, list)
        or not registered
        or any(not isinstance(content_id, str) for content_id in registered)
        or registered != sorted(set(registered))
        or any(content_id not in set(selected) for content_id in registered)
    ):
        raise ProducerUnavailable("private_observation_invalid")

    edges = value["normalized_pair_edges"]
    if not isinstance(edges, list) or not edges:
        raise ProducerUnavailable("private_observation_invalid")
    validated_edges: list[dict[str, str]] = []
    edge_ids: set[str] = set()
    selected_set = set(selected)
    for raw_edge in edges:
        if not isinstance(raw_edge, dict) or set(raw_edge) != {
            "content_a",
            "content_b",
            "edge_id",
        }:
            raise ProducerUnavailable("private_observation_invalid")
        content_a = raw_edge["content_a"]
        content_b = raw_edge["content_b"]
        edge_id = raw_edge["edge_id"]
        if (
            not isinstance(content_a, str)
            or not isinstance(content_b, str)
            or not isinstance(edge_id, str)
            or content_a not in selected_set
            or content_b not in selected_set
            or content_a >= content_b
            or edge_id != evidence._photo_pair_edge_id(content_a, content_b)
            or edge_id in edge_ids
        ):
            raise ProducerUnavailable("private_observation_invalid")
        edge_ids.add(edge_id)
        validated_edges.append(dict(raw_edge))
    if validated_edges != sorted(validated_edges, key=lambda edge: edge["edge_id"]):
        raise ProducerUnavailable("private_observation_invalid")
    _require_connected_content_graph(selected, validated_edges)

    pairing_policy = value["pairing_policy"]
    accepted_attempt = value["accepted_attempt"]
    policy_attempts = {
        "unordered_exhaustive": {"exhaustive_primary"},
        "unordered_retrieval": {
            "vocabulary_retrieval",
            "exhaustive_recovery",
        },
    }
    if (
        not isinstance(pairing_policy, str)
        or not isinstance(accepted_attempt, str)
        or pairing_policy not in policy_attempts
        or accepted_attempt not in policy_attempts[pairing_policy]
    ):
        raise ProducerUnavailable("private_observation_invalid")

    count_fields = (
        "scheduled_pair_count",
        "attempted_pair_count",
        "raw_matched_pair_count",
        "spatially_verified_pair_count",
    )
    if any(type(value[field]) is not int for field in count_fields):
        raise ProducerUnavailable("private_observation_invalid")
    scheduled_count = value["scheduled_pair_count"]
    attempted_count = value["attempted_pair_count"]
    raw_matched_count = value["raw_matched_pair_count"]
    verified_count = value["spatially_verified_pair_count"]
    if (
        scheduled_count <= 0
        or attempted_count != scheduled_count
        or not 0 < verified_count <= raw_matched_count <= attempted_count
        or verified_count != len(validated_edges)
    ):
        raise ProducerUnavailable("private_observation_invalid")
    graph_digest_fields = (
        "scheduled_pair_graph_sha256",
        "attempted_pair_graph_sha256",
        "raw_matched_pair_graph_sha256",
    )
    if any(
        not isinstance(value[field], str)
        or evidence.OPAQUE_SHA256_PATTERN.fullmatch(value[field]) is None
        for field in graph_digest_fields
    ):
        raise ProducerUnavailable("private_observation_invalid")
    if value["scheduled_pair_graph_sha256"] != value[
        "attempted_pair_graph_sha256"
    ]:
        raise ProducerUnavailable("private_observation_invalid")
    verified_graph_digest = evidence._photo_pair_graph_digest(
        [edge["edge_id"] for edge in validated_edges]
    )
    if (
        raw_matched_count == verified_count
        and value["raw_matched_pair_graph_sha256"] != verified_graph_digest
    ):
        raise ProducerUnavailable("private_observation_invalid")

    pair_counts = value["pair_counts"]
    if (
        not isinstance(pair_counts, dict)
        or set(pair_counts) != PRIVATE_PAIR_COUNT_FIELDS
        or any(type(count) is not int or count < 0 for count in pair_counts.values())
        or pair_counts["temporal"] != 0
        or sum(pair_counts.values()) != verified_count
    ):
        raise ProducerUnavailable("private_observation_invalid")
    retrieval_executed = value["retrieval_worker_executed"]
    if type(retrieval_executed) is not bool:
        raise ProducerUnavailable("private_observation_invalid")
    selected_count = len(selected)
    exhaustive_pair_count = selected_count * (selected_count - 1) // 2
    if accepted_attempt == "exhaustive_primary":
        if (
            selected_count > 60
            or scheduled_count != exhaustive_pair_count
            or retrieval_executed
            or pair_counts["exhaustive_primary"] != verified_count
        ):
            raise ProducerUnavailable("private_observation_invalid")
    elif accepted_attempt == "exhaustive_recovery":
        if (
            not 60 < selected_count <= 250
            or scheduled_count != exhaustive_pair_count
            or retrieval_executed
            or pair_counts["exhaustive_recovery"] != verified_count
        ):
            raise ProducerUnavailable("private_observation_invalid")
    elif (
        selected_count <= 60
        or not retrieval_executed
        or pair_counts["exhaustive_primary"] != 0
        or pair_counts["exhaustive_recovery"] != 0
        or pair_counts["vocabulary_retrieval"]
        + pair_counts["loop_revisit"]
        != verified_count
    ):
        raise ProducerUnavailable("private_observation_invalid")

    registered_views = value["registered_views"]
    point_count = value["point_count"]
    observation_count = value["observation_count"]
    median = value["residual_median_pixels"]
    p90 = value["residual_p90_pixels"]
    if (
        type(registered_views) is not int
        or registered_views != len(registered)
        or type(point_count) is not int
        or point_count <= 0
        or type(observation_count) is not int
        or observation_count <= 0
        or isinstance(median, bool)
        or not isinstance(median, (int, float))
        or isinstance(p90, bool)
        or not isinstance(p90, (int, float))
        or not math.isfinite(float(median))
        or not math.isfinite(float(p90))
        or median < 0
        or p90 < median
    ):
        raise ProducerUnavailable("private_observation_invalid")
    try:
        poses = evidence._coerce_name_bound_pose_mapping(
            value["poses"], label="private observation poses"
        )
    except evidence.PoseAlignmentError as error:
        raise ProducerUnavailable("private_observation_invalid") from error
    if set(poses) != set(registered):
        raise ProducerUnavailable("private_observation_invalid")
    return dict(value)


def _private_observation_receipt(
    observation: Any,
    *,
    group_contract_sha256: str,
    variant_id: str,
    authentication_key: bytes,
) -> dict[str, Any]:
    validated = _validated_private_observation(observation)
    authenticated_payload = {
        "schema_version": 1,
        "group_contract_sha256": group_contract_sha256,
        "variant_id": variant_id,
        "observation": validated,
    }
    return {
        **authenticated_payload,
        "authenticator": _opaque_hmac(
            authentication_key,
            b"easysplat-photo-private-observation-v1",
            evidence.canonical_json_bytes(authenticated_payload),
        ),
    }


def _load_private_observation_receipt(
    path: Path,
    *,
    group_contract_sha256: str,
    variant_id: str,
    authentication_key: bytes,
) -> tuple[dict[str, Any], str]:
    try:
        snapshot, data = _secure_regular_file(
            path,
            maximum_bytes=MAXIMUM_PRIVATE_JSON_BYTES,
            capture_bytes=True,
            require_single_link=True,
        )
        if data is None or snapshot.permission_mode != 0o600:
            raise ProducerUnavailable("canonical_observation_unavailable")
        value = json.loads(data)
        if (
            not isinstance(value, dict)
            or set(value)
            != {
                "schema_version",
                "group_contract_sha256",
                "variant_id",
                "observation",
                "authenticator",
            }
            or type(value.get("schema_version")) is not int
            or value["schema_version"] != 1
            or value.get("group_contract_sha256") != group_contract_sha256
            or value.get("variant_id") != variant_id
        ):
            raise ProducerUnavailable("canonical_observation_unavailable")
        observation = _validated_private_observation(value.get("observation"))
        authenticated_payload = {
            "schema_version": 1,
            "group_contract_sha256": group_contract_sha256,
            "variant_id": variant_id,
            "observation": observation,
        }
        expected_authenticator = _opaque_hmac(
            authentication_key,
            b"easysplat-photo-private-observation-v1",
            evidence.canonical_json_bytes(authenticated_payload),
        )
        authenticator = value.get("authenticator")
        if (
            not isinstance(authenticator, str)
            or evidence.OPAQUE_SHA256_PATTERN.fullmatch(authenticator) is None
            or not hmac.compare_digest(authenticator, expected_authenticator)
        ):
            raise ProducerUnavailable("canonical_observation_unavailable")
        return observation, authenticator
    except (
        json.JSONDecodeError,
        UnicodeError,
        OverflowError,
        RecursionError,
        ValueError,
        ProducerError,
        OSError,
    ) as error:
        if (
            isinstance(error, ProducerUnavailable)
            and error.reason == "canonical_observation_unavailable"
        ):
            raise
        raise ProducerUnavailable("canonical_observation_unavailable") from error


def _load_private_observation(
    path: Path,
    *,
    group_contract_sha256: str,
    variant_id: str,
    authentication_key: bytes,
) -> dict[str, Any]:
    return _load_private_observation_receipt(
        path,
        group_contract_sha256=group_contract_sha256,
        variant_id=variant_id,
        authentication_key=authentication_key,
    )[0]


def _publish_canonical_observation(
    path: Path,
    observation: Any,
    *,
    group_contract_sha256: str,
    authentication_key: bytes,
) -> tuple[dict[str, Any], str]:
    receipt = _private_observation_receipt(
        observation,
        group_contract_sha256=group_contract_sha256,
        variant_id="canonical",
        authentication_key=authentication_key,
    )
    _write_new_private_json(path, receipt)
    stored, attestation = _load_private_observation_receipt(
        path,
        group_contract_sha256=group_contract_sha256,
        variant_id="canonical",
        authentication_key=authentication_key,
    )
    if stored != receipt["observation"] or not hmac.compare_digest(
        attestation,
        receipt["authenticator"],
    ):
        raise ProducerUnavailable("canonical_observation_changed")
    return stored, attestation


def execute_fresh_variant(
    spec: VariantSpec,
    *,
    manifest: dict[str, Any],
    source_root: Path,
    request: Mapping[str, Any],
    request_path: Path,
    toolchain_root: Path,
    adapter: Path,
    state_root: Path,
    run_parent: Path,
    source_kind: str,
    group_id: str,
    group_contract: Mapping[str, Any],
    runtime_context: RuntimeGroupContext,
    bound_toolchain: BoundToolchainContext,
    timeout_seconds: int,
) -> dict[str, Any]:
    validate_runtime_path_separation(
        source_root=source_root,
        state_root=state_root,
        run_parent=run_parent,
        toolchain_root=toolchain_root,
        request_path=request_path,
        adapter=adapter,
    )
    state_root = _ensure_private_directory(state_root, "producer state root")
    contract_digest = ensure_group_contract(state_root, group_contract)
    if runtime_context.contract != dict(group_contract):
        raise ProducerError("runtime inputs do not match the immutable group contract")
    revalidate_runtime_group_context(runtime_context)
    if bound_toolchain.closure_sha256 != group_contract["toolchain_closure_sha256"]:
        raise ProducerError(
            "bound toolchain does not match the immutable group contract"
        )
    _revalidate_toolchain_snapshot(
        bound_toolchain.root,
        bound_toolchain.files,
        bound_toolchain.directories,
    )
    run_parent = _ensure_private_directory(run_parent, "producer run parent")
    recover_stale_owned_runs(
        state_root=state_root,
        run_parent=run_parent,
        group_contract_sha256=contract_digest,
    )
    _require_plain_directory(toolchain_root, "toolchain root")
    _read_bounded(request_path, maximum_bytes=16 * 1024 * 1024)
    try:
        adapter_metadata = adapter.lstat()
    except OSError as error:
        raise ProducerError("geometry adapter is unavailable") from error
    if (
        stat.S_ISLNK(adapter_metadata.st_mode)
        or not stat.S_ISREG(adapter_metadata.st_mode)
        or not os.access(adapter, os.X_OK)
    ):
        raise ProducerError("geometry adapter must be a plain executable")
    key = load_or_create_opaque_key(state_root)
    private_materializations = state_root / "materializations"
    private_observations = state_root / "observations"
    private_executions = state_root / "executions"
    for directory, label in (
        (private_materializations, "materialization receipt root"),
        (private_observations, "observation root"),
        (private_executions, "execution receipt root"),
    ):
        _ensure_private_directory(directory, label)

    canonical_observation_path = private_observations / "canonical.json"
    if spec.permutation_index == 0 and (
        canonical_observation_path.exists()
        or canonical_observation_path.is_symlink()
    ):
        observation, canonical_observation_attestation = (
            _load_private_observation_receipt(
                canonical_observation_path,
                group_contract_sha256=contract_digest,
                variant_id="canonical",
                authentication_key=key,
            )
        )
        public = build_public_variant(
            observation,
            spec=spec,
            group_id=group_id,
            source_kind=source_kind,
            request=request,
            canonical_observation=None,
            canonical_observation_attestation=(
                canonical_observation_attestation
            ),
        )
        write_private_json(
            private_executions / f"{spec.variant_id}.json",
            {
                "schema_version": 1,
                "status": "complete",
                "group_contract_sha256": contract_digest,
                "variant_id": spec.variant_id,
                "adapter_stdout_tail": "",
                "adapter_stderr_tail": "",
                "public_variant": public,
            },
        )
        return public

    run_root = Path(tempfile.mkdtemp(prefix=f"run-{spec.variant_id}-", dir=run_parent))
    os.chmod(run_root, 0o700)
    owned_run = register_owned_run(
        run_root,
        run_parent=run_parent,
        state_root=state_root,
        group_contract_sha256=contract_digest,
    )
    input_root = run_root / "input"
    project_root = run_root / MEASUREMENT_PROJECT_LEAF
    adapter_output = run_root / "adapter.json"
    try:
        staged_runtime = run_root / "runtime"
        staged_runtime.mkdir(mode=0o700)
        staged_request = staged_runtime / "request.json"
        staged_adapter = staged_runtime / "geometry-adapter"
        staged_request_snapshot = stage_pinned_runtime_file(
            runtime_context.request_path,
            runtime_context.request_snapshot,
            staged_request,
            executable=False,
        )
        staged_adapter_snapshot = stage_pinned_runtime_file(
            runtime_context.adapter_path,
            runtime_context.adapter_snapshot,
            staged_adapter,
            executable=True,
        )
        scale, _, _ = evidence._photo_permutation_request_contract(request)
        materialization = materialize_variant(
            manifest,
            source_root=source_root,
            destination=input_root,
            scale=scale,
            permutation_index=spec.permutation_index,
            permutation_seed=spec.permutation_seed,
            pinned_sources=dict(runtime_context.source_files),
        )
        write_private_json(
            private_materializations / f"{spec.variant_id}.json",
            {
                "schema_version": 1,
                "group_contract_sha256": contract_digest,
                "variant_id": spec.variant_id,
                "materialization": materialization,
            },
        )
        command = geometry_only_command(
            adapter=staged_adapter,
            request_path=staged_request,
            input_root=input_root,
            toolchain_root=bound_toolchain.root,
            project_root=project_root,
            output_path=adapter_output,
        )
        if project_root.exists() or project_root.is_symlink():
            raise ProducerUnavailable("fresh_project_preexisted")
        stdout_tail, stderr_tail = _run_geometry_adapter(
            command,
            run_root=run_root,
            timeout_seconds=timeout_seconds,
            formal_release=group_contract["mode"] == "release",
        )
        try:
            controlled_project_root = _require_plain_directory(
                project_root, "fresh geometry project root"
            )
        except ProducerError as error:
            raise ProducerUnavailable("fresh_project_unavailable") from error
        _revalidate_file_snapshot(
            staged_request,
            staged_request_snapshot,
            reason="staged_request_changed_during_geometry",
        )
        _revalidate_file_snapshot(
            staged_adapter,
            staged_adapter_snapshot,
            reason="staged_adapter_changed_during_geometry",
        )
        revalidate_runtime_group_context(runtime_context)
        _revalidate_toolchain_snapshot(
            bound_toolchain.root,
            bound_toolchain.files,
            bound_toolchain.directories,
        )
        envelope = _load_bounded_json(adapter_output, maximum_bytes=2 * 1024 * 1024)
        observation = derive_private_geometry_observation(
            envelope,
            mapping=materialization["mapping"],
            requested_plan=request["candidate_run_configuration"],
            hmac_key=key,
            expected_project_root=controlled_project_root,
            expected_variant="candidate",
        )
        observation_path = private_observations / f"{spec.variant_id}.json"
        if spec.permutation_index == 0:
            observation, canonical_observation_attestation = (
                _publish_canonical_observation(
                    observation_path,
                    observation,
                    group_contract_sha256=contract_digest,
                    authentication_key=key,
                )
            )
            canonical = None
        else:
            write_private_json(
                observation_path,
                _private_observation_receipt(
                    observation,
                    group_contract_sha256=contract_digest,
                    variant_id=spec.variant_id,
                    authentication_key=key,
                ),
            )
            canonical, canonical_observation_attestation = (
                _load_private_observation_receipt(
                    private_observations / "canonical.json",
                    group_contract_sha256=contract_digest,
                    variant_id="canonical",
                    authentication_key=key,
                )
            )
        public = build_public_variant(
            observation,
            spec=spec,
            group_id=group_id,
            source_kind=source_kind,
            request=request,
            canonical_observation=canonical,
            canonical_observation_attestation=(
                canonical_observation_attestation
            ),
        )
        write_private_json(
            private_executions / f"{spec.variant_id}.json",
            {
                "schema_version": 1,
                "status": "complete",
                "group_contract_sha256": contract_digest,
                "variant_id": spec.variant_id,
                "adapter_stdout_tail": stdout_tail,
                "adapter_stderr_tail": stderr_tail,
                "public_variant": public,
            },
        )
        return public
    except ProducerUnavailable as error:
        write_private_json(
            private_executions / f"{spec.variant_id}.json",
            {
                "schema_version": 1,
                "status": "producer_evidence_unavailable",
                "group_contract_sha256": contract_digest,
                "variant_id": spec.variant_id,
                "reason": error.reason,
                "adapter_stdout_tail": _tail(run_root / "adapter.stdout"),
                "adapter_stderr_tail": _tail(run_root / "adapter.stderr"),
            },
        )
        raise
    finally:
        remove_owned_run(owned_run)


def _load_json_file(
    path: Path, label: str, maximum_bytes: int = 16 * 1024 * 1024
) -> Any:
    return _load_json_file_with_sha256(path, label, maximum_bytes)[0]


def _load_json_file_with_sha256(
    path: Path, label: str, maximum_bytes: int = 16 * 1024 * 1024
) -> tuple[Any, str]:
    try:
        raw = _read_bounded(path, maximum_bytes=maximum_bytes)
        return json.loads(raw), evidence.sha256_bytes(raw)
    except (json.JSONDecodeError, UnicodeError, ProducerUnavailable) as error:
        raise ProducerError(f"{label} is invalid") from error


def _arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Inventory and run private unordered-photo permutation evidence."
    )
    subparsers = parser.add_subparsers(dest="command", required=True)

    inventory = subparsers.add_parser("inventory")
    inventory.add_argument("--source-root", type=Path, required=True)
    inventory.add_argument("--corpus-id", required=True)
    inventory.add_argument(
        "--source-kind",
        choices=tuple(sorted(evidence.PHOTO_PERMUTATION_SOURCE_KINDS)),
        required=True,
    )
    inventory.add_argument("--origin-manifest", type=Path, required=True)
    inventory.add_argument("--output", type=Path, required=True)

    def common(subparser: argparse.ArgumentParser, *, runtime: bool) -> None:
        subparser.add_argument("--source-manifest", type=Path, required=True)
        subparser.add_argument("--request", type=Path, required=True)
        subparser.add_argument(
            "--source-kind",
            choices=tuple(sorted(evidence.PHOTO_PERMUTATION_SOURCE_KINDS)),
            required=True,
        )
        subparser.add_argument("--shuffle-count", type=int, default=2)
        subparser.add_argument(
            "--mode", choices=("development", "release"), default="development"
        )
        if runtime:
            subparser.add_argument("--source-root", type=Path, required=True)
            subparser.add_argument("--toolchain-root", type=Path, required=True)
            subparser.add_argument("--adapter", type=Path, required=True)
            subparser.add_argument("--state-root", type=Path, required=True)
            subparser.add_argument("--run-parent", type=Path, required=True)
            subparser.add_argument("--group-id", required=True)
            subparser.add_argument("--timeout-seconds", type=int, default=7_200)

    dry_run = subparsers.add_parser("dry-run")
    common(dry_run, runtime=False)

    run_one = subparsers.add_parser("run-one")
    common(run_one, runtime=True)
    run_one.add_argument("--index", type=int, required=True)
    run_one.add_argument("--seed", type=int)

    run_group_parser = subparsers.add_parser("run-group")
    common(run_group_parser, runtime=True)
    return parser.parse_args()


def _main() -> int:
    arguments = _arguments()
    try:
        if (
            arguments.command in {"run-one", "run-group"}
            and arguments.mode == "release"
        ):
            raise ProducerUnavailable("formal_execution_authority_unavailable")
        if arguments.command == "inventory":
            origin_manifest, origin_manifest_file_sha256 = _load_json_file_with_sha256(
                arguments.origin_manifest,
                "derived origin manifest",
            )
            manifest = inventory_source_manifest(
                arguments.source_root,
                corpus_id=arguments.corpus_id,
                source_kind=arguments.source_kind,
                origin_manifest=origin_manifest,
                origin_manifest_file_sha256=origin_manifest_file_sha256,
            )
            write_new_inventory_manifest(
                arguments.output,
                manifest,
                source_root=arguments.source_root,
            )
            output = {
                "schema_version": 1,
                "status": "inventory_complete",
                "corpus_id": manifest["corpus_id"],
                "file_count": len(manifest["entries"]),
            }
            sys.stdout.buffer.write(evidence.canonical_json_bytes(output) + b"\n")
            return 0
        manifest = _load_json_file(arguments.source_manifest, "source manifest")
        request = _load_json_file(arguments.request, "measurement request")
        if arguments.command == "dry-run":
            output = dry_run_plan(
                manifest,
                request,
                mode=arguments.mode,
                shuffle_count=arguments.shuffle_count,
                source_kind=arguments.source_kind,
            )
        elif arguments.command == "run-one":
            validate_runtime_path_separation(
                source_root=arguments.source_root,
                state_root=arguments.state_root,
                run_parent=arguments.run_parent,
                toolchain_root=arguments.toolchain_root,
                request_path=arguments.request,
                adapter=arguments.adapter,
            )
            spec = single_variant_spec(
                mode=arguments.mode,
                index=arguments.index,
                seed=arguments.seed,
            )
            schedule = variant_schedule(
                mode=arguments.mode,
                shuffle_count=arguments.shuffle_count,
            )
            if spec not in schedule:
                raise ProducerError(
                    "run-one permutation is outside the declared group schedule"
                )
            runtime_context = capture_runtime_group_context(
                manifest=manifest,
                source_root=arguments.source_root,
                request=request,
                request_path=arguments.request,
                group_id=arguments.group_id,
                source_kind=arguments.source_kind,
                mode=arguments.mode,
                shuffle_count=arguments.shuffle_count,
                adapter=arguments.adapter,
                toolchain_root=arguments.toolchain_root,
            )
            group_contract = runtime_context.contract
            contract_digest = ensure_group_contract(
                arguments.state_root, group_contract
            )
            bound_toolchain = prepare_bound_toolchain(
                runtime_context,
                state_root=arguments.state_root,
                group_contract_sha256=contract_digest,
            )
            output = execute_fresh_variant(
                spec,
                manifest=manifest,
                source_root=arguments.source_root,
                request=request,
                request_path=arguments.request,
                toolchain_root=arguments.toolchain_root,
                adapter=arguments.adapter,
                state_root=arguments.state_root,
                run_parent=arguments.run_parent,
                source_kind=arguments.source_kind,
                group_id=arguments.group_id,
                group_contract=group_contract,
                runtime_context=runtime_context,
                bound_toolchain=bound_toolchain,
                timeout_seconds=arguments.timeout_seconds,
            )
        else:
            validate_runtime_path_separation(
                source_root=arguments.source_root,
                state_root=arguments.state_root,
                run_parent=arguments.run_parent,
                toolchain_root=arguments.toolchain_root,
                request_path=arguments.request,
                adapter=arguments.adapter,
            )
            runtime_context = capture_runtime_group_context(
                manifest=manifest,
                source_root=arguments.source_root,
                request=request,
                request_path=arguments.request,
                group_id=arguments.group_id,
                source_kind=arguments.source_kind,
                mode=arguments.mode,
                shuffle_count=arguments.shuffle_count,
                adapter=arguments.adapter,
                toolchain_root=arguments.toolchain_root,
            )
            group_contract = runtime_context.contract
            contract_digest = ensure_group_contract(
                arguments.state_root, group_contract
            )
            bound_toolchain = prepare_bound_toolchain(
                runtime_context,
                state_root=arguments.state_root,
                group_contract_sha256=contract_digest,
            )
            output = orchestrate_group(
                request=request,
                state_root=arguments.state_root,
                mode=arguments.mode,
                shuffle_count=arguments.shuffle_count,
                source_kind=arguments.source_kind,
                group_contract=group_contract,
                receipt_authentication_key=load_or_create_opaque_key(
                    arguments.state_root
                ),
                execute_variant=lambda spec: execute_fresh_variant(
                    spec,
                    manifest=manifest,
                    source_root=arguments.source_root,
                    request=request,
                    request_path=arguments.request,
                    toolchain_root=arguments.toolchain_root,
                    adapter=arguments.adapter,
                    state_root=arguments.state_root,
                    run_parent=arguments.run_parent,
                    source_kind=arguments.source_kind,
                    group_id=arguments.group_id,
                    group_contract=group_contract,
                    runtime_context=runtime_context,
                    bound_toolchain=bound_toolchain,
                    timeout_seconds=arguments.timeout_seconds,
                ),
            )
        sys.stdout.buffer.write(evidence.canonical_json_bytes(output) + b"\n")
        return 0
    except ProducerInterrupted as error:
        sys.stderr.write(f"photo permutation producer: {error}\n")
        return 130
    except (ProducerError, evidence.EvidenceError, OSError) as error:
        sys.stderr.write(f"photo permutation producer: {error}\n")
        return 1


def main() -> int:
    def interrupted(signal_number: int, _frame: Any) -> None:
        raise ProducerInterrupted(signal_number)

    prior_handlers = {
        signal_number: signal.getsignal(signal_number)
        for signal_number in (signal.SIGINT, signal.SIGTERM)
    }
    for signal_number in prior_handlers:
        signal.signal(signal_number, interrupted)
    try:
        return _main()
    finally:
        for signal_number, handler in prior_handlers.items():
            signal.signal(signal_number, handler)


if __name__ == "__main__":
    if __spec__ is not None:
        sys.stderr.write(
            "photo permutation producer: execute the source file directly; "
            "module bytecode is not accepted\n"
        )
        raise SystemExit(1)
    raise SystemExit(main())
