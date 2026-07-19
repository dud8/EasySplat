from __future__ import annotations

import hashlib
import json
import os
import signal
import shutil
import stat
import subprocess
import sys
import tempfile
import time
import unittest
from pathlib import Path
from unittest import mock

from scripts.benchmark import evidence_protocol as evidence
from scripts.benchmark import photo_permutation_producer as producer


def digest_bytes(value: bytes) -> str:
    return "sha256:" + hashlib.sha256(value).hexdigest()


def native_origin_manifest(files: dict[str, bytes]) -> dict[str, object]:
    return {
        "schema_version": 1,
        "sources": [
            {"kind": "native_photo", "source_sha256": digest_bytes(contents)}
            for _, contents in sorted(files.items())
        ],
    }


def request(scale: int = 3) -> dict[str, object]:
    configuration = {
        "capture_path": "automatic",
        "input_topology": "unordered",
        "camera_grouping": "automatic",
        "lens_projection": "automatic",
        "pairing_policy": (
            "unordered_exhaustive" if scale <= 60 else "unordered_retrieval"
        ),
        "temporal_pairing": "none",
        "temporal_offsets": [],
        "photo_selection": "automatic",
        "vocabulary_candidate_count": 20,
        "vocabulary_returned_neighbor_count": 8,
        "vocabulary_query_stride": 1,
        "descriptor_matcher": "faiss",
        "run_seed": 42,
    }
    return {
        "binding": {"scale": scale},
        "candidate_run_configuration": configuration,
        "category": "object_orbit",
        "input_kind": "photos",
    }


def source_manifest(
    files: dict[str, bytes],
    *,
    source_kind: str = "native_photos",
    video_origin_count: int = 0,
    photo_origin_count: int | None = None,
) -> dict[str, object]:
    entries = [
        {"relative_path": name, "source_sha256": digest_bytes(contents)}
        for name, contents in sorted(files.items())
    ]
    resolved_photo_origins = (
        len(entries) if photo_origin_count is None else photo_origin_count
    )
    origin_closure_value: object
    if source_kind == "native_photos":
        origin_closure_value = [
            {"kind": "native_photo", "source_sha256": source_sha256}
            for source_sha256 in sorted(entry["source_sha256"] for entry in entries)
        ]
    else:
        origin_closure_value = sorted(entry["source_sha256"] for entry in entries)
    return {
        "schema_version": 2,
        "corpus_id": "private-fixture",
        "provenance": {
            "source_kind": source_kind,
            "video_origin_count": video_origin_count,
            "photo_origin_count": resolved_photo_origins,
            "origin_closure_sha256": evidence.sha256_bytes(
                evidence.canonical_json_bytes(origin_closure_value)
            ),
        },
        "entries": entries,
    }


def calibration_crop_manifest(files: dict[str, bytes]) -> dict[str, object]:
    return {
        "schema_version": 1,
        "source": "TUM-VI room1 512x512 camera 0 deterministic 120-frame subset",
        "purpose": "COLMAP forward-hemisphere positive fisheye control",
        "source_directory": "/private/calibration/source",
        "crop_pixels": {"left": 52, "top": 52, "width": 408, "height": 408},
        "maximum_corner_bearing_degrees": 87.45876195189696,
        "maximum_diagonal_field_of_view_degrees": 174.91752390379392,
        "official_camera_model": "equidistant",
        "official_parameters": [
            190.97847715128717,
            190.9733070521226,
            254.93170605935475,
            256.8974428996504,
            0.0034823894022493434,
            0.0007150348452162257,
            -0.0020532361418706202,
            0.00020293673591811182,
        ],
        "entries": [
            {
                "name": name,
                "source_sha256": hashlib.sha256(
                    b"uncropped\0" + name.encode("utf-8")
                ).hexdigest(),
                "output_sha256": hashlib.sha256(contents).hexdigest(),
                "output_bytes": len(contents),
            }
            for name, contents in sorted(files.items())
        ],
    }


def calibration_manifest_constants(
    manifest: dict[str, object],
) -> dict[str, object]:
    raw = evidence.canonical_json_bytes(manifest) + b"\n"
    entries = manifest["entries"]
    assert isinstance(entries, list)
    output_entries = [
        {
            "relative_path": entry["name"],
            "source_sha256": "sha256:" + entry["output_sha256"],
        }
        for entry in entries
    ]
    return {
        "TUMVI_SUPPORTED_CROP_MANIFEST_SHA256": evidence.sha256_bytes(raw),
        "TUMVI_SUPPORTED_CROP_OUTPUT_SET_SHA256": evidence.sha256_bytes(
            evidence.canonical_json_bytes(output_entries)
        ),
        "TUMVI_SUPPORTED_CROP_OUTPUT_COUNT": len(entries),
        "TUMVI_SUPPORTED_CROP_TOTAL_BYTES": sum(
            entry["output_bytes"] for entry in entries
        ),
    }


def protected_source_authorization(
    manifest: dict[str, object],
    request_value: dict[str, object],
    *,
    adapter_sha256: str,
    toolchain_closure_sha256: str,
) -> dict[str, object]:
    entries = manifest["entries"]
    assert isinstance(entries, list)
    binding = request_value["binding"]
    assert isinstance(binding, dict)
    return {
        "schema_version": 1,
        "kind": "easysplat-photo-permutation-source-authorization",
        "request_binding_sha256": evidence.photo_permutation_request_binding_sha256(
            request_value
        ),
        "source_kind": manifest["provenance"]["source_kind"],
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
        "containment_supervisor_sha256": digest_bytes(b"containment-supervisor"),
        "containment_policy_sha256": digest_bytes(b"containment-policy"),
        "dedicated_uid": 520,
        "gh_verifier_sha256": digest_bytes(b"gh-verifier"),
        "source_commit": binding["git_commit"],
        "source_ref": "refs/heads/main",
    }


def protocol_mapping_manifest(manifest: dict[str, object]) -> dict[str, object]:
    return {
        "schema_version": 1,
        "corpus_id": manifest["corpus_id"],
        "entries": manifest["entries"],
    }


def opaque(label: str) -> str:
    return "opaque-sha256:" + hashlib.sha256(label.encode()).hexdigest()


def canonical_string_digest(fields: list[str]) -> str:
    payload = bytearray()
    for field in fields:
        encoded = field.encode("utf-8")
        payload.extend(f"{len(encoded)}:".encode("utf-8"))
        payload.extend(encoded)
    return hashlib.sha256(payload).hexdigest()


def retrieval_receipt(selected: list[str]) -> dict[str, object]:
    query_outcomes = [
        {
            "queryImageName": selected[index],
            "status": "ranked",
            "rankedNeighborImageNames": [selected[(index + 1) % len(selected)]],
        }
        for index in range(len(selected))
    ]
    directed_pairs = sorted(
        {
            " ".join(
                sorted(
                    (outcome["queryImageName"], outcome["rankedNeighborImageNames"][0])
                )
            )
            for outcome in query_outcomes
        }
    )
    request_digest = canonical_string_digest(
        ["localSiftVocabularyV2", "1", "20", "8", "0", *selected]
    )
    contract_lines = [
        " ".join(
            (
                "EASYSPLAT_RETRIEVAL_OUTCOMES_V2",
                "localSiftVocabularyV2",
                "1",
                "20",
                "8",
                "0",
                str(len(selected)),
                request_digest,
            )
        ),
        *[
            " ".join(
                (
                    "Q",
                    outcome["status"],
                    outcome["queryImageName"],
                    str(len(outcome["rankedNeighborImageNames"])),
                    *outcome["rankedNeighborImageNames"],
                )
            )
            for outcome in query_outcomes
        ],
        *[f"P {line}" for line in directed_pairs],
    ]
    return {
        "engine": "localSiftVocabularyV2",
        "queryImageNames": selected,
        "queryStride": 1,
        "candidateCount": 20,
        "returnedNeighborCount": 8,
        "minimumFrameSeparation": 0,
        "queryOutcomes": query_outcomes,
        "directedPairLines": directed_pairs,
        "outputDigest": canonical_string_digest(contract_lines),
    }


def public_variant(spec: producer.VariantSpec, scale: int = 3) -> dict[str, object]:
    selected = sorted(opaque(f"content-{index}") for index in range(scale))
    edges = []
    for first_index in range(scale):
        for second_index in range(first_index + 1, scale):
            content_a, content_b = sorted(
                (selected[first_index], selected[second_index])
            )
            edge_id = (
                "opaque-sha256:"
                + hashlib.sha256(
                    b"easysplat-photo-pair-edge-v1\0"
                    + evidence.canonical_json_bytes([content_a, content_b])
                ).hexdigest()
            )
            edges.append(
                {"content_a": content_a, "content_b": content_b, "edge_id": edge_id}
            )
    edges.sort(key=lambda edge: edge["edge_id"])
    set_digest = (
        "opaque-sha256:"
        + hashlib.sha256(
            b"easysplat-photo-content-set-v1\0"
            + evidence.canonical_json_bytes(selected)
        ).hexdigest()
    )
    graph_digest = (
        "opaque-sha256:"
        + hashlib.sha256(
            b"easysplat-photo-pair-graph-v1\0"
            + evidence.canonical_json_bytes([edge["edge_id"] for edge in edges])
        ).hexdigest()
    )
    return {
        "group_id": "private-fixture-group",
        "variant_id": spec.variant_id,
        "permutation": spec.public_permutation,
        "order_commitment": opaque(f"order-{spec.variant_id}"),
        "content_set_attestation": opaque("attestation"),
        "canonical_observation_attestation": opaque("canonical-observation"),
        "source_kind": "native_photos",
        "selected_content_ids": selected,
        "registered_content_ids": selected,
        "selected_content_set_sha256": set_digest,
        "registered_content_set_sha256": set_digest,
        "normalized_pair_graph_sha256": graph_digest,
        "normalized_pair_edges": edges,
        "requested_plan_sha256": evidence.sha256_bytes(
            evidence.canonical_json_bytes(request(scale)["candidate_run_configuration"])
        ),
        "scale": scale,
        "run_seed": 42,
        "pairing_policy": "unordered_exhaustive",
        "accepted_attempt": "exhaustive_primary",
        "scheduled_pair_count": scale * (scale - 1) // 2,
        "scheduled_pair_graph_sha256": graph_digest,
        "attempted_pair_count": scale * (scale - 1) // 2,
        "attempted_pair_graph_sha256": graph_digest,
        "raw_matched_pair_count": scale * (scale - 1) // 2,
        "raw_matched_pair_graph_sha256": graph_digest,
        "spatially_verified_pair_count": len(edges),
        "retrieval_worker_executed": False,
        "pair_counts": {
            "temporal": 0,
            "vocabulary_retrieval": 0,
            "loop_revisit": 0,
            "exhaustive_primary": len(edges),
            "exhaustive_recovery": 0,
        },
        "registered_views": scale,
        "point_count": scale * 100,
        "observation_count": scale * 400,
        "residual_median_pixels": 0.5,
        "residual_p90_pixels": 1.0,
        "camera_center_p95_scene_radius_fraction": 0.0,
        "rotation_p95_degrees": 0.0,
    }


def private_observation(scale: int = 3) -> dict[str, object]:
    public = public_variant(producer.VariantSpec("canonical", 0, 0), scale)
    content_ids = public["selected_content_ids"]
    assert isinstance(content_ids, list)
    centers = ([0.0, 0.0, 0.0], [1.0, 0.0, 0.0], [0.0, 1.0, 0.0])
    assert scale == len(centers)
    return {
        "schema_version": 1,
        "private_order_manifest_sha256": digest_bytes(b"private-order"),
        "order_commitment": public["order_commitment"],
        "content_set_attestation": public["content_set_attestation"],
        "selected_content_ids": content_ids,
        "registered_content_ids": public["registered_content_ids"],
        "normalized_pair_edges": public["normalized_pair_edges"],
        "pairing_policy": public["pairing_policy"],
        "accepted_attempt": public["accepted_attempt"],
        "scheduled_pair_count": public["scheduled_pair_count"],
        "scheduled_pair_graph_sha256": public["scheduled_pair_graph_sha256"],
        "attempted_pair_count": public["attempted_pair_count"],
        "attempted_pair_graph_sha256": public["attempted_pair_graph_sha256"],
        "raw_matched_pair_count": public["raw_matched_pair_count"],
        "raw_matched_pair_graph_sha256": public[
            "raw_matched_pair_graph_sha256"
        ],
        "spatially_verified_pair_count": public[
            "spatially_verified_pair_count"
        ],
        "retrieval_worker_executed": public["retrieval_worker_executed"],
        "pair_counts": public["pair_counts"],
        "registered_views": public["registered_views"],
        "point_count": public["point_count"],
        "observation_count": public["observation_count"],
        "residual_median_pixels": public["residual_median_pixels"],
        "residual_p90_pixels": public["residual_p90_pixels"],
        "poses": {
            content_id: {
                "center": list(center),
                "rotation_cw": [
                    [1.0, 0.0, 0.0],
                    [0.0, 1.0, 0.0],
                    [0.0, 0.0, 1.0],
                ],
            }
            for content_id, center in zip(content_ids, centers, strict=True)
        },
    }


def private_observation_receipt(
    observation: dict[str, object],
    *,
    key: bytes,
    group_contract_sha256: str,
    variant_id: str,
) -> dict[str, object]:
    authenticated_payload = {
        "schema_version": 1,
        "group_contract_sha256": group_contract_sha256,
        "variant_id": variant_id,
        "observation": observation,
    }
    return {
        **authenticated_payload,
        "authenticator": producer._opaque_hmac(
            key,
            b"easysplat-photo-private-observation-v1",
            evidence.canonical_json_bytes(authenticated_payload),
        ),
    }


def private_group_contract(
    *,
    manifest: dict[str, object] | None = None,
    request_value: dict[str, object] | None = None,
    group_id: str = "private-fixture-group",
    source_kind: str = "native_photos",
    adapter_label: bytes = b"adapter",
    toolchain_label: bytes = b"toolchain",
    producer_label: bytes | None = None,
    source_authorization_label: bytes | None = None,
) -> dict[str, object]:
    if manifest is None:
        provenance_counts = {
            "native_photos": (0, 3),
            "single_video_derived_stills": (1, 0),
            "multi_video_derived_stills": (2, 0),
            "mixed_derived_stills": (1, 1),
            "calibration_dataset_derived_stills": (0, 0),
        }
        video_origins, photo_origins = provenance_counts[source_kind]
        manifest = source_manifest(
            {"IMG_1.JPG": b"a", "IMG_2.JPG": b"b", "IMG_3.JPG": b"c"},
            source_kind=source_kind,
            video_origin_count=video_origins,
            photo_origin_count=photo_origins,
        )
    return producer.build_group_contract(
        manifest=manifest,
        request=request_value or request(),
        request_file_sha256=digest_bytes(b"request-file"),
        group_id=group_id,
        source_kind=source_kind,
        mode="development",
        shuffle_count=2,
        adapter_sha256=digest_bytes(adapter_label),
        toolchain_closure_sha256=digest_bytes(toolchain_label),
        producer_implementation_sha256=(
            None if producer_label is None else digest_bytes(producer_label)
        ),
        source_authorization_sha256=(
            None
            if source_authorization_label is None
            else digest_bytes(source_authorization_label)
        ),
    )


def seal_public_group(
    value: dict[str, object],
    request_value: dict[str, object] | None = None,
) -> dict[str, object]:
    variants = value["variants"]
    assert isinstance(variants, list)
    schedule = [
        {"variant_id": item["variant_id"], "permutation": item["permutation"]}
        for item in variants
    ]
    slot_receipts = [
        {
            "variant_id": item["variant_id"],
            "public_variant_sha256": evidence.sha256_bytes(
                evidence.canonical_json_bytes(item)
            ),
            "receipt_sha256": digest_bytes(
                f"slot-{item['variant_id']}".encode("utf-8")
            ),
        }
        for item in variants
    ]
    receipt = {
        "schema_version": 1,
        "kind": "easysplat-photo-permutation-execution-receipt",
        "group_contract_sha256": digest_bytes(b"group-contract"),
        "request_binding_sha256": evidence.photo_permutation_request_binding_sha256(
            request_value or request(int(variants[0]["scale"]))
        ),
        "source_authorization_sha256": digest_bytes(b"source-authorization"),
        "source_kind": variants[0]["source_kind"],
        "trust_boundary": "requires_github_artifact_attestation",
        "source_provenance_commitment": opaque("source-provenance"),
        "producer_implementation_sha256": (
            evidence.photo_permutation_producer_implementation_sha256()
        ),
        "adapter_sha256": digest_bytes(b"adapter"),
        "toolchain_closure_sha256": digest_bytes(b"toolchain"),
        "variant_schedule_sha256": evidence.sha256_bytes(
            evidence.canonical_json_bytes(schedule)
        ),
        "variant_receipts": slot_receipts,
        "variant_receipts_sha256": evidence.sha256_bytes(
            evidence.canonical_json_bytes(slot_receipts)
        ),
        "group_payload_sha256": evidence.sha256_bytes(
            evidence.canonical_json_bytes(value)
        ),
    }
    value["execution_provenance"] = {
        "schema_version": 1,
        "group_contract_sha256": receipt["group_contract_sha256"],
        "request_binding_sha256": receipt["request_binding_sha256"],
        "source_authorization_sha256": receipt["source_authorization_sha256"],
        "source_kind": receipt["source_kind"],
        "trust_boundary": receipt["trust_boundary"],
        "source_provenance_commitment": receipt["source_provenance_commitment"],
        "producer_implementation_sha256": receipt["producer_implementation_sha256"],
        "adapter_sha256": receipt["adapter_sha256"],
        "toolchain_closure_sha256": receipt["toolchain_closure_sha256"],
        "variant_schedule_sha256": receipt["variant_schedule_sha256"],
        "variant_receipts_sha256": receipt["variant_receipts_sha256"],
        "execution_receipt_sha256": evidence.sha256_bytes(
            evidence.canonical_json_bytes(receipt) + b"\n"
        ),
    }
    return receipt


def geometry_envelope(project: Path, *, registered_views: int) -> dict[str, object]:
    project = project.resolve()
    return {
        "schema_version": 2,
        "measurement_scope": "geometry_only",
        "variant": "candidate",
        "started_monotonic_seconds": 1.0,
        "ended_monotonic_seconds": 2.0,
        "project_root": str(project),
        "geometry_manifest": str(project / "SfM/geometry_manifest.json"),
        "selection_manifest": str(project / "Frames/selected_manifest.json"),
        "pair_graph_evidence": str(project / "SfM/pair_graph_evidence.json"),
        "canonical_text_model": str(
            project / "Training/measurement-candidate-source-text"
        ),
        "pipeline_log": str(project / "Logs/pipeline.log"),
        "registered_views": registered_views,
        "point_count": 100,
        "observation_count": 200,
        "median_residual_pixels": 0.4,
        "p90_residual_pixels": 0.9,
        "geometry_completed_monotonic_seconds": 1.9,
        "pipeline_stage_seconds": {"sfmMapping": 0.9},
        "stage_seconds": {"geometry": 0.9, "end_to_end": 1.0},
    }


def pair_graph_plan_binding(
    requested_plan: dict[str, object],
) -> dict[str, object]:
    camera_initializer = (
        "sharedOpenCVFisheyeEquidistantDiagonal150V1"
        if requested_plan["camera_grouping"] == "same_camera_and_lens"
        and requested_plan["lens_projection"] == "fisheye"
        else "colmapAutomatic"
    )
    return {
        "pairingPolicy": "unorderedRetrieval",
        "geometryBackend": "colmap",
        "modelIdentifier": "none",
        "temporalPairing": requested_plan["temporal_pairing"],
        "temporalOffsets": requested_plan["temporal_offsets"],
        "retrievalEngine": "localSiftVocabularyV2",
        "retrievalCandidateCount": requested_plan["vocabulary_candidate_count"],
        "retrievalNeighborCount": requested_plan[
            "vocabulary_returned_neighbor_count"
        ],
        "retrievalQueryStride": requested_plan["vocabulary_query_stride"],
        "requiresCrossClipRetrieval": False,
        "normalDescriptorMatcher": requested_plan["descriptor_matcher"],
        "cameraInitializationRecipe": camera_initializer,
        "runSeed": requested_plan["run_seed"],
    }


def write_geometry_project(
    project: Path,
    target_names: list[str],
    *,
    requested_plan: dict[str, object] | None = None,
    mapping_entries: list[dict[str, str]] | None = None,
    source_files: dict[str, bytes] | None = None,
) -> dict[str, object]:
    resolved_plan = requested_plan or request()["candidate_run_configuration"]
    assert isinstance(resolved_plan, dict)
    (project / "Frames").mkdir(parents=True)
    (project / "SfM").mkdir()
    (project / "Logs").mkdir()
    model = project / "Training/measurement-candidate-source-text"
    model.mkdir(parents=True)
    images = [f"frame-{index:06d}.jpg" for index in range(1, len(target_names) + 1)]
    if (mapping_entries is None) != (source_files is None):
        raise AssertionError("mapping entries and source files must be supplied together")
    source_by_digest = (
        {
            digest_bytes(contents): contents
            for contents in source_files.values()
        }
        if source_files is not None
        else {}
    )
    if mapping_entries is not None:
        if [entry["target_relative_path"] for entry in mapping_entries] != target_names:
            raise AssertionError("mapping targets must match the selected target order")
        originals = project / "Originals/Photos"
        originals.mkdir(parents=True)
        for entry in mapping_entries:
            (originals / entry["target_relative_path"]).write_bytes(
                source_by_digest[entry["source_sha256"]]
            )
    selection = []
    for index, (image, target) in enumerate(
        zip(images, target_names, strict=True)
    ):
        item = {
            "outputFileName": image,
            "sourceProjectRelativePath": "Originals/Photos/" + target,
        }
        if mapping_entries is not None:
            item["sourceSHA256"] = mapping_entries[index]["source_sha256"]
        selection.append(item)
    (project / "Frames/selected_manifest.json").write_text(json.dumps(selection))
    scheduled = [
        {
            "firstImageName": images[first],
            "secondImageName": images[second],
            "role": "retrieval",
        }
        for first in range(len(images))
        for second in range(first + 1, len(images))
    ]
    pairs = {
        "schemaVersion": 20,
        "pairingPolicy": "unorderedRetrieval",
        "planBinding": pair_graph_plan_binding(resolved_plan),
        "acceptedAttemptNumber": 1,
        "attempts": [
            {
                "artifact": {
                    "attemptNumber": 1,
                    "matcher": "faiss",
                    "exactRecoveryReason": None,
                    "recoveryLevel": "normal",
                    "outcome": "completed",
                },
                "scheduledPairs": scheduled,
                "retrieval": None,
                "retrievalWasExecuted": False,
            }
        ],
        "acceptedInspection": {
            "scheduledPairCount": len(scheduled),
            "attemptedPairCount": len(scheduled),
            "attemptedPairs": scheduled,
            "rawMatchedPairCount": len(scheduled),
            "rawMatchedPairs": scheduled,
            "spatiallyVerifiedPairCount": len(scheduled),
            "spatiallyVerifiedPairs": scheduled,
        },
    }
    (project / "SfM/pair_graph_evidence.json").write_text(json.dumps(pairs))
    (project / "SfM/geometry_manifest.json").write_text("{}")
    (project / "Logs/pipeline.log").write_text("fixture\n")
    model_lines: list[str] = []
    for index, image in enumerate(images, start=1):
        model_lines.extend([f"{index} 1 0 0 0 {-float(index - 1)} 0 0 1 {image}", ""])
    (model / "images.txt").write_text("\n".join(model_lines) + "\n")
    return geometry_envelope(project, registered_views=len(images))


def write_fake_adapter(path: Path, invocations: Path) -> None:
    path.write_text(
        """#!/usr/bin/python3
import hashlib
import json
import pathlib
import sys

arguments = dict(zip(sys.argv[1::2], sys.argv[2::2]))
assert arguments["--geometry-only"] == "true"
assert pathlib.Path(sys.argv[0]).parent.name == "runtime"
assert pathlib.Path(arguments["--request"]).parent.name == "runtime"
assert pathlib.Path(arguments["--toolchain-root"]).name == "bound-toolchain"
project = pathlib.Path(arguments["--project-root"])
assert project.name == "project.easysplatproj"
project.mkdir()
(project / "Frames").mkdir()
(project / "SfM").mkdir()
(project / "Logs").mkdir()
originals = project / "Originals/Photos"
originals.mkdir(parents=True)
model = project / "Training/measurement-candidate-source-text"
model.mkdir(parents=True)
targets = sorted(path.name for path in pathlib.Path(arguments["--input"]).iterdir())
images = [f"frame-{index:06d}.jpg" for index in range(1, len(targets) + 1)]
target_digests = {
    target: hashlib.sha256(
        (pathlib.Path(arguments["--input"]) / target).read_bytes()
    ).hexdigest()
    for target in targets
}
content_rank = {
    digest: rank for rank, digest in enumerate(sorted(target_digests.values()))
}
selection = [
    {
        "outputFileName": image,
        "sourceProjectRelativePath": "Originals/Photos/" + target,
        "sourceSHA256": target_digests[target],
    }
    for image, target in zip(images, targets)
]
for target in targets:
    (originals / target).write_bytes(
        (pathlib.Path(arguments["--input"]) / target).read_bytes()
    )
(project / "Frames/selected_manifest.json").write_text(json.dumps(selection))
scheduled = [
    {
        "firstImageName": images[first],
        "secondImageName": images[second],
        "role": "retrieval",
    }
    for first in range(len(images))
    for second in range(first + 1, len(images))
]
pairs = {
    "schemaVersion": 20,
    "pairingPolicy": "unorderedRetrieval",
    "planBinding": {
        "pairingPolicy": "unorderedRetrieval",
        "geometryBackend": "colmap",
        "modelIdentifier": "none",
        "temporalPairing": "none",
        "temporalOffsets": [],
        "retrievalEngine": "localSiftVocabularyV2",
        "retrievalCandidateCount": 20,
        "retrievalNeighborCount": 8,
        "retrievalQueryStride": 1,
        "requiresCrossClipRetrieval": False,
        "normalDescriptorMatcher": "faiss",
        "cameraInitializationRecipe": "colmapAutomatic",
        "runSeed": 42,
    },
    "acceptedAttemptNumber": 1,
    "attempts": [{
        "artifact": {
            "attemptNumber": 1,
            "matcher": "faiss",
            "exactRecoveryReason": None,
            "recoveryLevel": "normal",
            "outcome": "completed",
        },
        "scheduledPairs": scheduled,
        "retrieval": None,
        "retrievalWasExecuted": False,
    }],
    "acceptedInspection": {
        "scheduledPairCount": len(scheduled),
        "attemptedPairCount": len(scheduled),
        "attemptedPairs": scheduled,
        "rawMatchedPairCount": len(scheduled),
        "rawMatchedPairs": scheduled,
        "spatiallyVerifiedPairCount": len(scheduled),
        "spatiallyVerifiedPairs": scheduled,
    },
}
(project / "SfM/pair_graph_evidence.json").write_text(json.dumps(pairs))
(project / "SfM/geometry_manifest.json").write_text("{}")
(project / "Logs/pipeline.log").write_text("fake geometry completed\\n")
model_lines = []
for index, (image, target) in enumerate(zip(images, targets), start=1):
    rank = content_rank[target_digests[target]]
    center_x = float(rank)
    center_y = float(rank * rank)
    model_lines.extend([
        f"{index} 1 0 0 0 {-center_x} {-center_y} 0 1 {image}",
        "",
    ])
(model / "images.txt").write_text("\\n".join(model_lines) + "\\n")
envelope = {
    "schema_version": 2,
    "measurement_scope": "geometry_only",
    "variant": "candidate",
    "started_monotonic_seconds": 1.0,
    "ended_monotonic_seconds": 2.0,
    "project_root": str(project),
    "geometry_manifest": str(project / "SfM/geometry_manifest.json"),
    "selection_manifest": str(project / "Frames/selected_manifest.json"),
    "pair_graph_evidence": str(project / "SfM/pair_graph_evidence.json"),
    "canonical_text_model": str(model),
    "pipeline_log": str(project / "Logs/pipeline.log"),
    "registered_views": len(images),
    "point_count": 100,
    "observation_count": 200,
    "median_residual_pixels": 0.4,
    "p90_residual_pixels": 0.9,
    "geometry_completed_monotonic_seconds": 1.9,
    "pipeline_stage_seconds": {"sfmMapping": 0.9},
    "stage_seconds": {"geometry": 0.9, "end_to_end": 1.0},
}
pathlib.Path(arguments["--output"]).write_text(json.dumps(envelope))
with pathlib.Path("""
        + repr(str(invocations))
        + """).open("a") as handle:
    handle.write(str(project) + "\\n")
""",
        encoding="utf-8",
    )
    path.chmod(0o755)


class PhotoPermutationProducerTests(unittest.TestCase):
    def test_disconnected_accepted_content_graph_is_rejected(self) -> None:
        selected = [opaque(f"content-{index}") for index in range(4)]
        def edge(first: str, second: str) -> dict[str, str]:
            content_a, content_b = sorted((first, second))
            return {
                "content_a": content_a,
                "content_b": content_b,
                "edge_id": evidence._photo_pair_edge_id(content_a, content_b),
            }

        disconnected = [
            edge(selected[0], selected[1]),
            edge(selected[2], selected[3]),
        ]

        with self.assertRaisesRegex(
            producer.ProducerUnavailable,
            "accepted_pair_graph_disconnected",
        ):
            producer._require_connected_content_graph(selected, disconnected)

    def test_model_images_budget_scales_for_large_professional_folders(self) -> None:
        mib = 1024 * 1024
        self.assertEqual(producer._model_images_maximum_bytes(60), 128 * mib)
        self.assertEqual(producer._model_images_maximum_bytes(314), 314 * mib)
        self.assertEqual(producer._model_images_maximum_bytes(500), 500 * mib)
        self.assertEqual(producer._model_images_maximum_bytes(3_000), 512 * mib)
        for invalid in (True, 0, -1):
            with self.subTest(invalid=invalid):
                with self.assertRaisesRegex(
                    producer.ProducerUnavailable,
                    "selection_artifact_invalid",
                ):
                    producer._model_images_maximum_bytes(invalid)

    def test_dry_run_is_development_only_and_redacts_private_inputs(self) -> None:
        manifest = source_manifest(
            {"client/IMG_0001.JPG": b"a", "client/IMG_0002.JPG": b"b"}
        )
        plan = producer.dry_run_plan(
            manifest,
            request(2),
            mode="development",
            shuffle_count=2,
            source_kind="native_photos",
        )
        serialized = json.dumps(plan, sort_keys=True)
        self.assertEqual(plan["evidence_status"], "development_only")
        self.assertEqual(plan["variant_count"], 3)
        self.assertNotIn("IMG_0001", serialized)
        self.assertNotIn("client/", serialized)
        self.assertNotIn("sha256:", serialized)

    def test_schedule_is_canonical_then_sequential_and_release_seeds_are_fixed(
        self,
    ) -> None:
        development = producer.variant_schedule(mode="development", shuffle_count=2)
        self.assertEqual(
            [item.variant_id for item in development],
            ["canonical", "shuffle-01", "shuffle-02"],
        )
        release = producer.variant_schedule(mode="release", shuffle_count=19)
        self.assertEqual(len(release), 20)
        self.assertEqual(release[0].public_permutation, {"kind": "canonical"})
        self.assertEqual(
            [item.permutation_seed for item in release[1:]],
            [evidence.photo_permutation_release_seed(index) for index in range(1, 20)],
        )
        with self.assertRaisesRegex(producer.ProducerError, "exactly 19 shuffles"):
            producer.variant_schedule(mode="release", shuffle_count=2)
        self.assertEqual(
            producer.single_variant_spec(mode="release", index=8, seed=None),
            release[8],
        )
        with self.assertRaisesRegex(producer.ProducerError, "formal release seed"):
            producer.single_variant_spec(mode="release", index=8, seed=17)

        five_shuffle_development = producer.variant_schedule(
            mode="development", shuffle_count=5
        )
        self.assertEqual(
            [item.permutation_seed for item in five_shuffle_development[1:]],
            [
                3_840_444_645_453_124_342,
                3_047_114_146_883_787_958,
                7_114_752_268_117_194_879,
                5_704_163_804_122_661_365,
                3_378_918_378_078_704_989,
            ],
        )

    def test_materialization_clones_verifies_and_never_mutates_sources(self) -> None:
        files = {"a/IMG_0001.JPG": b"photo-a", "b/IMG_0002.PNG": b"photo-b"}
        manifest = source_manifest(files)
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            source = root / "source"
            source.mkdir()
            for name, contents in files.items():
                path = source / name
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_bytes(contents)
            runs = root / "runs"
            runs.mkdir(mode=0o700)
            run_root = runs / "owned-run"
            run_root.mkdir(mode=0o700)
            state = root / "state"
            owned = producer.register_owned_run(
                run_root,
                run_parent=runs,
                state_root=state,
                group_contract_sha256=digest_bytes(b"group"),
            )
            destination = run_root / "input"
            cloned: list[tuple[str, str]] = []

            def fake_clone(origin: Path, target: Path) -> None:
                cloned.append((origin.name, target.name))
                shutil.copyfile(origin, target, follow_symlinks=False)

            receipt = producer.materialize_variant(
                manifest,
                source_root=source,
                destination=destination,
                scale=2,
                permutation_index=1,
                permutation_seed=17,
                clone_file=fake_clone,
            )

            self.assertEqual(stat.S_IMODE(destination.stat().st_mode), 0o700)
            self.assertEqual(receipt["verified_file_count"], 2)
            self.assertEqual(len(cloned), 2)
            self.assertEqual(
                sorted(path.name for path in destination.iterdir()),
                ["photo-000001.jpg", "photo-000002.png"],
            )
            self.assertEqual((source / "a/IMG_0001.JPG").read_bytes(), b"photo-a")
            producer.remove_owned_run(owned)
            self.assertTrue(source.is_dir())
            self.assertFalse(run_root.exists())

    def test_digest_mismatch_is_typed_unavailable_and_cleans_partial_target(
        self,
    ) -> None:
        manifest = source_manifest({"IMG_0001.JPG": b"expected", "IMG_0002.JPG": b"b"})
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            source = root / "source"
            source.mkdir()
            (source / "IMG_0001.JPG").write_bytes(b"changed")
            (source / "IMG_0002.JPG").write_bytes(b"b")
            destination = root / "run" / "input"
            destination.parent.mkdir(mode=0o700)
            with self.assertRaisesRegex(
                producer.ProducerUnavailable, "source_digest_mismatch"
            ) as raised:
                producer.materialize_variant(
                    manifest,
                    source_root=source,
                    destination=destination,
                    scale=2,
                    permutation_index=1,
                    permutation_seed=17,
                    clone_file=lambda origin, target: shutil.copyfile(origin, target),
                )
            self.assertEqual(raised.exception.reason, "source_digest_mismatch")
            self.assertFalse(destination.exists())
            self.assertTrue(source.exists())

    def test_real_apfs_clone_materialization_uses_single_link_targets(self) -> None:
        files = {"IMG_0001.JPG": b"photo-a", "IMG_0002.JPG": b"photo-b"}
        manifest = source_manifest(files)
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            source = root / "source"
            source.mkdir()
            for name, contents in files.items():
                (source / name).write_bytes(contents)
            run_root = root / "run"
            run_root.mkdir(mode=0o700)
            receipt = producer.materialize_variant(
                manifest,
                source_root=source,
                destination=run_root / "input",
                scale=2,
                permutation_index=1,
                permutation_seed=17,
            )
            self.assertEqual(receipt["materialization"], "apfs_clone")
            self.assertTrue(
                all(
                    path.stat().st_nlink == 1 for path in (run_root / "input").iterdir()
                )
            )

    def test_cleanup_requires_an_owned_direct_child(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            runs = root / "runs"
            runs.mkdir()
            run_root = runs / "owned"
            run_root.mkdir()
            owned = producer.register_owned_run(
                run_root,
                run_parent=runs,
                state_root=root / "state",
                group_contract_sha256=digest_bytes(b"group"),
            )
            original = runs / "original-owned"
            run_root.rename(original)
            run_root.mkdir()
            (run_root / "user-file").write_bytes(b"do not delete")
            with self.assertRaisesRegex(producer.ProducerError, "identity changed"):
                producer.remove_owned_run(owned)
            self.assertEqual((run_root / "user-file").read_bytes(), b"do not delete")

    def test_failed_cleanup_preserves_the_ownership_marker_for_recovery(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            runs = root / "runs"
            runs.mkdir()
            run_root = runs / "owned"
            run_root.mkdir()
            (run_root / "artifact.db").write_bytes(b"partial")
            owned = producer.register_owned_run(
                run_root,
                run_parent=runs,
                state_root=root / "state",
                group_contract_sha256=digest_bytes(b"group"),
            )
            real_unlink = os.unlink

            def interrupted_unlink(
                path: object, *args: object, **kwargs: object
            ) -> None:
                if path == "artifact.db":
                    raise OSError("synthetic cleanup interruption")
                real_unlink(path, *args, **kwargs)

            with mock.patch.object(os, "unlink", side_effect=interrupted_unlink):
                with self.assertRaisesRegex(
                    producer.ProducerError, "owned run entry changed during cleanup"
                ):
                    producer.remove_owned_run(owned)

            self.assertTrue((run_root / producer.OWNED_MARKER).is_file())
            self.assertTrue(owned.ownership_receipt.is_file())

            producer.recover_stale_owned_runs(
                state_root=root / "state",
                run_parent=runs,
                group_contract_sha256=digest_bytes(b"group"),
            )
            self.assertFalse(run_root.exists())
            self.assertFalse(owned.ownership_receipt.exists())

    def test_cleanup_tolerates_descendant_that_disappears_during_unlink(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            runs = root / "runs"
            runs.mkdir()
            run_root = runs / "owned"
            run_root.mkdir()
            (run_root / "geometry.db-wal").write_bytes(b"transient")
            owned = producer.register_owned_run(
                run_root,
                run_parent=runs,
                state_root=root / "state",
                group_contract_sha256=digest_bytes(b"group"),
            )
            real_unlink = os.unlink

            def disappearing_unlink(
                path: object, *args: object, **kwargs: object
            ) -> None:
                real_unlink(path, *args, **kwargs)
                if path == "geometry.db-wal":
                    raise FileNotFoundError("synthetic SQLite sidecar teardown")

            with mock.patch.object(os, "unlink", side_effect=disappearing_unlink):
                producer.remove_owned_run(owned)

            self.assertFalse(run_root.exists())
            self.assertFalse(owned.ownership_receipt.exists())

    def test_next_start_recovers_a_stale_cryptographically_owned_run(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            runs = root / "runs"
            runs.mkdir()
            state = root / "state"
            run_root = runs / "run-interrupted"
            (run_root / "nested").mkdir(parents=True)
            (run_root / "nested/partial.db").write_bytes(b"partial")
            contract_digest = digest_bytes(b"group")
            owned = producer.register_owned_run(
                run_root,
                run_parent=runs,
                state_root=state,
                group_contract_sha256=contract_digest,
            )

            producer.recover_stale_owned_runs(
                state_root=state,
                run_parent=runs,
                group_contract_sha256=contract_digest,
            )

            self.assertFalse(run_root.exists())
            self.assertFalse(owned.ownership_receipt.exists())

    def test_private_receipt_is_atomic_mode_0600(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            receipt = root / "receipt.json"
            producer.write_private_json(
                receipt, {"schema_version": 1, "status": "complete"}
            )
            self.assertEqual(stat.S_IMODE(receipt.stat().st_mode), 0o600)
            self.assertEqual(
                json.loads(receipt.read_text()),
                {"schema_version": 1, "status": "complete"},
            )

    def test_new_private_receipt_uses_atomic_no_replace_publication(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            path = root / "canonical.json"
            first = {"schema_version": 1, "value": "first"}
            replacement = {"schema_version": 1, "value": "replacement"}

            with mock.patch.object(
                producer.os,
                "link",
                side_effect=AssertionError("hard-link publication is not atomic"),
            ):
                self.assertTrue(producer._write_new_private_json(path, first))
                self.assertFalse(
                    producer._write_new_private_json(path, replacement)
                )

            self.assertEqual(json.loads(path.read_text(encoding="utf-8")), first)
            self.assertEqual(path.stat().st_nlink, 1)
            self.assertEqual(stat.S_IMODE(path.stat().st_mode), 0o600)
            self.assertEqual(list(root.glob(".canonical.json.*.tmp")), [])

    def test_resume_rejects_canonical_pose_tampering_that_would_hide_deviation(
        self,
    ) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            path = root / "canonical.json"
            key = b"private-observation-authentication-key"
            contract_digest = digest_bytes(b"group-contract")
            canonical = private_observation()
            candidate = json.loads(json.dumps(canonical))
            content_id = candidate["registered_content_ids"][0]
            candidate["poses"][content_id]["center"][0] = 0.25
            self.assertGreater(
                producer._pose_deviation(canonical, candidate)[0],
                0.0,
            )
            producer.write_private_json(
                path,
                private_observation_receipt(
                    canonical,
                    key=key,
                    group_contract_sha256=contract_digest,
                    variant_id="canonical",
                ),
            )
            self.assertEqual(
                producer._load_private_observation(
                    path,
                    group_contract_sha256=contract_digest,
                    variant_id="canonical",
                    authentication_key=key,
                ),
                canonical,
            )

            tampered = json.loads(path.read_text(encoding="utf-8"))
            tampered["observation"]["poses"] = candidate["poses"]
            hidden_center_deviation, hidden_rotation_deviation = (
                producer._pose_deviation(tampered["observation"], candidate)
            )
            self.assertAlmostEqual(hidden_center_deviation, 0.0, places=12)
            self.assertAlmostEqual(hidden_rotation_deviation, 0.0, places=12)
            producer.write_private_json(path, tampered)

            with self.assertRaisesRegex(
                producer.ProducerUnavailable,
                "canonical_observation_unavailable",
            ):
                producer._load_private_observation(
                    path,
                    group_contract_sha256=contract_digest,
                    variant_id="canonical",
                    authentication_key=key,
                )

    def test_canonical_observation_is_immutable_within_one_group(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "canonical.json"
            key = b"private-observation-authentication-key"
            contract_digest = digest_bytes(b"group-contract")
            first = private_observation()
            replacement = json.loads(json.dumps(first))
            content_id = replacement["registered_content_ids"][0]
            replacement["poses"][content_id]["center"][0] = 0.25

            stored, first_attestation = producer._publish_canonical_observation(
                path,
                first,
                group_contract_sha256=contract_digest,
                authentication_key=key,
            )
            self.assertEqual(stored, first)
            self.assertRegex(first_attestation, evidence.OPAQUE_SHA256_PATTERN)

            with self.assertRaisesRegex(
                producer.ProducerUnavailable,
                "canonical_observation_changed",
            ):
                producer._publish_canonical_observation(
                    path,
                    replacement,
                    group_contract_sha256=contract_digest,
                    authentication_key=key,
                )

            replayed, replayed_attestation = (
                producer._publish_canonical_observation(
                    path,
                    first,
                    group_contract_sha256=contract_digest,
                    authentication_key=key,
                )
            )
            self.assertEqual(replayed, first)
            self.assertEqual(replayed_attestation, first_attestation)

    def test_authenticated_private_observation_still_requires_proper_poses(
        self,
    ) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            path = root / "canonical.json"
            key = b"private-observation-authentication-key"
            contract_digest = digest_bytes(b"group-contract")
            observation = private_observation()
            content_id = observation["registered_content_ids"][0]
            observation["poses"][content_id]["rotation_cw"] = [
                [1.0, 0.0, 0.0],
                [0.0, 1.0, 0.0],
                [0.0, 0.0, -1.0],
            ]
            producer.write_private_json(
                path,
                private_observation_receipt(
                    observation,
                    key=key,
                    group_contract_sha256=contract_digest,
                    variant_id="canonical",
                ),
            )

            with self.assertRaisesRegex(
                producer.ProducerUnavailable,
                "canonical_observation_unavailable",
            ):
                producer._load_private_observation(
                    path,
                    group_contract_sha256=contract_digest,
                    variant_id="canonical",
                    authentication_key=key,
                )

    def test_authenticated_private_observation_rejects_wrong_json_types_fail_closed(
        self,
    ) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            key = b"private-observation-authentication-key"
            contract_digest = digest_bytes(b"group-contract")
            corruptions = (
                ("schema_version", {"schema_version": True}),
                ("content_id", {"selected_content_ids": [opaque("content"), 7]}),
                ("pairing_policy", {"pairing_policy": ["unordered_exhaustive"]}),
                ("huge_residual", {"residual_median_pixels": 10**400}),
            )
            for label, replacement in corruptions:
                with self.subTest(label=label):
                    path = root / f"{label}.json"
                    observation = {**private_observation(), **replacement}
                    producer.write_private_json(
                        path,
                        private_observation_receipt(
                            observation,
                            key=key,
                            group_contract_sha256=contract_digest,
                            variant_id="canonical",
                        ),
                    )

                    with self.assertRaisesRegex(
                        producer.ProducerUnavailable,
                        "canonical_observation_unavailable",
                    ):
                        producer._load_private_observation(
                            path,
                            group_contract_sha256=contract_digest,
                            variant_id="canonical",
                            authentication_key=key,
                        )

    def test_private_observation_receipt_rejects_noncanonical_envelopes(
        self,
    ) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            key = b"private-observation-authentication-key"
            contract_digest = digest_bytes(b"group-contract")
            observation = private_observation()
            valid = private_observation_receipt(
                observation,
                key=key,
                group_contract_sha256=contract_digest,
                variant_id="canonical",
            )
            authenticated_payload = {
                "schema_version": 1,
                "group_contract_sha256": contract_digest,
                "variant_id": "canonical",
                "observation": observation,
            }
            missing_observation_field = dict(observation)
            missing_observation_field.pop("poses")
            extra_observation_field = {**observation, "legacy": True}
            cases = {
                "legacy": observation,
                "missing_field": {
                    field: value
                    for field, value in valid.items()
                    if field != "authenticator"
                },
                "extra_field": {**valid, "legacy": True},
                "wrong_schema_type": {**valid, "schema_version": True},
                "wrong_tag_type": {**valid, "authenticator": 7},
                "malformed_tag": {
                    **valid,
                    "authenticator": "opaque-sha256:not-a-valid-tag",
                },
                "non_ascii_tag": {
                    **valid,
                    "authenticator": "opaque-sha256:\u00e9",
                },
                "wrong_domain": {
                    **valid,
                    "authenticator": producer._opaque_hmac(
                        key,
                        b"easysplat-photo-private-observation-wrong-domain",
                        evidence.canonical_json_bytes(authenticated_payload),
                    ),
                },
                "missing_observation_field": private_observation_receipt(
                    missing_observation_field,
                    key=key,
                    group_contract_sha256=contract_digest,
                    variant_id="canonical",
                ),
                "extra_observation_field": private_observation_receipt(
                    extra_observation_field,
                    key=key,
                    group_contract_sha256=contract_digest,
                    variant_id="canonical",
                ),
            }
            for label, receipt in cases.items():
                with self.subTest(label=label):
                    path = root / f"{label}.json"
                    producer.write_private_json(path, receipt)
                    with self.assertRaisesRegex(
                        producer.ProducerUnavailable,
                        "canonical_observation_unavailable",
                    ):
                        producer._load_private_observation(
                            path,
                            group_contract_sha256=contract_digest,
                            variant_id="canonical",
                            authentication_key=key,
                        )

    def test_private_observation_receipt_authenticates_every_observation_field(
        self,
    ) -> None:
        def mutated(value: object) -> object:
            if type(value) is bool:
                return not value
            if type(value) is int:
                return value + 1
            if isinstance(value, float):
                return value + 0.125
            if isinstance(value, str):
                return value[:-1] + ("0" if value[-1] != "0" else "1")
            if isinstance(value, list):
                return [*value, None]
            if isinstance(value, dict):
                return {**value, "__tampered": True}
            raise AssertionError(f"unhandled fixture type: {type(value).__name__}")

        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            key = b"private-observation-authentication-key"
            contract_digest = digest_bytes(b"group-contract")
            observation = private_observation()
            valid = private_observation_receipt(
                observation,
                key=key,
                group_contract_sha256=contract_digest,
                variant_id="canonical",
            )
            for field in sorted(producer.PRIVATE_OBSERVATION_FIELDS):
                with self.subTest(field=field):
                    path = root / f"{field}.json"
                    tampered = json.loads(json.dumps(valid))
                    tampered["observation"][field] = mutated(
                        tampered["observation"][field]
                    )
                    producer.write_private_json(path, tampered)
                    with self.assertRaisesRegex(
                        producer.ProducerUnavailable,
                        "canonical_observation_unavailable",
                    ):
                        producer._load_private_observation(
                            path,
                            group_contract_sha256=contract_digest,
                            variant_id="canonical",
                            authentication_key=key,
                        )

    def test_private_observation_receipt_rejects_identity_and_key_replay(
        self,
    ) -> None:
        base_contract = private_group_contract()
        base_digest = base_contract["contract_sha256"]
        assert isinstance(base_digest, str)
        changed_request = request()
        changed_configuration = dict(
            changed_request["candidate_run_configuration"]
        )
        changed_configuration["run_seed"] = 43
        changed_request["candidate_run_configuration"] = changed_configuration
        changed_contracts = {
            "group": private_group_contract(group_id="different-group"),
            "source": private_group_contract(
                manifest=source_manifest(
                    {
                        "IMG_1.JPG": b"different",
                        "IMG_2.JPG": b"b",
                        "IMG_3.JPG": b"c",
                    }
                )
            ),
            "request": private_group_contract(request_value=changed_request),
            "adapter": private_group_contract(adapter_label=b"different-adapter"),
            "toolchain": private_group_contract(
                toolchain_label=b"different-toolchain"
            ),
            "runtime": private_group_contract(producer_label=b"different-producer"),
        }
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "canonical.json"
            key = b"private-observation-authentication-key"
            producer.write_private_json(
                path,
                private_observation_receipt(
                    private_observation(),
                    key=key,
                    group_contract_sha256=base_digest,
                    variant_id="canonical",
                ),
            )
            replays = {
                **{
                    label: {
                        "group_contract_sha256": contract["contract_sha256"],
                        "variant_id": "canonical",
                        "authentication_key": key,
                    }
                    for label, contract in changed_contracts.items()
                },
                "variant": {
                    "group_contract_sha256": base_digest,
                    "variant_id": "shuffle-01",
                    "authentication_key": key,
                },
                "key": {
                    "group_contract_sha256": base_digest,
                    "variant_id": "canonical",
                    "authentication_key": (
                        b"different-observation-authentication-key"
                    ),
                },
            }
            for label, replay in replays.items():
                with self.subTest(label=label):
                    with self.assertRaisesRegex(
                        producer.ProducerUnavailable,
                        "canonical_observation_unavailable",
                    ):
                        producer._load_private_observation(path, **replay)

    def test_private_observation_receipt_requires_a_private_plain_single_link(
        self,
    ) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            key = b"private-observation-authentication-key"
            contract_digest = digest_bytes(b"group-contract")
            receipt = private_observation_receipt(
                private_observation(),
                key=key,
                group_contract_sha256=contract_digest,
                variant_id="canonical",
            )

            public_mode = root / "public-mode.json"
            producer.write_private_json(public_mode, receipt)
            public_mode.chmod(0o644)

            linked = root / "linked.json"
            producer.write_private_json(linked, receipt)
            hard_link = root / "linked-copy.json"
            os.link(linked, hard_link)

            target = root / "target.json"
            producer.write_private_json(target, receipt)
            symbolic_link = root / "symbolic-link.json"
            symbolic_link.symlink_to(target)

            for label, path in {
                "mode": public_mode,
                "hard_link": linked,
                "symbolic_link": symbolic_link,
            }.items():
                with self.subTest(label=label):
                    with self.assertRaisesRegex(
                        producer.ProducerUnavailable,
                        "canonical_observation_unavailable",
                    ):
                        producer._load_private_observation(
                            path,
                            group_contract_sha256=contract_digest,
                            variant_id="canonical",
                            authentication_key=key,
                        )

    def test_private_observation_parser_rejects_excessive_nesting_fail_closed(
        self,
    ) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "canonical.json"
            path.write_bytes(b"[" * 2_000 + b"0" + b"]" * 2_000)
            path.chmod(0o600)

            with self.assertRaisesRegex(
                producer.ProducerUnavailable,
                "canonical_observation_unavailable",
            ):
                producer._load_private_observation(
                    path,
                    group_contract_sha256=digest_bytes(b"group-contract"),
                    variant_id="canonical",
                    authentication_key=b"private-observation-authentication-key",
                )

    def test_group_resume_skips_completed_and_runs_sequentially(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            state = Path(temporary) / "state"
            calls: list[str] = []

            def first_executor(spec: producer.VariantSpec) -> dict[str, object]:
                calls.append(spec.variant_id)
                if spec.variant_id == "shuffle-01":
                    raise producer.ProducerUnavailable("synthetic_interruption")
                return public_variant(spec)

            result = producer.orchestrate_group(
                request=request(),
                state_root=state,
                mode="development",
                shuffle_count=2,
                source_kind="native_photos",
                group_contract=private_group_contract(),
                receipt_authentication_key=b"k" * 32,
                execute_variant=first_executor,
            )
            self.assertEqual(result["status"], "producer_evidence_unavailable")
            self.assertEqual(calls, ["canonical", "shuffle-01"])

            calls.clear()
            group = producer.orchestrate_group(
                request=request(),
                state_root=state,
                mode="development",
                shuffle_count=2,
                source_kind="native_photos",
                group_contract=private_group_contract(),
                receipt_authentication_key=b"k" * 32,
                execute_variant=lambda spec: (
                    calls.append(spec.variant_id) or public_variant(spec)
                ),
            )
            self.assertEqual(calls, ["shuffle-01", "shuffle-02"])
            self.assertEqual(group["expected_variant_count"], 3)
            self.assertEqual(
                [item["variant_id"] for item in group["variants"]],
                ["canonical", "shuffle-01", "shuffle-02"],
            )

    def test_group_cache_rejects_extra_fields_wrong_schema_and_wrong_variant_slot(
        self,
    ) -> None:
        corruptions = (
            {"extra": True},
            {"schema_version": 99},
            {
                "public_variant": public_variant(
                    producer.VariantSpec("shuffle-01", 1, 17)
                )
            },
        )
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            for index, corruption in enumerate(corruptions):
                state = root / f"state-{index}"
                contract = private_group_contract()
                contract_digest = producer.ensure_group_contract(state, contract)
                receipts = state / "receipts"
                receipts.mkdir()
                receipt = {
                    "schema_version": 1,
                    "status": "complete",
                    "group_contract_sha256": contract_digest,
                    "public_variant": public_variant(
                        producer.VariantSpec("canonical", 0, 0)
                    ),
                    **corruption,
                }
                producer.write_private_json(receipts / "canonical.json", receipt)
                calls: list[str] = []
                producer.orchestrate_group(
                    request=request(),
                    state_root=state,
                    mode="development",
                    shuffle_count=2,
                    source_kind="native_photos",
                    group_contract=contract,
                    receipt_authentication_key=b"k" * 32,
                    execute_variant=lambda spec: (
                        calls.append(spec.variant_id) or public_variant(spec)
                    ),
                )
                self.assertEqual(calls, ["canonical", "shuffle-01", "shuffle-02"])

    def test_group_cache_authenticator_rejects_metric_tampering(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            state = Path(temporary) / "state"
            contract = private_group_contract()
            key = b"cache-authentication-key".ljust(32, b"-")
            producer.orchestrate_group(
                request=request(),
                state_root=state,
                mode="development",
                shuffle_count=2,
                source_kind="native_photos",
                group_contract=contract,
                receipt_authentication_key=key,
                execute_variant=public_variant,
            )
            path = state / "receipts/canonical.json"
            receipt = json.loads(path.read_text())
            receipt["public_variant"]["residual_median_pixels"] = 0.501
            receipt["public_variant"]["residual_p90_pixels"] = 1.001
            producer.write_private_json(path, receipt)
            calls: list[str] = []

            producer.orchestrate_group(
                request=request(),
                state_root=state,
                mode="development",
                shuffle_count=2,
                source_kind="native_photos",
                group_contract=contract,
                receipt_authentication_key=key,
                execute_variant=lambda spec: (
                    calls.append(spec.variant_id) or public_variant(spec)
                ),
            )

            self.assertEqual(calls, ["canonical"])

    def test_slot_receipt_mutation_before_final_sealing_aborts_publication(
        self,
    ) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            state = Path(temporary) / "state"
            key = b"final-slot-authentication-key".ljust(32, b"-")
            contract = private_group_contract()
            original = producer._load_completed_variant_receipt
            calls = 0

            def mutate_before_sealing(
                path: Path,
                **kwargs: object,
            ) -> tuple[dict[str, object], str] | None:
                nonlocal calls
                calls += 1
                if calls == 4:
                    value = json.loads(path.read_text(encoding="utf-8"))
                    value["public_variant"]["residual_median_pixels"] = 0.75
                    producer.write_private_json(path, value)
                return original(path, **kwargs)

            with (
                mock.patch.object(
                    producer,
                    "_load_completed_variant_receipt",
                    side_effect=mutate_before_sealing,
                ),
                self.assertRaisesRegex(
                    producer.ProducerError,
                    "changed before group sealing",
                ),
            ):
                producer.orchestrate_group(
                    request=request(),
                    state_root=state,
                    mode="development",
                    shuffle_count=2,
                    source_kind="native_photos",
                    group_contract=contract,
                    receipt_authentication_key=key,
                    execute_variant=public_variant,
                )

            self.assertFalse((state / "group.json").exists())
            self.assertFalse((state / "execution-receipt.json").exists())

    def test_public_unavailable_record_cannot_contain_paths_or_raw_digests(
        self,
    ) -> None:
        record = producer.unavailable_public_record(
            "shuffle-01", "pose_alignment_unavailable"
        )
        producer.validate_public_record(record)
        self.assertEqual(record["status"], "producer_evidence_unavailable")
        leaked = dict(record, source_path="/Users/client/IMG_0001.CR3")
        with self.assertRaisesRegex(producer.ProducerError, "public record"):
            producer.validate_public_record(leaked)

    def test_group_contract_rejects_every_cache_identity_change(self) -> None:
        base = private_group_contract()
        candidates = {
            "corpus": private_group_contract(
                manifest=source_manifest(
                    {"IMG_1.JPG": b"different", "IMG_2.JPG": b"b", "IMG_3.JPG": b"c"}
                )
            ),
            "group": private_group_contract(group_id="different-group"),
            "request": private_group_contract(
                request_value={
                    **request(),
                    "candidate_run_configuration": {
                        **request()["candidate_run_configuration"],
                        "run_seed": 43,
                    },
                }
            ),
            "source_kind": private_group_contract(
                source_kind="single_video_derived_stills"
            ),
            "adapter": private_group_contract(adapter_label=b"changed-adapter"),
            "toolchain": private_group_contract(toolchain_label=b"changed-toolchain"),
            "producer": private_group_contract(producer_label=b"changed-producer"),
            "source_authorization": private_group_contract(
                source_authorization_label=b"changed-source-authorization"
            ),
        }
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            for label, candidate in candidates.items():
                with self.subTest(label=label):
                    state = root / label
                    state.mkdir(mode=0o700)
                    producer.ensure_group_contract(state, base)
                    producer.ensure_group_contract(state, base)
                    with self.assertRaisesRegex(
                        producer.ProducerError, "group contract mismatch"
                    ):
                        producer.ensure_group_contract(state, candidate)

    def test_formal_group_contract_requires_external_source_authorization(self) -> None:
        manifest = source_manifest(
            {"IMG_1.JPG": b"a", "IMG_2.JPG": b"b", "IMG_3.JPG": b"c"}
        )
        request_value = request()
        request_value["binding"] = {
            **request_value["binding"],
            "git_commit": "1" * 40,
            "lane": evidence.LANE_REFERENCE,
            "profile": "release",
        }
        arguments = {
            "manifest": manifest,
            "request": request_value,
            "request_file_sha256": digest_bytes(b"request-file"),
            "group_id": "formal-source-authorization",
            "source_kind": "native_photos",
            "mode": "release",
            "shuffle_count": 19,
            "adapter_sha256": digest_bytes(b"adapter"),
            "toolchain_closure_sha256": digest_bytes(b"toolchain"),
            "producer_implementation_sha256": digest_bytes(b"producer"),
        }
        with self.assertRaisesRegex(producer.ProducerError, "source authorization"):
            producer.build_group_contract(**arguments)

        authorization = protected_source_authorization(
            manifest,
            request_value,
            adapter_sha256=arguments["adapter_sha256"],
            toolchain_closure_sha256=arguments["toolchain_closure_sha256"],
        )
        authorization_digest = evidence.sha256_bytes(
            evidence.canonical_json_bytes(authorization) + b"\n"
        )
        contract = producer.build_group_contract(
            **arguments,
            source_authorization=authorization,
        )
        self.assertEqual(
            contract["source_authorization_sha256"],
            authorization_digest,
        )

    def test_same_size_source_overwrite_after_import_cannot_relabel_loaded_code(
        self,
    ) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            package = root / "scripts/benchmark"
            package.mkdir(parents=True)
            (root / "scripts/__init__.py").write_text("")
            (package / "__init__.py").write_text("")
            shutil.copyfile(
                Path(producer.__file__), package / "photo_permutation_producer.py"
            )
            shutil.copyfile(Path(evidence.__file__), package / "evidence_protocol.py")
            completed = subprocess.run(
                [
                    "python3",
                    "-c",
                    """
from pathlib import Path
from scripts.benchmark import photo_permutation_producer as producer
path = Path(producer.__file__)
data = path.read_bytes()
path.write_bytes(data[:-1] + (b" " if data[-1:] != b" " else b"\\n"))
try:
    producer._producer_implementation_closure()
except producer.ProducerUnavailable as error:
    print(error.reason)
else:
    raise SystemExit("changed source was accepted")
""",
                ],
                cwd=root,
                env={"PATH": os.environ["PATH"], "PYTHONPATH": str(root)},
                check=False,
                text=True,
                capture_output=True,
            )
            self.assertEqual(completed.returncode, 0, completed.stderr)
            self.assertEqual(
                completed.stdout.strip(),
                "producer_implementation_changed_after_import",
            )

    def test_timestamp_valid_stale_bytecode_cannot_run_as_current_protocol(
        self,
    ) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            package = root / "scripts/benchmark"
            package.mkdir(parents=True)
            (root / "scripts/__init__.py").write_text("")
            (package / "__init__.py").write_text("")
            shutil.copyfile(
                Path(producer.__file__), package / "photo_permutation_producer.py"
            )
            shutil.copyfile(Path(evidence.__file__), package / "evidence_protocol.py")
            completed = subprocess.run(
                [
                    "python3",
                    "-c",
                    """
import importlib
import os
import sys
from pathlib import Path

module = importlib.import_module("scripts.benchmark.evidence_protocol")
path = Path(module.__file__)
metadata = path.stat()
source = path.read_bytes()
current = module.PROTOCOL_VERSION
replacement = current + 1
changed = source.replace(
    f"PROTOCOL_VERSION = {current}".encode(),
    f"PROTOCOL_VERSION = {replacement}".encode(),
    1,
)
assert len(changed) == len(source) and changed != source
path.write_bytes(changed)
os.utime(path, ns=(metadata.st_atime_ns, metadata.st_mtime_ns))
del sys.modules["scripts.benchmark.evidence_protocol"]
delattr(sys.modules["scripts.benchmark"], "evidence_protocol")
producer = importlib.import_module("scripts.benchmark.photo_permutation_producer")
print(producer.evidence.PROTOCOL_VERSION)
""",
                ],
                cwd=root,
                env={"PATH": os.environ["PATH"], "PYTHONPATH": str(root)},
                check=False,
                text=True,
                capture_output=True,
            )
            self.assertEqual(completed.returncode, 0, completed.stderr)
            self.assertEqual(
                completed.stdout.strip(),
                str(evidence.PROTOCOL_VERSION + 1),
            )

    def test_nonempty_state_without_contract_is_never_adopted(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            state = Path(temporary) / "state"
            state.mkdir(mode=0o700)
            (state / "receipts").mkdir()
            with self.assertRaisesRegex(
                producer.ProducerError, "no immutable group contract"
            ):
                producer.ensure_group_contract(state, private_group_contract())

    def test_runtime_contract_binds_actual_source_request_adapter_and_toolchain_bytes(
        self,
    ) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            source = root / "source"
            source.mkdir()
            files = {"IMG_1.JPG": b"a", "IMG_2.JPG": b"b", "IMG_3.JPG": b"c"}
            for name, contents in files.items():
                (source / name).write_bytes(contents)
            manifest = source_manifest(files)
            request_value = request()
            request_path = root / "request.json"
            request_path.write_text(json.dumps(request_value))
            adapter = root / "adapter"
            adapter.write_bytes(b"adapter-v1")
            adapter.chmod(0o755)
            toolchain = root / "toolchain"
            (toolchain / "bin").mkdir(parents=True)
            (toolchain / ".easysplat_toolchain_state.json").write_bytes(b"receipt-v1")
            (toolchain / "bin/colmap").write_bytes(b"colmap-v1")

            def contract(
                current_manifest: dict[str, object] = manifest,
            ) -> dict[str, object]:
                return producer.runtime_group_contract(
                    manifest=current_manifest,
                    source_root=source,
                    request=request_value,
                    request_path=request_path,
                    group_id="private-fixture-group",
                    source_kind="native_photos",
                    mode="development",
                    shuffle_count=2,
                    adapter=adapter,
                    toolchain_root=toolchain,
                )

            base = contract()
            state = root / "state"
            state.mkdir(mode=0o700)
            producer.ensure_group_contract(state, base)

            request_path.write_text(json.dumps(request_value, indent=2))
            with self.assertRaisesRegex(
                producer.ProducerError, "group contract mismatch"
            ):
                producer.ensure_group_contract(state, contract())
            request_path.write_text(json.dumps(request_value))

            adapter.write_bytes(b"adapter-v2")
            adapter.chmod(0o755)
            with self.assertRaisesRegex(
                producer.ProducerError, "group contract mismatch"
            ):
                producer.ensure_group_contract(state, contract())
            adapter.write_bytes(b"adapter-v1")
            adapter.chmod(0o755)

            (toolchain / ".easysplat_toolchain_state.json").write_bytes(b"receipt-v2")
            with self.assertRaisesRegex(
                producer.ProducerError, "group contract mismatch"
            ):
                producer.ensure_group_contract(state, contract())
            (toolchain / ".easysplat_toolchain_state.json").write_bytes(b"receipt-v1")

            (source / "IMG_1.JPG").write_bytes(b"different")
            with self.assertRaisesRegex(
                producer.ProducerUnavailable, "source_digest_mismatch"
            ):
                contract()
            changed_manifest = source_manifest(
                {"IMG_1.JPG": b"different", "IMG_2.JPG": b"b", "IMG_3.JPG": b"c"}
            )
            with self.assertRaisesRegex(
                producer.ProducerError, "group contract mismatch"
            ):
                producer.ensure_group_contract(state, contract(changed_manifest))

    def test_formal_group_hashes_each_source_once_per_materialization_not_per_contract_check(
        self,
    ) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            source = root / "source"
            source.mkdir()
            files = {
                "IMG_1.JPG": b"source-one",
                "IMG_2.JPG": b"source-two",
                "IMG_3.JPG": b"source-three",
            }
            for name, contents in files.items():
                (source / name).write_bytes(contents)
            source_identities = {
                ((source / name).stat().st_dev, (source / name).stat().st_ino)
                for name in files
            }
            request_value = request()
            request_value["binding"] = {
                **request_value["binding"],
                "git_commit": "1" * 40,
                "lane": evidence.LANE_REFERENCE,
                "profile": "release",
            }
            request_path = root / "request.json"
            request_path.write_text(json.dumps(request_value))
            adapter = root / "adapter"
            adapter.write_bytes(b"adapter")
            adapter.chmod(0o755)
            toolchain = root / "toolchain"
            toolchain.mkdir()
            (toolchain / ".easysplat_toolchain_state.json").write_bytes(b"receipt")
            runs = root / "runs"
            runs.mkdir(mode=0o700)
            ownership_state = root / "ownership-state"
            source_hash_calls = 0
            source_hash_bytes = 0
            original_hash = producer._hash_open_descriptor

            def counted_hash(descriptor: int, **kwargs: object):
                nonlocal source_hash_calls, source_hash_bytes
                metadata = os.fstat(descriptor)
                result = original_hash(descriptor, **kwargs)
                if (metadata.st_dev, metadata.st_ino) in source_identities:
                    source_hash_calls += 1
                    source_hash_bytes += metadata.st_size
                return result

            with mock.patch.object(producer, "_hash_open_descriptor", counted_hash):
                manifest = source_manifest(files)
                authorization = protected_source_authorization(
                    manifest,
                    request_value,
                    adapter_sha256=producer._sha256_file(adapter)[0],
                    toolchain_closure_sha256=producer._capture_toolchain_closure(
                        toolchain
                    )[0],
                )
                context = producer.capture_runtime_group_context(
                    manifest=manifest,
                    source_root=source,
                    request=request_value,
                    request_path=request_path,
                    group_id="formal-private-fixture",
                    source_kind="native_photos",
                    mode="release",
                    shuffle_count=19,
                    adapter=adapter,
                    toolchain_root=toolchain,
                    source_authorization=authorization,
                )
                for spec in producer.variant_schedule(mode="release", shuffle_count=19):
                    run_root = runs / spec.variant_id
                    run_root.mkdir(mode=0o700)
                    owned = producer.register_owned_run(
                        run_root,
                        run_parent=runs,
                        state_root=ownership_state,
                        group_contract_sha256=digest_bytes(b"formal-group"),
                    )
                    producer.materialize_variant(
                        source_manifest(files),
                        source_root=source,
                        destination=run_root / "input",
                        scale=3,
                        permutation_index=spec.permutation_index,
                        permutation_seed=spec.permutation_seed,
                        pinned_sources=dict(context.source_files),
                    )
                    producer.revalidate_runtime_group_context(context)
                    producer.remove_owned_run(owned)

            expected_passes = 1 + 20
            self.assertEqual(source_hash_calls, len(files) * expected_passes)
            self.assertEqual(
                source_hash_bytes,
                sum(len(contents) for contents in files.values()) * expected_passes,
            )

    def test_derived_stills_are_forced_to_order_only_claim(self) -> None:
        plan = producer.dry_run_plan(
            source_manifest(
                {"IMG_1.JPG": b"a", "IMG_2.JPG": b"b"},
                source_kind="single_video_derived_stills",
                video_origin_count=1,
                photo_origin_count=0,
            ),
            request(2),
            mode="development",
            shuffle_count=2,
            source_kind="single_video_derived_stills",
        )
        self.assertEqual(plan["closure_claims"], ["order_mechanics"])

    def test_calibration_dataset_inventory_binds_exact_crop_outputs(self) -> None:
        files = {
            "1520530308199447626.png": b"cropped-frame-one",
            "1520530309399588486.png": b"cropped-frame-two",
        }
        crop_manifest = calibration_crop_manifest(files)
        constants = calibration_manifest_constants(crop_manifest)
        crop_manifest_sha256 = constants["TUMVI_SUPPORTED_CROP_MANIFEST_SHA256"]
        assert isinstance(crop_manifest_sha256, str)

        with (
            tempfile.TemporaryDirectory() as temporary,
            mock.patch.multiple(producer, **constants),
        ):
            source = Path(temporary) / "supported-crop"
            source.mkdir()
            for name, contents in files.items():
                (source / name).write_bytes(contents)

            manifest = producer.inventory_source_manifest(
                source,
                corpus_id="tumvi-supported-fisheye-control",
                source_kind="calibration_dataset_derived_stills",
                origin_manifest=crop_manifest,
                origin_manifest_file_sha256=crop_manifest_sha256,
            )

            self.assertEqual(
                manifest["provenance"],
                {
                    "source_kind": "calibration_dataset_derived_stills",
                    "video_origin_count": 0,
                    "photo_origin_count": 0,
                    "origin_closure_sha256": crop_manifest_sha256,
                },
            )
            self.assertEqual(
                manifest["entries"],
                [
                    {
                        "relative_path": name,
                        "source_sha256": digest_bytes(contents),
                    }
                    for name, contents in sorted(files.items())
                ],
            )
            plan = producer.dry_run_plan(
                manifest,
                request(2),
                mode="development",
                shuffle_count=5,
                source_kind="calibration_dataset_derived_stills",
            )
            self.assertEqual(plan["closure_claims"], ["order_mechanics"])
            self.assertEqual(plan["variant_count"], 6)

    def test_calibration_dataset_inventory_rejects_any_crop_manifest_drift(
        self,
    ) -> None:
        files = {
            "1520530308199447626.png": b"cropped-frame-one",
            "1520530309399588486.png": b"cropped-frame-two",
        }
        crop_manifest = calibration_crop_manifest(files)
        constants = calibration_manifest_constants(crop_manifest)
        expected_sha256 = constants["TUMVI_SUPPORTED_CROP_MANIFEST_SHA256"]
        assert isinstance(expected_sha256, str)

        with (
            tempfile.TemporaryDirectory() as temporary,
            mock.patch.multiple(producer, **constants),
        ):
            source = Path(temporary) / "supported-crop"
            source.mkdir()
            for name, contents in files.items():
                (source / name).write_bytes(contents)

            cases: list[tuple[str, dict[str, object], str, str]] = []
            wrong_bytes = json.loads(json.dumps(crop_manifest))
            wrong_bytes["entries"][0]["output_bytes"] += 1
            cases.append(("bytes", wrong_bytes, expected_sha256, "calibration crop"))
            wrong_hash = json.loads(json.dumps(crop_manifest))
            wrong_hash["entries"][0]["output_sha256"] = "0" * 64
            cases.append(("hash", wrong_hash, expected_sha256, "output set"))
            wrong_name = json.loads(json.dumps(crop_manifest))
            wrong_name["entries"][0]["name"] = "renamed.png"
            cases.append(("name", wrong_name, expected_sha256, "calibration crop"))
            cases.append(
                (
                    "manifest digest",
                    crop_manifest,
                    digest_bytes(b"different-manifest"),
                    "manifest digest",
                )
            )
            for label, candidate, supplied_digest, expected_message in cases:
                with self.subTest(label=label), self.assertRaisesRegex(
                    producer.ProducerError,
                    expected_message,
                ):
                    producer.inventory_source_manifest(
                        source,
                        corpus_id="tumvi-supported-fisheye-control",
                        source_kind="calibration_dataset_derived_stills",
                        origin_manifest=candidate,
                        origin_manifest_file_sha256=supplied_digest,
                    )

    def test_calibration_source_manifest_rejects_original_uncropped_hashes(
        self,
    ) -> None:
        files = {
            "1520530308199447626.png": b"cropped-frame-one",
            "1520530309399588486.png": b"cropped-frame-two",
        }
        crop_manifest = calibration_crop_manifest(files)
        constants = calibration_manifest_constants(crop_manifest)
        crop_manifest_sha256 = constants["TUMVI_SUPPORTED_CROP_MANIFEST_SHA256"]
        assert isinstance(crop_manifest_sha256, str)

        with (
            tempfile.TemporaryDirectory() as temporary,
            mock.patch.multiple(producer, **constants),
        ):
            source = Path(temporary) / "supported-crop"
            source.mkdir()
            for name, contents in files.items():
                (source / name).write_bytes(contents)
            manifest = producer.inventory_source_manifest(
                source,
                corpus_id="tumvi-supported-fisheye-control",
                source_kind="calibration_dataset_derived_stills",
                origin_manifest=crop_manifest,
                origin_manifest_file_sha256=crop_manifest_sha256,
            )
            manifest["entries"][0]["source_sha256"] = (
                "sha256:" + crop_manifest["entries"][0]["source_sha256"]
            )
            with self.assertRaisesRegex(
                producer.ProducerError,
                "calibration crop output set",
            ):
                producer._validated_manifest(manifest)

    def test_calibration_inventory_rejects_extraneous_source_entries(self) -> None:
        files = {
            "1520530308199447626.png": b"cropped-frame-one",
            "1520530309399588486.png": b"cropped-frame-two",
        }
        crop_manifest = calibration_crop_manifest(files)
        constants = calibration_manifest_constants(crop_manifest)
        crop_manifest_sha256 = constants["TUMVI_SUPPORTED_CROP_MANIFEST_SHA256"]
        assert isinstance(crop_manifest_sha256, str)

        with (
            tempfile.TemporaryDirectory() as temporary,
            mock.patch.multiple(producer, **constants),
        ):
            source = Path(temporary) / "supported-crop"
            source.mkdir()
            for name, contents in files.items():
                (source / name).write_bytes(contents)
            (source / "notes.txt").write_text("not part of the calibrated closure")

            with self.assertRaisesRegex(
                producer.ProducerUnavailable,
                "calibration_crop_output_set_mismatch",
            ):
                producer.inventory_source_manifest(
                    source,
                    corpus_id="tumvi-supported-fisheye-control",
                    source_kind="calibration_dataset_derived_stills",
                    origin_manifest=crop_manifest,
                    origin_manifest_file_sha256=crop_manifest_sha256,
                )

    def test_declared_source_kind_must_match_bound_origin_provenance(self) -> None:
        manifest = source_manifest({"IMG_1.JPG": b"a", "IMG_2.JPG": b"b"})
        with self.assertRaisesRegex(producer.ProducerError, "origin provenance"):
            producer.build_group_contract(
                manifest=manifest,
                request=request(2),
                request_file_sha256=digest_bytes(b"request"),
                group_id="provenance-mismatch",
                source_kind="single_video_derived_stills",
                mode="development",
                shuffle_count=2,
                adapter_sha256=digest_bytes(b"adapter"),
                toolchain_closure_sha256=digest_bytes(b"toolchain"),
            )

    def test_derived_inventory_binds_distinct_video_origin_closure(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            source = Path(temporary) / "frames"
            source.mkdir()
            (source / "frame-001.JPG").write_bytes(b"frame-one")
            (source / "frame-002.JPG").write_bytes(b"frame-two")
            origins = {
                "schema_version": 1,
                "sources": [
                    {"kind": "video", "source_sha256": digest_bytes(b"clip-one")},
                    {"kind": "video", "source_sha256": digest_bytes(b"clip-two")},
                ],
            }

            manifest = producer.inventory_source_manifest(
                source,
                corpus_id="multi-video-derived",
                source_kind="multi_video_derived_stills",
                origin_manifest=origins,
            )
            self.assertEqual(
                manifest["provenance"],
                {
                    "source_kind": "multi_video_derived_stills",
                    "video_origin_count": 2,
                    "photo_origin_count": 0,
                    "origin_closure_sha256": evidence.sha256_bytes(
                        evidence.canonical_json_bytes(
                            sorted(
                                origins["sources"],
                                key=lambda item: (
                                    item["kind"],
                                    item["source_sha256"],
                                ),
                            )
                        )
                    ),
                },
            )

    def test_native_inventory_requires_an_exact_native_origin_receipt(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            source = Path(temporary) / "photos"
            source.mkdir()
            files = {"IMG_001.JPG": b"photo-one", "IMG_002.JPG": b"photo-two"}
            for name, contents in files.items():
                (source / name).write_bytes(contents)

            with self.assertRaisesRegex(producer.ProducerError, "origin manifest"):
                producer.inventory_source_manifest(
                    source,
                    corpus_id="native-photo-fixture",
                    source_kind="native_photos",
                    origin_manifest=None,
                )

            manifest = producer.inventory_source_manifest(
                source,
                corpus_id="native-photo-fixture",
                source_kind="native_photos",
                origin_manifest=native_origin_manifest(files),
            )
            self.assertEqual(manifest["provenance"]["photo_origin_count"], 2)

            wrong = native_origin_manifest(files)
            wrong["sources"][0]["source_sha256"] = digest_bytes(b"derived-frame")
            with self.assertRaisesRegex(producer.ProducerError, "native photo origins"):
                producer.inventory_source_manifest(
                    source,
                    corpus_id="native-photo-fixture",
                    source_kind="native_photos",
                    origin_manifest=wrong,
                )

    def test_derived_inventory_rejects_origin_class_mismatch(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            source = Path(temporary) / "frames"
            source.mkdir()
            (source / "frame-001.JPG").write_bytes(b"frame-one")
            (source / "frame-002.JPG").write_bytes(b"frame-two")
            origins = {
                "schema_version": 1,
                "sources": [
                    {"kind": "video", "source_sha256": digest_bytes(b"clip")},
                    {"kind": "native_photo", "source_sha256": digest_bytes(b"photo")},
                ],
            }
            with self.assertRaisesRegex(producer.ProducerError, "origin class"):
                producer.inventory_source_manifest(
                    source,
                    corpus_id="wrong-derived-class",
                    source_kind="single_video_derived_stills",
                    origin_manifest=origins,
                )

    def test_cli_dry_run_is_a_runnable_redacted_entry_point(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            manifest_path = root / "manifest.json"
            request_path = root / "request.json"
            manifest_path.write_text(
                json.dumps(
                    source_manifest(
                        {"private/IMG_1.JPG": b"a", "private/IMG_2.JPG": b"b"}
                    )
                )
            )
            request_path.write_text(json.dumps(request(2)))
            completed = subprocess.run(
                [
                    "python3",
                    "scripts/benchmark/photo_permutation_producer.py",
                    "dry-run",
                    "--source-manifest",
                    str(manifest_path),
                    "--request",
                    str(request_path),
                    "--source-kind",
                    "native_photos",
                    "--shuffle-count",
                    "2",
                ],
                cwd=Path(__file__).resolve().parents[3],
                check=True,
                text=True,
                capture_output=True,
            )
            output = json.loads(completed.stdout)
            self.assertEqual(output["evidence_status"], "development_only")
            self.assertNotIn("IMG_1", completed.stdout)
            self.assertNotIn("sha256:", completed.stdout)

            direct_help = subprocess.run(
                [
                    "python3",
                    "scripts/benchmark/photo_permutation_producer.py",
                    "--help",
                ],
                cwd=Path(__file__).resolve().parents[3],
                check=True,
                text=True,
                capture_output=True,
            )
            self.assertIn("run-group", direct_help.stdout)

            release = subprocess.run(
                [
                    "python3",
                    "scripts/benchmark/photo_permutation_producer.py",
                    "dry-run",
                    "--source-manifest",
                    str(manifest_path),
                    "--request",
                    str(request_path),
                    "--source-kind",
                    "native_photos",
                    "--mode",
                    "release",
                    "--shuffle-count",
                    "19",
                ],
                cwd=Path(__file__).resolve().parents[3],
                check=True,
                text=True,
                capture_output=True,
            )
            release_output = json.loads(release.stdout)
            self.assertEqual(
                release_output["evidence_status"], "unsealed_formal_schedule"
            )
            self.assertEqual(release_output["variant_count"], 20)
            self.assertEqual(
                release_output["variants"][8]["permutation"]["seed"],
                evidence.photo_permutation_release_seed(8),
            )

    def test_cli_rejects_module_bytecode_entry_point(self) -> None:
        completed = subprocess.run(
            [
                "python3",
                "-m",
                "scripts.benchmark.photo_permutation_producer",
                "--help",
            ],
            cwd=Path(__file__).resolve().parents[3],
            check=False,
            text=True,
            capture_output=True,
        )
        self.assertNotEqual(completed.returncode, 0)
        self.assertIn("module bytecode is not accepted", completed.stderr)

    def test_cli_inventory_recurses_writes_private_manifest_and_discloses_no_paths(
        self,
    ) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            source = root / "selected-frames"
            (source / "nested").mkdir(parents=True)
            (source / "nested/FRAME_002.PNG").write_bytes(b"frame-two")
            (source / "FRAME_001.JPG").write_bytes(b"frame-one")
            (source / ".DS_Store").write_bytes(b"ignored")
            origins = root / "native-origins.json"
            origins.write_text(
                json.dumps(
                    native_origin_manifest(
                        {
                            "FRAME_001.JPG": b"frame-one",
                            "nested/FRAME_002.PNG": b"frame-two",
                        }
                    )
                )
            )
            output = root / "private-source-manifest.json"
            command = [
                "python3",
                "scripts/benchmark/photo_permutation_producer.py",
                "inventory",
                "--source-root",
                str(source),
                "--corpus-id",
                "park-selected-frames",
                "--source-kind",
                "native_photos",
                "--origin-manifest",
                str(origins),
                "--output",
                str(output),
            ]
            completed = subprocess.run(
                command,
                cwd=Path(__file__).resolve().parents[3],
                check=True,
                text=True,
                capture_output=True,
            )
            public = json.loads(completed.stdout)
            manifest = json.loads(output.read_text())
            self.assertEqual(public["file_count"], 2)
            self.assertEqual(stat.S_IMODE(output.stat().st_mode), 0o600)
            self.assertEqual(
                [entry["relative_path"] for entry in manifest["entries"]],
                ["FRAME_001.JPG", "nested/FRAME_002.PNG"],
            )
            self.assertNotIn(str(source), completed.stdout)
            self.assertNotIn("FRAME_001", completed.stdout)
            self.assertNotIn("sha256:", completed.stdout)

            (source / "FRAME_001.JPG").rename(source / "renamed.JPG")
            renamed_output = root / "renamed-source-manifest.json"
            renamed = subprocess.run(
                [*command[:-1], str(renamed_output)],
                cwd=Path(__file__).resolve().parents[3],
                check=True,
                text=True,
                capture_output=True,
            )
            renamed_manifest = json.loads(renamed_output.read_text())
            self.assertEqual(json.loads(renamed.stdout)["file_count"], 2)
            self.assertEqual(
                {entry["source_sha256"] for entry in manifest["entries"]},
                {entry["source_sha256"] for entry in renamed_manifest["entries"]},
            )
            self.assertIn(
                "renamed.JPG",
                {entry["relative_path"] for entry in renamed_manifest["entries"]},
            )

            preexisting = root / "do-not-replace.txt"
            preexisting.write_bytes(b"user-owned")
            rejected_existing = subprocess.run(
                [*command[:-1], str(preexisting)],
                cwd=Path(__file__).resolve().parents[3],
                check=False,
                text=True,
                capture_output=True,
            )
            self.assertNotEqual(rejected_existing.returncode, 0)
            self.assertEqual(preexisting.read_bytes(), b"user-owned")

            source_photo = source / "renamed.JPG"
            original_photo = source_photo.read_bytes()
            rejected_source = subprocess.run(
                [*command[:-1], str(source_photo)],
                cwd=Path(__file__).resolve().parents[3],
                check=False,
                text=True,
                capture_output=True,
            )
            self.assertNotEqual(rejected_source.returncode, 0)
            self.assertEqual(source_photo.read_bytes(), original_photo)

    def test_inventory_rejects_symlinks_duplicates_special_files_and_path_mutation(
        self,
    ) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)

            symlink_root = root / "symlink"
            symlink_root.mkdir()
            (symlink_root / "a.JPG").write_bytes(b"a")
            (symlink_root / "b.JPG").write_bytes(b"b")
            (symlink_root / "linked.JPG").symlink_to(symlink_root / "a.JPG")
            with self.assertRaisesRegex(producer.ProducerUnavailable, "symlink"):
                producer.inventory_source_manifest(
                    symlink_root,
                    corpus_id="symlink-fixture",
                    source_kind="native_photos",
                    origin_manifest=native_origin_manifest(
                        {"a.JPG": b"a", "b.JPG": b"b"}
                    ),
                )

            duplicate_root = root / "duplicate"
            duplicate_root.mkdir()
            (duplicate_root / "a.JPG").write_bytes(b"same")
            (duplicate_root / "b.PNG").write_bytes(b"same")
            with self.assertRaisesRegex(
                producer.ProducerUnavailable, "duplicate_content"
            ):
                producer.inventory_source_manifest(
                    duplicate_root,
                    corpus_id="duplicate-fixture",
                    source_kind="native_photos",
                    origin_manifest=native_origin_manifest(
                        {"a.JPG": b"same", "b.PNG": b"same"}
                    ),
                )

            special_root = root / "special"
            special_root.mkdir()
            (special_root / "a.JPG").write_bytes(b"a")
            os.mkfifo(special_root / "capture.JPG")
            with self.assertRaisesRegex(producer.ProducerUnavailable, "unsafe_entry"):
                producer.inventory_source_manifest(
                    special_root,
                    corpus_id="special-fixture",
                    source_kind="native_photos",
                    origin_manifest=native_origin_manifest({"a.JPG": b"a"}),
                )

            mutation_root = root / "mutation"
            mutation_root.mkdir()
            mutable = mutation_root / "a.JPG"
            mutable.write_bytes(b"a")
            (mutation_root / "b.JPG").write_bytes(b"b")
            original_hash = producer._hash_open_descriptor
            mutated = False

            def mutate_after_hash(descriptor: int, **kwargs: object):
                nonlocal mutated
                result = original_hash(descriptor, **kwargs)
                if not mutated:
                    mutable.rename(mutation_root / "moved.JPG")
                    mutated = True
                return result

            with (
                mock.patch.object(producer, "_hash_open_descriptor", mutate_after_hash),
                self.assertRaisesRegex(producer.ProducerUnavailable, "path_changed"),
            ):
                producer.inventory_source_manifest(
                    mutation_root,
                    corpus_id="mutation-fixture",
                    source_kind="native_photos",
                    origin_manifest=native_origin_manifest(
                        {"a.JPG": b"a", "b.JPG": b"b"}
                    ),
                )

    def test_artifacts_are_normalized_by_protected_content_identity(self) -> None:
        files = {
            "a/IMG_0001.JPG": b"photo-a",
            "b/IMG_0002.JPG": b"photo-b",
            "c/IMG_0003.JPG": b"photo-c",
        }
        manifest = source_manifest(files)
        mapping = evidence.build_photo_permutation_mapping(
            protocol_mapping_manifest(manifest),
            scale=3,
            permutation_index=1,
            permutation_seed=17,
        )
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            project = root / "project"
            (project / "Frames").mkdir(parents=True)
            (project / "SfM").mkdir()
            (project / "Logs").mkdir()
            model = project / "Training/measurement-candidate-source-text"
            model.mkdir(parents=True)
            originals = project / "Originals/Photos"
            originals.mkdir(parents=True)
            content_by_digest = {
                digest_bytes(contents): contents for contents in files.values()
            }
            image_names = [f"frame-{index:06d}.jpg" for index in range(1, 4)]
            selected_manifest = []
            for image_name, mapped in zip(image_names, mapping["entries"], strict=True):
                (originals / mapped["target_relative_path"]).write_bytes(
                    content_by_digest[mapped["source_sha256"]]
                )
                selected_manifest.append(
                    {
                        "outputFileName": image_name,
                        "sourceProjectRelativePath": (
                            "Originals/Photos/" + mapped["target_relative_path"]
                        ),
                        "sourceSHA256": mapped["source_sha256"],
                    }
                )
            (project / "Frames/selected_manifest.json").write_text(
                json.dumps(selected_manifest)
            )
            scheduled = [
                {
                    "firstImageName": image_names[first],
                    "secondImageName": image_names[second],
                    "role": "retrieval",
                }
                for first in range(3)
                for second in range(first + 1, 3)
            ]
            pair_evidence = {
                "schemaVersion": 20,
                "pairingPolicy": "unorderedRetrieval",
                "planBinding": pair_graph_plan_binding(
                    request()["candidate_run_configuration"]
                ),
                "acceptedAttemptNumber": 1,
                "attempts": [
                    {
                        "artifact": {
                            "attemptNumber": 1,
                            "matcher": "faiss",
                            "exactRecoveryReason": None,
                            "recoveryLevel": "normal",
                            "outcome": "completed",
                        },
                        "scheduledPairs": scheduled,
                        "retrieval": None,
                        "retrievalWasExecuted": False,
                    }
                ],
                "acceptedInspection": {
                    "scheduledPairCount": len(scheduled),
                    "attemptedPairCount": len(scheduled),
                    "attemptedPairs": scheduled,
                    "rawMatchedPairCount": 2,
                    "rawMatchedPairs": scheduled[:2],
                    "spatiallyVerifiedPairCount": 2,
                    "spatiallyVerifiedPairs": scheduled[:2],
                },
            }
            (project / "SfM/pair_graph_evidence.json").write_text(
                json.dumps(pair_evidence)
            )
            (project / "SfM/geometry_manifest.json").write_text("{}")
            (project / "Logs/pipeline.log").write_text("fixture\n")
            image_lines = []
            centers = ((0.0, 0.0, 0.0), (1.0, 0.0, 0.0), (0.0, 1.0, 0.0))
            for image_id, (name, center) in enumerate(
                zip(image_names, centers, strict=True), start=1
            ):
                image_lines.extend(
                    [
                        f"{image_id} 1 0 0 0 {-center[0]} {-center[1]} {-center[2]} 1 {name}",
                        "",
                    ]
                )
            (model / "images.txt").write_text("\n".join(image_lines) + "\n")
            envelope = geometry_envelope(project, registered_views=3)

            observation = producer.derive_private_geometry_observation(
                envelope,
                mapping=mapping,
                requested_plan=request()["candidate_run_configuration"],
                hmac_key=b"k" * 32,
                expected_project_root=project,
                expected_variant="candidate",
            )
            public = producer.build_public_variant(
                observation,
                spec=producer.VariantSpec("canonical", 0, 0),
                group_id="private-fixture-group",
                source_kind="native_photos",
                request=request(),
                canonical_observation=None,
                canonical_observation_attestation=opaque(
                    "canonical-observation"
                ),
            )

            self.assertEqual(
                public["registered_content_ids"], public["selected_content_ids"]
            )
            self.assertEqual(public["accepted_attempt"], "exhaustive_primary")
            self.assertEqual(public["pair_counts"]["exhaustive_primary"], 2)
            self.assertEqual(len(public["normalized_pair_edges"]), 2)
            self.assertRegex(public["order_commitment"], evidence.OPAQUE_SHA256_PATTERN)
            self.assertNotEqual(
                public["order_commitment"],
                mapping["order_manifest_sha256"],
            )
            self.assertNotIn("IMG_0001", json.dumps(public, sort_keys=True))
            self.assertNotIn(
                digest_bytes(b"photo-a"), json.dumps(public, sort_keys=True)
            )
            public_group = {
                "schema_version": 1,
                "mode": "development",
                "expected_variant_count": 2,
                "closure_claims": ["order_mechanics"],
                "variants": [
                    public,
                    dict(
                        public,
                        variant_id="shuffle-01",
                        permutation={"kind": "shuffled", "index": 1, "seed": 17},
                        order_commitment=opaque("other-order"),
                    ),
                ],
            }
            execution_receipt = seal_public_group(public_group)
            evidence.validate_photo_permutation_group(
                public_group,
                request(),
                formal_release=False,
                execution_receipt=execution_receipt,
            )
            outside_path = list(selected_manifest)
            outside_path[0] = {
                **outside_path[0],
                "sourceProjectRelativePath": (
                    "Outside/" + mapping["entries"][0]["target_relative_path"]
                ),
            }
            (project / "Frames/selected_manifest.json").write_text(
                json.dumps(outside_path)
            )
            with self.assertRaisesRegex(
                producer.ProducerUnavailable, "selection_artifact_invalid"
            ):
                producer.derive_private_geometry_observation(
                    envelope,
                    mapping=mapping,
                    requested_plan=request()["candidate_run_configuration"],
                    hmac_key=b"k" * 32,
                    expected_project_root=project,
                    expected_variant="candidate",
                )
            conflicting = list(selected_manifest)
            conflicting[0] = {
                **conflicting[0],
                "sourceSHA256": mapping["entries"][1]["source_sha256"],
            }
            (project / "Frames/selected_manifest.json").write_text(
                json.dumps(conflicting)
            )
            with self.assertRaisesRegex(
                producer.ProducerUnavailable, "selection_artifact_identity_conflict"
            ):
                producer.derive_private_geometry_observation(
                    envelope,
                    mapping=mapping,
                    requested_plan=request()["candidate_run_configuration"],
                    hmac_key=b"k" * 32,
                    expected_project_root=project,
                    expected_variant="candidate",
                )

    def test_production_adopted_photo_names_bind_through_the_verified_source_digest(
        self,
    ) -> None:
        files = {
            "capture/DSC_0001.JPG": b"photo-a",
            "capture/DSC_0002.JPG": b"photo-b",
            "capture/DSC_0003.JPG": b"photo-c",
        }
        manifest = source_manifest(files)
        mapping = producer._canonical_mapping(manifest, scale=3)
        content_by_digest = {
            "sha256:" + hashlib.sha256(content).hexdigest(): content
            for content in files.values()
        }
        with tempfile.TemporaryDirectory() as temporary:
            project = Path(temporary) / "project"
            envelope = write_geometry_project(
                project,
                [entry["target_relative_path"] for entry in mapping["entries"]],
            )
            originals = project / "Originals/Photos"
            originals.mkdir(parents=True)
            selection = json.loads(
                (project / "Frames/selected_manifest.json").read_text()
            )
            for index, (item, mapped) in enumerate(
                zip(selection, mapping["entries"], strict=True)
            ):
                adopted_leaf = f"photo-{index:04d}.jpg"
                (originals / adopted_leaf).write_bytes(
                    content_by_digest[mapped["source_sha256"]]
                )
                item["sourceProjectRelativePath"] = "Originals/Photos/" + adopted_leaf
                item["sourceSHA256"] = mapped["source_sha256"].removeprefix("sha256:")
            (project / "Frames/selected_manifest.json").write_text(
                json.dumps(selection)
            )

            observation = producer.derive_private_geometry_observation(
                envelope,
                mapping=mapping,
                requested_plan=request()["candidate_run_configuration"],
                hmac_key=b"k" * 32,
                expected_project_root=project,
                expected_variant="candidate",
            )
            self.assertEqual(
                observation["selected_content_ids"],
                sorted(observation["selected_content_ids"]),
            )

            selection[0]["sourceSHA256"] = mapping["entries"][1][
                "source_sha256"
            ].removeprefix("sha256:")
            (project / "Frames/selected_manifest.json").write_text(
                json.dumps(selection)
            )
            with self.assertRaisesRegex(
                producer.ProducerUnavailable, "selection_artifact_identity_conflict"
            ):
                producer.derive_private_geometry_observation(
                    envelope,
                    mapping=mapping,
                    requested_plan=request()["candidate_run_configuration"],
                    hmac_key=b"k" * 32,
                    expected_project_root=project,
                    expected_variant="candidate",
                )

    def test_exhaustive_schedule_must_be_the_exact_selected_pair_closure(self) -> None:
        selected = {"a.jpg", "b.jpg", "c.jpg"}
        valid = [
            {"firstImageName": "a.jpg", "secondImageName": "b.jpg", "role": "local"},
            {"firstImageName": "a.jpg", "secondImageName": "c.jpg", "role": "local"},
            {"firstImageName": "b.jpg", "secondImageName": "c.jpg", "role": "local"},
        ]
        producer._validated_scheduled_roles(
            valid,
            selected_names=selected,
            require_exhaustive=True,
        )
        wrong = [
            *valid[:-1],
            {
                "firstImageName": "b.jpg",
                "secondImageName": "outside.jpg",
                "role": "local",
            },
        ]
        with self.assertRaisesRegex(
            producer.ProducerUnavailable,
            "pair_graph_artifact_invalid",
        ):
            producer._validated_scheduled_roles(
                wrong,
                selected_names=selected,
                require_exhaustive=True,
            )

    def test_every_scheduled_pair_must_have_attempted_execution_evidence(self) -> None:
        scheduled = [
            {"firstImageName": "a.jpg", "secondImageName": "b.jpg", "role": "local"},
            {"firstImageName": "a.jpg", "secondImageName": "c.jpg", "role": "local"},
            {"firstImageName": "b.jpg", "secondImageName": "c.jpg", "role": "local"},
        ]
        scheduled_roles = producer._validated_scheduled_roles(
            scheduled,
            selected_names={"a.jpg", "b.jpg", "c.jpg"},
            require_exhaustive=True,
        )
        inspection = {
            "scheduledPairCount": 3,
            "attemptedPairCount": 2,
            "attemptedPairs": scheduled[:2],
            "rawMatchedPairCount": 2,
            "rawMatchedPairs": scheduled[:2],
            "spatiallyVerifiedPairCount": 2,
            "spatiallyVerifiedPairs": scheduled[:2],
        }
        with self.assertRaisesRegex(
            producer.ProducerUnavailable,
            "pair_graph_artifact_invalid",
        ):
            producer._validated_inspection_pairs(
                inspection,
                scheduled_roles=scheduled_roles,
            )

    def test_retrieval_execution_requires_a_closed_worker_receipt(self) -> None:
        selected = ["a.jpg", "b.jpg", "c.jpg"]
        with self.assertRaisesRegex(
            producer.ProducerUnavailable,
            "pair_graph_artifact_invalid",
        ):
            producer._validated_retrieval_evidence(
                {},
                selected_names=selected,
                expected_query_stride=1,
                expected_candidate_count=20,
                expected_neighbor_count=8,
            )

        incomplete = {
            "engine": "localSiftVocabularyV2",
            "queryImageNames": ["a.jpg"],
            "queryStride": 1,
            "candidateCount": 20,
            "returnedNeighborCount": 8,
            "minimumFrameSeparation": 0,
            "directedPairLines": ["a.jpg b.jpg"],
        }
        with self.assertRaisesRegex(
            producer.ProducerUnavailable,
            "pair_graph_artifact_invalid",
        ):
            producer._validated_retrieval_evidence(
                incomplete,
                selected_names=selected,
                expected_query_stride=1,
                expected_candidate_count=20,
                expected_neighbor_count=8,
            )

        legacy = {
            **incomplete,
            "queryImageNames": selected,
            "directedPairLines": ["a.jpg b.jpg", "b.jpg c.jpg", "c.jpg a.jpg"],
        }
        with self.assertRaisesRegex(
            producer.ProducerUnavailable,
            "pair_graph_artifact_invalid",
        ):
            producer._validated_retrieval_evidence(
                legacy,
                selected_names=selected,
                expected_query_stride=1,
                expected_candidate_count=20,
                expected_neighbor_count=8,
            )

        receipt = retrieval_receipt(selected)
        self.assertEqual(
            producer._validated_retrieval_evidence(
                receipt,
                selected_names=selected,
                expected_query_stride=1,
                expected_candidate_count=20,
                expected_neighbor_count=8,
            ),
            {
                frozenset(("a.jpg", "b.jpg")),
                frozenset(("b.jpg", "c.jpg")),
                frozenset(("a.jpg", "c.jpg")),
            },
        )

        tampered = dict(receipt, outputDigest="0" * 64)
        with self.assertRaisesRegex(
            producer.ProducerUnavailable,
            "pair_graph_artifact_invalid",
        ):
            producer._validated_retrieval_evidence(
                tampered,
                selected_names=selected,
                expected_query_stride=1,
                expected_candidate_count=20,
                expected_neighbor_count=8,
            )

    def test_retrieval_contract_accepts_zero_outcomes_but_rejects_status_count_mismatch(
        self,
    ) -> None:
        selected = ["a.jpg", "b.jpg", "c.jpg"]

        def seal(receipt: dict[str, object]) -> dict[str, object]:
            query_names = receipt["queryImageNames"]
            outcomes = receipt["queryOutcomes"]
            directed_pairs = receipt["directedPairLines"]
            assert isinstance(query_names, list)
            assert isinstance(outcomes, list)
            assert isinstance(directed_pairs, list)
            request_digest = canonical_string_digest(
                ["localSiftVocabularyV2", "1", "20", "8", "0", *query_names]
            )
            contract_lines = [
                " ".join(
                    (
                        "EASYSPLAT_RETRIEVAL_OUTCOMES_V2",
                        "localSiftVocabularyV2",
                        "1",
                        "20",
                        "8",
                        "0",
                        str(len(query_names)),
                        request_digest,
                    )
                ),
                *[
                    " ".join(
                        (
                            "Q",
                            outcome["status"],
                            outcome["queryImageName"],
                            str(len(outcome["rankedNeighborImageNames"])),
                            *outcome["rankedNeighborImageNames"],
                        )
                    )
                    for outcome in outcomes
                ],
                *[f"P {line}" for line in directed_pairs],
            ]
            return dict(
                receipt,
                outputDigest=canonical_string_digest(contract_lines),
            )

        zero = retrieval_receipt(selected)
        zero["queryOutcomes"] = [
            {
                "queryImageName": name,
                "status": "noRankedNeighbors",
                "rankedNeighborImageNames": [],
            }
            for name in selected
        ]
        zero["directedPairLines"] = []
        zero = seal(zero)
        self.assertEqual(
            producer._validated_retrieval_evidence(
                zero,
                selected_names=selected,
                expected_query_stride=1,
                expected_candidate_count=20,
                expected_neighbor_count=8,
            ),
            set(),
        )

        mismatched = dict(zero)
        mismatched["queryOutcomes"] = [dict(item) for item in zero["queryOutcomes"]]
        mismatched["queryOutcomes"][0] = {
            "queryImageName": selected[0],
            "status": "noRankedNeighbors",
            "rankedNeighborImageNames": [selected[1]],
        }
        mismatched["directedPairLines"] = [f"{selected[0]} {selected[1]}"]
        mismatched = seal(mismatched)
        with self.assertRaisesRegex(
            producer.ProducerUnavailable,
            "pair_graph_artifact_invalid",
        ):
            producer._validated_retrieval_evidence(
                mismatched,
                selected_names=selected,
                expected_query_stride=1,
                expected_candidate_count=20,
                expected_neighbor_count=8,
            )

    def test_retired_pair_graph_schema_is_rejected(self) -> None:
        files = {
            "a.JPG": b"photo-a",
            "b.JPG": b"photo-b",
            "c.JPG": b"photo-c",
        }
        manifest = source_manifest(files)
        mapping = evidence.build_photo_permutation_mapping(
            protocol_mapping_manifest(manifest),
            scale=3,
            permutation_index=1,
            permutation_seed=17,
        )
        for schema_version in (18, 19.0):
            with (
                self.subTest(schema_version=schema_version),
                tempfile.TemporaryDirectory() as temporary,
            ):
                project = Path(temporary) / "project"
                envelope = write_geometry_project(
                    project,
                    [entry["target_relative_path"] for entry in mapping["entries"]],
                    mapping_entries=mapping["entries"],
                    source_files=files,
                )
                pair_path = project / "SfM/pair_graph_evidence.json"
                pair_evidence = json.loads(pair_path.read_text())
                pair_evidence["schemaVersion"] = schema_version
                pair_path.write_text(json.dumps(pair_evidence))

                with self.assertRaisesRegex(
                    producer.ProducerUnavailable,
                    "pair_graph_artifact_invalid",
                ):
                    producer.derive_private_geometry_observation(
                        envelope,
                        mapping=mapping,
                        requested_plan=request()["candidate_run_configuration"],
                        hmac_key=b"k" * 32,
                        expected_project_root=project,
                        expected_variant="candidate",
                    )

    def test_current_pair_graph_schema_binds_the_resolved_fisheye_initializer(
        self,
    ) -> None:
        files = {
            "a.JPG": b"photo-a",
            "b.JPG": b"photo-b",
            "c.JPG": b"photo-c",
        }
        manifest = source_manifest(files)
        mapping = evidence.build_photo_permutation_mapping(
            protocol_mapping_manifest(manifest),
            scale=3,
            permutation_index=1,
            permutation_seed=17,
        )
        requested_plan = {
            **request()["candidate_run_configuration"],
            "camera_grouping": "same_camera_and_lens",
            "lens_projection": "fisheye",
            "temporal_pairing": "none",
            "temporal_offsets": [],
            "descriptor_matcher": "faiss",
        }
        with tempfile.TemporaryDirectory() as temporary:
            project = Path(temporary) / "project"
            envelope = write_geometry_project(
                project,
                [entry["target_relative_path"] for entry in mapping["entries"]],
                mapping_entries=mapping["entries"],
                source_files=files,
            )
            pair_path = project / "SfM/pair_graph_evidence.json"
            pair_evidence = json.loads(pair_path.read_text())
            pair_evidence.update(
                {
                    "schemaVersion": 20,
                    "planBinding": {
                        "pairingPolicy": "unorderedRetrieval",
                        "geometryBackend": "colmap",
                        "modelIdentifier": "none",
                        "temporalPairing": "none",
                        "temporalOffsets": [],
                        "retrievalEngine": "localSiftVocabularyV2",
                        "retrievalCandidateCount": 20,
                        "retrievalNeighborCount": 8,
                        "retrievalQueryStride": 1,
                        "requiresCrossClipRetrieval": False,
                        "normalDescriptorMatcher": "faiss",
                        "cameraInitializationRecipe": (
                            "sharedOpenCVFisheyeEquidistantDiagonal150V1"
                        ),
                        "runSeed": 42,
                    },
                }
            )
            pair_path.write_text(json.dumps(pair_evidence))

            observation = producer.derive_private_geometry_observation(
                envelope,
                mapping=mapping,
                requested_plan=requested_plan,
                hmac_key=b"k" * 32,
                expected_project_root=project,
                expected_variant="candidate",
            )

            self.assertEqual(observation["pairing_policy"], "unordered_exhaustive")

    def test_pair_graph_plan_binding_must_exactly_match_the_requested_plan(
        self,
    ) -> None:
        files = {
            "a.JPG": b"photo-a",
            "b.JPG": b"photo-b",
            "c.JPG": b"photo-c",
        }
        manifest = source_manifest(files)
        mapping = evidence.build_photo_permutation_mapping(
            protocol_mapping_manifest(manifest),
            scale=3,
            permutation_index=1,
            permutation_seed=17,
        )
        requested_plan = request()["candidate_run_configuration"]
        assert isinstance(requested_plan, dict)
        mutations = {
            "pairing policy": ("pairingPolicy", "orderedContinuous"),
            "geometry backend": ("geometryBackend", "da3"),
            "model identifier": ("modelIdentifier", "DA3-BASE"),
            "temporal pairing": ("temporalPairing", "linear"),
            "temporal offsets": ("temporalOffsets", [1]),
            "retrieval engine": ("retrievalEngine", "other"),
            "candidate count": ("retrievalCandidateCount", 21),
            "candidate count type": ("retrievalCandidateCount", 20.0),
            "neighbor count": ("retrievalNeighborCount", 7),
            "neighbor count type": ("retrievalNeighborCount", 8.0),
            "query stride": ("retrievalQueryStride", 2),
            "query stride type": ("retrievalQueryStride", True),
            "cross-clip requirement": ("requiresCrossClipRetrieval", True),
            "cross-clip requirement type": ("requiresCrossClipRetrieval", 0),
            "matcher": ("normalDescriptorMatcher", "exact"),
            "camera initializer": (
                "cameraInitializationRecipe",
                "sharedOpenCVFisheyeEquidistantDiagonal150V1",
            ),
            "seed": ("runSeed", 43),
            "seed type": ("runSeed", 42.0),
        }
        for label, (field, value) in mutations.items():
            with self.subTest(label=label), tempfile.TemporaryDirectory() as temporary:
                project = Path(temporary) / "project"
                envelope = write_geometry_project(
                    project,
                    [entry["target_relative_path"] for entry in mapping["entries"]],
                    requested_plan=requested_plan,
                    mapping_entries=mapping["entries"],
                    source_files=files,
                )
                pair_path = project / "SfM/pair_graph_evidence.json"
                pair_evidence = json.loads(pair_path.read_text())
                pair_evidence["planBinding"][field] = value
                pair_path.write_text(json.dumps(pair_evidence))

                with self.assertRaisesRegex(
                    producer.ProducerUnavailable,
                    "pair_graph_artifact_invalid",
                ):
                    producer.derive_private_geometry_observation(
                        envelope,
                        mapping=mapping,
                        requested_plan=requested_plan,
                        hmac_key=b"k" * 32,
                        expected_project_root=project,
                        expected_variant="candidate",
                    )

        for label, field in (
            ("camera grouping", "camera_grouping"),
            ("lens projection", "lens_projection"),
        ):
            with self.subTest(label=label), tempfile.TemporaryDirectory() as temporary:
                project = Path(temporary) / "project"
                envelope = write_geometry_project(
                    project,
                    [entry["target_relative_path"] for entry in mapping["entries"]],
                    requested_plan=requested_plan,
                    mapping_entries=mapping["entries"],
                    source_files=files,
                )
                incomplete_plan = dict(requested_plan)
                del incomplete_plan[field]
                with self.assertRaisesRegex(
                    producer.ProducerUnavailable,
                    "pair_graph_artifact_invalid",
                ):
                    producer.derive_private_geometry_observation(
                        envelope,
                        mapping=mapping,
                        requested_plan=incomplete_plan,
                        hmac_key=b"k" * 32,
                        expected_project_root=project,
                        expected_variant="candidate",
                    )

        with tempfile.TemporaryDirectory() as temporary:
            project = Path(temporary) / "project"
            envelope = write_geometry_project(
                project,
                [entry["target_relative_path"] for entry in mapping["entries"]],
                requested_plan=requested_plan,
                mapping_entries=mapping["entries"],
                source_files=files,
            )
            pair_path = project / "SfM/pair_graph_evidence.json"
            pair_evidence = json.loads(pair_path.read_text())
            pair_evidence["planBinding"]["unexpected"] = False
            pair_path.write_text(json.dumps(pair_evidence))
            with self.assertRaisesRegex(
                producer.ProducerUnavailable,
                "pair_graph_artifact_invalid",
            ):
                producer.derive_private_geometry_observation(
                    envelope,
                    mapping=mapping,
                    requested_plan=requested_plan,
                    hmac_key=b"k" * 32,
                    expected_project_root=project,
                    expected_variant="candidate",
                )

        with tempfile.TemporaryDirectory() as temporary:
            project = Path(temporary) / "project"
            envelope = write_geometry_project(
                project,
                [entry["target_relative_path"] for entry in mapping["entries"]],
                requested_plan=requested_plan,
                mapping_entries=mapping["entries"],
                source_files=files,
            )
            pair_path = project / "SfM/pair_graph_evidence.json"
            pair_evidence = json.loads(pair_path.read_text())
            del pair_evidence["planBinding"]["cameraInitializationRecipe"]
            pair_path.write_text(json.dumps(pair_evidence))
            with self.assertRaisesRegex(
                producer.ProducerUnavailable,
                "pair_graph_artifact_invalid",
            ):
                producer.derive_private_geometry_observation(
                    envelope,
                    mapping=mapping,
                    requested_plan=requested_plan,
                    hmac_key=b"k" * 32,
                    expected_project_root=project,
                    expected_variant="candidate",
                )

    def test_photo_pair_evidence_remains_faiss_only(self) -> None:
        files = {
            "a.JPG": b"photo-a",
            "b.JPG": b"photo-b",
            "c.JPG": b"photo-c",
        }
        manifest = source_manifest(files)
        mapping = evidence.build_photo_permutation_mapping(
            protocol_mapping_manifest(manifest),
            scale=3,
            permutation_index=1,
            permutation_seed=17,
        )
        rejected_artifacts = (
            {"matcher": "faiss", "exactRecoveryReason": "faissCrash"},
            {"matcher": "exact", "exactRecoveryReason": "faissCrash"},
        )
        for index, artifact_update in enumerate(rejected_artifacts):
            with self.subTest(artifact_update=artifact_update):
                with tempfile.TemporaryDirectory() as temporary:
                    project = Path(temporary) / f"project-{index}"
                    envelope = write_geometry_project(
                        project,
                        [entry["target_relative_path"] for entry in mapping["entries"]],
                        mapping_entries=mapping["entries"],
                        source_files=files,
                    )
                    pair_path = project / "SfM/pair_graph_evidence.json"
                    pair_evidence = json.loads(pair_path.read_text())
                    pair_evidence["attempts"][0]["artifact"].update(artifact_update)
                    pair_path.write_text(json.dumps(pair_evidence))

                    with self.assertRaisesRegex(
                        producer.ProducerUnavailable,
                        "pair_graph_artifact_invalid",
                    ):
                        producer.derive_private_geometry_observation(
                            envelope,
                            mapping=mapping,
                            requested_plan=request()["candidate_run_configuration"],
                            hmac_key=b"k" * 32,
                            expected_project_root=project,
                            expected_variant="candidate",
                        )

    def test_missing_geometry_is_typed_unavailable_not_zero_filled(self) -> None:
        mapping = evidence.build_photo_permutation_mapping(
            protocol_mapping_manifest(source_manifest({"a.JPG": b"a", "b.JPG": b"b"})),
            scale=2,
            permutation_index=1,
            permutation_seed=17,
        )
        with tempfile.TemporaryDirectory() as temporary:
            project = Path(temporary) / "project"
            project.mkdir()
            with self.assertRaisesRegex(
                producer.ProducerUnavailable, "controlled_artifact_unavailable"
            ):
                producer.derive_private_geometry_observation(
                    geometry_envelope(project, registered_views=0),
                    mapping=mapping,
                    requested_plan=request(2)["candidate_run_configuration"],
                    hmac_key=b"k" * 32,
                    expected_project_root=project,
                    expected_variant="candidate",
                )

    def test_sim3_pose_comparison_removes_only_one_global_frame_change(self) -> None:
        import numpy as np

        angle = np.deg2rad(37.0)
        alignment = np.asarray(
            [
                [np.cos(angle), -np.sin(angle), 0.0],
                [np.sin(angle), np.cos(angle), 0.0],
                [0.0, 0.0, 1.0],
            ]
        )
        translation = np.asarray([4.0, -2.0, 3.0])
        scale = 2.5
        reference_centers = {
            "a": np.asarray([0.0, 0.0, 0.0]),
            "b": np.asarray([1.0, 0.0, 0.0]),
            "c": np.asarray([0.0, 1.0, 0.0]),
            "d": np.asarray([0.2, 0.3, 1.0]),
        }
        reference = {"poses": {}}
        candidate = {"poses": {}}
        for key, center in reference_centers.items():
            candidate_center = alignment.T @ ((center - translation) / scale)
            reference["poses"][key] = {
                "center": center.tolist(),
                "rotation_cw": np.eye(3).tolist(),
            }
            candidate["poses"][key] = {
                "center": candidate_center.tolist(),
                "rotation_cw": alignment.tolist(),
            }

        center_p95, rotation_p95 = producer._pose_deviation(reference, candidate)

        self.assertLess(center_p95, 1e-12)
        self.assertLess(rotation_p95, 3e-6)

    def test_shared_pose_alignment_keeps_private_unavailable_error_codes(self) -> None:
        identity = [[1.0, 0.0, 0.0], [0.0, 1.0, 0.0], [0.0, 0.0, 1.0]]
        two_poses = {
            "poses": {
                "a": {"center": [0.0, 0.0, 0.0], "rotation_cw": identity},
                "b": {"center": [1.0, 0.0, 0.0], "rotation_cw": identity},
            }
        }
        with self.assertRaisesRegex(
            producer.ProducerUnavailable, "^pose_alignment_unavailable$"
        ):
            producer._pose_deviation(two_poses, two_poses)

        collinear = {
            "poses": {
                name: {"center": [float(index), 0.0, 0.0], "rotation_cw": identity}
                for index, name in enumerate(("a", "b", "c"))
            }
        }
        with self.assertRaisesRegex(
            producer.ProducerUnavailable, "^pose_alignment_degenerate$"
        ):
            producer._pose_deviation(collinear, collinear)

    def test_geometry_only_command_has_fixed_seed_and_fresh_paths(self) -> None:
        project = Path("/private/run/project.easysplatproj")
        self.assertEqual(producer.MEASUREMENT_PROJECT_LEAF, project.name)
        command = producer.geometry_only_command(
            adapter=Path("/private/bin/PipelineMeasurementAdapter-current"),
            request_path=Path("/private/request.json"),
            input_root=Path("/private/run/input"),
            toolchain_root=Path("/private/toolchain"),
            project_root=project,
            output_path=Path("/private/run/adapter.json"),
        )
        self.assertEqual(command[-2:], ["--geometry-only", "true"])
        self.assertEqual(command.count(str(project)), 1)
        self.assertEqual(project.name, "project.easysplatproj")
        self.assertNotIn("--resume", command)

    def test_staged_runtime_executes_bound_bytes_when_original_adapter_is_swapped(
        self,
    ) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            original = root / "adapter"
            original.write_text('#!/bin/sh\nprintf trusted > "$1"\nsleep 0.2\n')
            original.chmod(0o755)
            _, snapshot = producer._sha256_file(original)
            runtime = root / "runtime"
            runtime.mkdir(mode=0o700)
            staged = runtime / "adapter"
            producer.stage_pinned_runtime_file(
                original,
                snapshot,
                staged,
                executable=True,
            )
            output = root / "result"
            process = subprocess.Popen([str(staged), str(output)])
            for _ in range(100):
                if output.exists():
                    break
                time.sleep(0.005)
            replacement = root / "replacement"
            replacement.write_text('#!/bin/sh\nprintf substituted > "$1"\n')
            replacement.chmod(0o755)
            os.replace(replacement, original)
            self.assertEqual(process.wait(timeout=5), 0)
            self.assertEqual(output.read_text(), "trusted")

    def test_cli_run_one_and_group_use_fresh_runs_and_resume_only_bound_receipts(
        self,
    ) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            source = root / "source"
            source.mkdir()
            files = {
                "IMG_1.JPG": b"photo-a",
                "IMG_2.JPG": b"photo-b",
                "IMG_3.JPG": b"photo-c",
                "IMG_4.JPG": b"photo-d",
            }
            for name, contents in files.items():
                (source / name).write_bytes(contents)
            manifest_path = root / "manifest.json"
            manifest_path.write_text(json.dumps(source_manifest(files)))
            request_path = root / "request.json"
            request_path.write_text(json.dumps(request(4)))
            toolchain = root / "toolchain"
            toolchain.mkdir()
            (toolchain / ".easysplat_toolchain_state.json").write_bytes(b"receipt")
            adapter = root / "fake-adapter.py"
            invocations = root / "invocations.txt"
            write_fake_adapter(adapter, invocations)
            repository = Path(__file__).resolve().parents[3]

            def runtime_arguments(state: Path, runs: Path) -> list[str]:
                return [
                    "--source-manifest",
                    str(manifest_path),
                    "--request",
                    str(request_path),
                    "--source-kind",
                    "native_photos",
                    "--shuffle-count",
                    "2",
                    "--mode",
                    "development",
                    "--source-root",
                    str(source),
                    "--toolchain-root",
                    str(toolchain),
                    "--adapter",
                    str(adapter),
                    "--state-root",
                    str(state),
                    "--run-parent",
                    str(runs),
                    "--group-id",
                    "cli-private-fixture",
                    "--timeout-seconds",
                    "10",
                ]

            one_state = root / "one-state"
            one_runs = root / "one-runs"
            one = subprocess.run(
                [
                    "python3",
                    "scripts/benchmark/photo_permutation_producer.py",
                    "run-one",
                    *runtime_arguments(one_state, one_runs),
                    "--index",
                    "0",
                ],
                cwd=repository,
                check=True,
                text=True,
                capture_output=True,
            )
            self.assertEqual(json.loads(one.stdout)["variant_id"], "canonical")
            self.assertEqual(list(one_runs.iterdir()), [])

            group_state = root / "group-state"
            group_runs = root / "group-runs"
            group_command = [
                "python3",
                "scripts/benchmark/photo_permutation_producer.py",
                "run-group",
                *runtime_arguments(group_state, group_runs),
            ]
            first_group = subprocess.run(
                group_command,
                cwd=repository,
                check=True,
                text=True,
                capture_output=True,
            )
            group = json.loads(first_group.stdout)
            self.assertEqual(group["expected_variant_count"], 3)
            self.assertEqual(
                [variant["variant_id"] for variant in group["variants"]],
                ["canonical", "shuffle-01", "shuffle-02"],
            )
            self.assertEqual(list(group_runs.iterdir()), [])
            self.assertEqual(len(invocations.read_text().splitlines()), 4)

            resumed = subprocess.run(
                group_command,
                cwd=repository,
                check=True,
                text=True,
                capture_output=True,
            )
            self.assertEqual(json.loads(resumed.stdout), group)
            self.assertEqual(len(invocations.read_text().splitlines()), 4)

            adapter.write_text(adapter.read_text() + "\n# changed adapter\n")
            adapter.chmod(0o755)
            mismatched = subprocess.run(
                group_command,
                cwd=repository,
                check=False,
                text=True,
                capture_output=True,
            )
            self.assertNotEqual(mismatched.returncode, 0)
            self.assertIn("group contract mismatch", mismatched.stderr)
            self.assertEqual(len(invocations.read_text().splitlines()), 4)
            self.assertEqual(list(group_runs.iterdir()), [])

    def test_cli_rejects_overlapping_state_before_writing_or_chmodding_source(
        self,
    ) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            source = root / "source"
            source.mkdir(mode=0o750)
            files = {"a.JPG": b"a", "b.JPG": b"b"}
            for name, contents in files.items():
                (source / name).write_bytes(contents)
            manifest = root / "manifest.json"
            manifest.write_text(json.dumps(source_manifest(files)))
            request_path = root / "request.json"
            request_path.write_text(json.dumps(request(2)))
            toolchain = root / "toolchain"
            toolchain.mkdir()
            (toolchain / ".easysplat_toolchain_state.json").write_bytes(b"receipt")
            adapter = root / "adapter"
            adapter.write_text("#!/bin/sh\nexit 1\n")
            adapter.chmod(0o755)
            overlapping_state = source / ".evidence"
            source_mode = stat.S_IMODE(source.stat().st_mode)
            completed = subprocess.run(
                [
                    "python3",
                    "scripts/benchmark/photo_permutation_producer.py",
                    "run-one",
                    "--source-manifest",
                    str(manifest),
                    "--request",
                    str(request_path),
                    "--source-kind",
                    "native_photos",
                    "--shuffle-count",
                    "2",
                    "--source-root",
                    str(source),
                    "--toolchain-root",
                    str(toolchain),
                    "--adapter",
                    str(adapter),
                    "--state-root",
                    str(overlapping_state),
                    "--run-parent",
                    str(root / "runs"),
                    "--group-id",
                    "overlap-fixture",
                    "--index",
                    "0",
                ],
                cwd=Path(__file__).resolve().parents[3],
                check=False,
                text=True,
                capture_output=True,
            )
            self.assertNotEqual(completed.returncode, 0)
            self.assertIn("must not overlap", completed.stderr)
            self.assertFalse(overlapping_state.exists())
            self.assertEqual(stat.S_IMODE(source.stat().st_mode), source_mode)
            self.assertEqual((source / "a.JPG").read_bytes(), b"a")

    def test_case_alias_cannot_hide_state_inside_the_source_directory(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            source = root / "source"
            source.mkdir(mode=0o700)
            alias = root / "SOURCE"
            if not alias.exists() or alias.stat().st_ino != source.stat().st_ino:
                self.skipTest("fixture volume is case-sensitive")
            request_path = root / "request.json"
            request_path.write_text("{}")
            adapter = root / "adapter"
            adapter.write_text("#!/bin/sh\nexit 0\n")
            adapter.chmod(0o755)
            toolchain = root / "toolchain"
            toolchain.mkdir()

            with self.assertRaisesRegex(producer.ProducerError, "must not overlap"):
                producer.validate_runtime_path_separation(
                    source_root=source,
                    state_root=alias / ".evidence",
                    run_parent=root / "runs",
                    toolchain_root=toolchain,
                    request_path=request_path,
                    adapter=adapter,
                )
            self.assertFalse((source / ".evidence").exists())

    def test_inventory_output_case_alias_cannot_escape_source_exclusion(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            source = root / "source"
            source.mkdir(mode=0o700)
            alias = root / "SOURCE"
            if not alias.exists() or alias.stat().st_ino != source.stat().st_ino:
                self.skipTest("fixture volume is case-sensitive")
            manifest = source_manifest({"a.JPG": b"a", "b.JPG": b"b"})
            output = alias / "inventory.json"

            with self.assertRaisesRegex(
                producer.ProducerError, "outside the source root"
            ):
                producer.write_new_inventory_manifest(
                    output,
                    manifest,
                    source_root=source,
                )
            self.assertFalse((source / "inventory.json").exists())

    def test_prospective_unicode_equivalent_directories_are_treated_as_overlapping(
        self,
    ) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            first = producer._directory_location(root / "caf\u00e9-state", "first")
            second = producer._directory_location(root / "cafe\u0301-state", "second")

            self.assertTrue(producer._directory_locations_overlap(first, second))

    def test_sigterm_terminates_adapter_group_and_cleans_registered_run(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            source = root / "source"
            source.mkdir()
            files = {"a.JPG": b"a", "b.JPG": b"b"}
            for name, contents in files.items():
                (source / name).write_bytes(contents)
            manifest = root / "manifest.json"
            manifest.write_text(json.dumps(source_manifest(files)))
            request_path = root / "request.json"
            request_path.write_text(json.dumps(request(2)))
            toolchain = root / "toolchain"
            toolchain.mkdir()
            (toolchain / ".easysplat_toolchain_state.json").write_bytes(b"receipt")
            started = root / "adapter-started.json"
            adapter = root / "slow-adapter.py"
            adapter.write_text(
                """#!/usr/bin/python3
import json
import pathlib
import subprocess
import time
child = subprocess.Popen(["/bin/sleep", "60"])
pathlib.Path("""
                + repr(str(started))
                + """).write_text(json.dumps({"child_pid": child.pid}))
time.sleep(60)
"""
            )
            adapter.chmod(0o755)
            state = root / "state"
            runs = root / "runs"
            command = [
                "python3",
                "scripts/benchmark/photo_permutation_producer.py",
                "run-one",
                "--source-manifest",
                str(manifest),
                "--request",
                str(request_path),
                "--source-kind",
                "native_photos",
                "--shuffle-count",
                "2",
                "--source-root",
                str(source),
                "--toolchain-root",
                str(toolchain),
                "--adapter",
                str(adapter),
                "--state-root",
                str(state),
                "--run-parent",
                str(runs),
                "--group-id",
                "signal-fixture",
                "--index",
                "0",
            ]
            process = subprocess.Popen(
                command,
                cwd=Path(__file__).resolve().parents[3],
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
            )
            for _ in range(400):
                if started.exists():
                    break
                if process.poll() is not None:
                    break
                time.sleep(0.01)
            self.assertTrue(started.exists())
            child_pid = json.loads(started.read_text())["child_pid"]
            os.kill(process.pid, signal.SIGTERM)
            _, stderr = process.communicate(timeout=15)
            self.assertEqual(process.returncode, 130, stderr)
            self.assertEqual(list(runs.iterdir()), [])
            ownership = state / "run-ownership"
            self.assertTrue(ownership.is_dir())
            self.assertEqual(list(ownership.iterdir()), [])
            for _ in range(100):
                try:
                    os.kill(child_pid, 0)
                except ProcessLookupError:
                    break
                time.sleep(0.01)
            with self.assertRaises(ProcessLookupError):
                os.kill(child_pid, 0)

    def test_successful_adapter_cannot_leave_a_background_process_group(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            child_receipt = root / "child.json"
            adapter = root / "background-adapter.py"
            adapter.write_text(
                """#!/usr/bin/python3
import json
import pathlib
import subprocess
child = subprocess.Popen(["/bin/sleep", "60"])
pathlib.Path("""
                + repr(str(child_receipt))
                + """).write_text(json.dumps({"child_pid": child.pid}))
"""
            )
            adapter.chmod(0o755)

            producer._run_geometry_adapter(
                [str(adapter)],
                run_root=root,
                timeout_seconds=10,
            )

            child_pid = json.loads(child_receipt.read_text())["child_pid"]
            for _ in range(100):
                try:
                    os.kill(child_pid, 0)
                except ProcessLookupError:
                    break
                time.sleep(0.01)
            try:
                os.kill(child_pid, 0)
            except ProcessLookupError:
                pass
            else:
                os.kill(child_pid, signal.SIGKILL)
                self.fail("successful adapter left a background child alive")

    def test_successful_adapter_cannot_leave_a_detached_descendant(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            child_receipt = root / "detached-child.json"
            adapter = root / "detached-adapter.py"
            adapter.write_text(
                """#!/usr/bin/python3
import json
import pathlib
import subprocess
import time
child = subprocess.Popen(["/bin/sleep", "60"], start_new_session=True)
pathlib.Path("""
                + repr(str(child_receipt))
                + """).write_text(json.dumps({"child_pid": child.pid}))
time.sleep(0.25)
"""
            )
            adapter.chmod(0o755)

            producer._run_geometry_adapter(
                [str(adapter)],
                run_root=root,
                timeout_seconds=10,
            )

            child_pid = json.loads(child_receipt.read_text())["child_pid"]
            for _ in range(100):
                try:
                    os.kill(child_pid, 0)
                except ProcessLookupError:
                    break
                time.sleep(0.01)
            try:
                os.kill(child_pid, 0)
            except ProcessLookupError:
                pass
            else:
                os.kill(child_pid, signal.SIGKILL)
                self.fail("successful adapter left a detached descendant alive")

    def test_formal_lane_rejects_uncontained_adapter_before_it_can_fork(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            launched = root / "launched"
            adapter = root / "escape-adapter.py"
            adapter.write_text(
                "#!/usr/bin/python3\n"
                "import pathlib\n"
                f"pathlib.Path({str(launched)!r}).write_text('launched')\n"
            )
            adapter.chmod(0o755)

            with self.assertRaisesRegex(
                producer.ProducerUnavailable,
                "formal_execution_authority_unavailable",
            ):
                producer._run_geometry_adapter(
                    [str(adapter)],
                    run_root=root,
                    timeout_seconds=10,
                    formal_release=True,
                )
            self.assertFalse(launched.exists())

    def test_release_cli_fails_before_reading_media_without_root_authority(
        self,
    ) -> None:
        missing = "/private/easysplat-formal-authority-must-precede-media"
        completed = subprocess.run(
            [
                "python3",
                "scripts/benchmark/photo_permutation_producer.py",
                "run-group",
                "--source-manifest",
                f"{missing}/manifest.json",
                "--request",
                f"{missing}/request.json",
                "--source-kind",
                "native_photos",
                "--mode",
                "release",
                "--shuffle-count",
                "19",
                "--source-root",
                f"{missing}/media",
                "--toolchain-root",
                f"{missing}/toolchain",
                "--adapter",
                f"{missing}/adapter",
                "--state-root",
                f"{missing}/state",
                "--run-parent",
                f"{missing}/runs",
                "--group-id",
                "formal-preflight",
            ],
            cwd=Path(__file__).resolve().parents[3],
            check=False,
            text=True,
            capture_output=True,
        )

        self.assertEqual(completed.returncode, 1)
        self.assertIn(
            "formal_execution_authority_unavailable",
            completed.stderr,
        )
        self.assertNotIn("manifest", completed.stderr)

    def test_fresh_executor_resumes_published_canonical_without_rerunning_adapter(
        self,
    ) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            source = root / "source"
            source.mkdir()
            files = {"IMG_1.JPG": b"photo-a", "IMG_2.JPG": b"photo-b"}
            for name, contents in files.items():
                (source / name).write_bytes(contents)
            manifest = source_manifest(files)
            request_value = request(2)
            request_path = root / "request.json"
            request_path.write_text(json.dumps(request_value))
            toolchain = root / "toolchain"
            toolchain.mkdir()
            (toolchain / ".easysplat_toolchain_state.json").write_bytes(
                b"fixture-receipt"
            )
            state = root / "state"
            runs = root / "runs"
            runs.mkdir(mode=0o700)
            invocations = root / "invocations.txt"
            adapter = root / "fake-adapter.py"
            write_fake_adapter(adapter, invocations)
            runtime_context = producer.capture_runtime_group_context(
                manifest=manifest,
                source_root=source,
                request=request_value,
                request_path=request_path,
                group_id="private-fixture-group",
                source_kind="native_photos",
                mode="development",
                shuffle_count=2,
                adapter=adapter,
                toolchain_root=toolchain,
            )
            runtime_contract = runtime_context.contract
            contract_digest = producer.ensure_group_contract(state, runtime_contract)
            bound_toolchain = producer.prepare_bound_toolchain(
                runtime_context,
                state_root=state,
                group_contract_sha256=contract_digest,
            )

            public_variants = []
            for _ in range(2):
                public = producer.execute_fresh_variant(
                    producer.VariantSpec("canonical", 0, 0),
                    manifest=manifest,
                    source_root=source,
                    request=request_value,
                    request_path=request_path,
                    toolchain_root=toolchain,
                    adapter=adapter,
                    state_root=state,
                    run_parent=runs,
                    source_kind="native_photos",
                    group_id="private-fixture-group",
                    group_contract=runtime_contract,
                    runtime_context=runtime_context,
                    bound_toolchain=bound_toolchain,
                    timeout_seconds=10,
                )
                public_variants.append(public)
                self.assertEqual(public["registered_views"], 2)
                self.assertEqual(list(runs.iterdir()), [])

            project_roots = invocations.read_text().splitlines()
            self.assertEqual(public_variants[0], public_variants[1])
            self.assertEqual(len(project_roots), 1)
            self.assertEqual(len(set(project_roots)), 1)
            self.assertTrue(
                all(
                    Path(path).name == "project.easysplatproj" for path in project_roots
                )
            )
            self.assertEqual((source / "IMG_1.JPG").read_bytes(), b"photo-a")
            self.assertEqual(
                stat.S_IMODE((state / ".opaque-content-key").stat().st_mode), 0o600
            )

    def test_bound_toolchain_recovers_a_published_directory_without_its_receipt(
        self,
    ) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            source = root / "source"
            source.mkdir()
            files = {"a.JPG": b"a", "b.JPG": b"b"}
            for name, contents in files.items():
                (source / name).write_bytes(contents)
            request_value = request(2)
            request_path = root / "request.json"
            request_path.write_text(json.dumps(request_value))
            adapter = root / "adapter"
            adapter.write_text("#!/bin/sh\nexit 0\n")
            adapter.chmod(0o755)
            toolchain = root / "toolchain"
            (toolchain / "bin").mkdir(parents=True)
            (toolchain / "bin/colmap").write_bytes(b"colmap")
            context = producer.capture_runtime_group_context(
                manifest=source_manifest(files),
                source_root=source,
                request=request_value,
                request_path=request_path,
                group_id="toolchain-recovery",
                source_kind="native_photos",
                mode="development",
                shuffle_count=2,
                adapter=adapter,
                toolchain_root=toolchain,
            )
            state = root / "state"
            contract_digest = producer.ensure_group_contract(state, context.contract)
            first = producer.prepare_bound_toolchain(
                context,
                state_root=state,
                group_contract_sha256=contract_digest,
            )
            (state / "bound-toolchain.json").unlink()

            recovered = producer.prepare_bound_toolchain(
                context,
                state_root=state,
                group_contract_sha256=contract_digest,
            )

            self.assertEqual(recovered.closure_sha256, first.closure_sha256)
            self.assertTrue((state / "bound-toolchain.json").is_file())

    def test_sigterm_during_bound_toolchain_staging_leaves_no_transaction(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            source = root / "source"
            source.mkdir()
            files = {"a.JPG": b"a", "b.JPG": b"b"}
            for name, contents in files.items():
                (source / name).write_bytes(contents)
            manifest = root / "manifest.json"
            manifest.write_text(json.dumps(source_manifest(files)))
            request_path = root / "request.json"
            request_path.write_text(json.dumps(request(2)))
            adapter = root / "adapter"
            adapter.write_text("#!/bin/sh\nexit 0\n")
            adapter.chmod(0o755)
            toolchain = root / "toolchain"
            toolchain.mkdir()
            (toolchain / "colmap").write_bytes(b"colmap")
            state = root / "state"
            runs = root / "runs"
            argv = [
                "photo_permutation_producer.py",
                "run-one",
                "--source-manifest",
                str(manifest),
                "--request",
                str(request_path),
                "--source-kind",
                "native_photos",
                "--shuffle-count",
                "2",
                "--source-root",
                str(source),
                "--toolchain-root",
                str(toolchain),
                "--adapter",
                str(adapter),
                "--state-root",
                str(state),
                "--run-parent",
                str(runs),
                "--group-id",
                "staging-signal",
                "--index",
                "0",
            ]

            def interrupt_clone(*_args: object, **_kwargs: object) -> None:
                os.kill(os.getpid(), signal.SIGTERM)

            with (
                mock.patch.object(sys, "argv", argv),
                mock.patch.object(
                    producer, "_fclonefileat", side_effect=interrupt_clone
                ),
            ):
                self.assertEqual(producer.main(), 130)

            self.assertFalse((state / producer.BOUND_TOOLCHAIN_TRANSACTION).exists())
            self.assertFalse((state / "bound-toolchain").exists())
            self.assertEqual(
                list(state.glob(".bound-toolchain-*")),
                [],
            )

    def test_adapter_cannot_substitute_artifacts_from_an_external_cached_project(
        self,
    ) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            source = root / "source"
            source.mkdir()
            files = {"IMG_1.JPG": b"photo-a", "IMG_2.JPG": b"photo-b"}
            for name, contents in files.items():
                (source / name).write_bytes(contents)
            external_project = root / "cached-project"
            external_envelope = write_geometry_project(
                external_project,
                ["photo-000001.jpg", "photo-000002.jpg"],
            )
            envelope_path = root / "external-envelope.json"
            envelope_path.write_text(json.dumps(external_envelope))
            adapter = root / "substituting-adapter.py"
            adapter.write_text(
                """#!/usr/bin/python3
import pathlib
import sys
arguments = dict(zip(sys.argv[1::2], sys.argv[2::2]))
pathlib.Path(arguments["--project-root"]).mkdir()
pathlib.Path(arguments["--output"]).write_bytes(pathlib.Path("""
                + repr(str(envelope_path))
                + """).read_bytes())
"""
            )
            adapter.chmod(0o755)
            request_value = request(2)
            request_path = root / "request.json"
            request_path.write_text(json.dumps(request_value))
            toolchain = root / "toolchain"
            toolchain.mkdir()
            (toolchain / ".easysplat_toolchain_state.json").write_bytes(b"receipt")
            state = root / "state"
            runs = root / "runs"
            runs.mkdir(mode=0o700)
            context = producer.capture_runtime_group_context(
                manifest=source_manifest(files),
                source_root=source,
                request=request_value,
                request_path=request_path,
                group_id="external-cache-fixture",
                source_kind="native_photos",
                mode="development",
                shuffle_count=2,
                adapter=adapter,
                toolchain_root=toolchain,
            )
            contract_digest = producer.ensure_group_contract(state, context.contract)
            bound = producer.prepare_bound_toolchain(
                context,
                state_root=state,
                group_contract_sha256=contract_digest,
            )

            with self.assertRaisesRegex(
                producer.ProducerUnavailable, "adapter_envelope_invalid"
            ):
                producer.execute_fresh_variant(
                    producer.VariantSpec("canonical", 0, 0),
                    manifest=source_manifest(files),
                    source_root=source,
                    request=request_value,
                    request_path=request_path,
                    toolchain_root=toolchain,
                    adapter=adapter,
                    state_root=state,
                    run_parent=runs,
                    source_kind="native_photos",
                    group_id="external-cache-fixture",
                    group_contract=context.contract,
                    runtime_context=context,
                    bound_toolchain=bound,
                    timeout_seconds=10,
                )
            self.assertEqual(list(runs.iterdir()), [])


if __name__ == "__main__":
    unittest.main()
