from __future__ import annotations

import hashlib
import json
import os
import stat
import subprocess
import sys
import tempfile
import textwrap
import types
import unittest
from pathlib import Path
from unittest import mock

from scripts.benchmark import mapper_cadence_request as request_contract
from scripts.benchmark import run_mapper_cadence_ab as supervisor


REPOSITORY_ROOT = Path(__file__).resolve().parents[3]
SUPERVISOR = REPOSITORY_ROOT / "scripts/benchmark/run_mapper_cadence_ab.py"


def digest(label: str) -> str:
    return hashlib.sha256(label.encode("utf-8")).hexdigest()


def runtime_closure_digest(root: Path) -> str:
    components = (
        ("bin/colmap", hashlib.sha256((root / "bin/colmap").read_bytes()).hexdigest()),
        (
            "lib/libomp.dylib",
            hashlib.sha256((root / "lib/libomp.dylib").read_bytes()).hexdigest(),
        ),
    )
    hasher = hashlib.sha256()

    def add(value: bytes) -> None:
        hasher.update(len(value).to_bytes(8, "big"))
        hasher.update(value)

    add(b"easysplat-colmap-runtime-closure-v1")
    for relative_path, sha256 in components:
        add(relative_path.encode("utf-8"))
        add(sha256.encode("utf-8"))
    return hasher.hexdigest()


def candidate_configuration() -> dict[str, object]:
    return {
        "detail_profile": "balanced",
        "selected_frame_count": 30,
        "capture_path": "automatic",
        "input_topology": "continuous",
        "camera_grouping": "automatic",
        "lens_projection": "automatic",
        "resource_policy": "maximum_performance",
        "compute_policy": "metal_for_supported_stages",
        "pairing_policy": "generic_continuous",
        "temporal_pairing": "multiscale",
        "temporal_offsets": [1, 2, 4, 8, 16],
        "vocabulary_candidate_count": 0,
        "vocabulary_returned_neighbor_count": 0,
        "vocabulary_query_stride": 10,
        "descriptor_matcher": "faiss",
        "ba_global_frames_ratio": 1.4,
        "ba_global_points_ratio": 1.4,
        "ba_global_max_refinements": 5,
        "ba_local_max_refinements": 2,
        "ba_local_max_num_iterations": 10,
        "ba_local_function_tolerance": 0.001,
        "ba_global_function_tolerance": 0.000001,
        "ba_local_num_images": 6,
        "trainer_iterations": 7_000,
        "trainer_plateau_window": 800,
        "feature_extraction_workers": 12,
        "coupled_matching_workers": 8,
        "vocabulary_retrieval_workers": 8,
        "maximum_concurrent_video_source_analysis_tasks": 4,
        "run_seed": 42,
    }


def fixed_mapper_options() -> dict[str, object]:
    return {
        "local_max_refinements": 2,
        "global_max_refinements": 5,
        "global_max_num_iterations": 100,
        "local_max_num_iterations": 10,
        "local_function_tolerance": 0.001,
        "global_function_tolerance": 0.000001,
        "local_image_count": 6,
        "random_seed": 42,
        "refine_focal_length": True,
        "minimum_pair_inlier_count": 15,
    }


def repeatability_trial(
    ordinal: int,
    elapsed_seconds: float,
    *,
    cadence: str = "balanced-global",
    registered_image_names: list[str] | None = None,
    topology_digest: str | None = None,
) -> dict[str, object]:
    names = registered_image_names or [
        f"frame-{index:03}.jpg" for index in range(1, 31)
    ]
    return {
        "trial_name": f"trial-{ordinal}",
        "mapper_cadence": cadence,
        "mapping_elapsed_seconds": elapsed_seconds,
        "registered_views": len(names),
        "registered_image_names": names,
        "point_track_topology_digest": topology_digest or digest("stable-topology"),
        "point_count": 100,
        "observation_count": 300,
        "median_residual_pixels": 0.5,
        "p90_residual_pixels": 1.0,
        "conditioning_status": "accepted",
        "camera_poses_wxyz_xyz": [
            [1.0, 0.0, 0.0, 0.0, float(index % 6), float(index // 6), 0.0]
            for index in range(len(names))
        ],
    }


FAKE_ADAPTER = r'''#!/usr/bin/env python3
from __future__ import annotations

import hashlib
import json
import os
import subprocess
import sys
from pathlib import Path


def digest(label: str) -> str:
    return hashlib.sha256(label.encode("utf-8")).hexdigest()


def canonical_digest(value: object) -> str:
    payload = json.dumps(value, sort_keys=True, separators=(",", ":")).encode("utf-8")
    return hashlib.sha256(payload).hexdigest()


def execution_assurance() -> dict[str, object]:
    return {
        "level": "observational",
        "mutation_threat_model": "no_concurrent_same_uid_mutation",
        "runner_isolation_mode": "owner_private_local_process",
        "child_database_binding": "pre_post_descriptor_path",
        "child_database_open_inode_verified": False,
        "child_runtime_binding": "pre_post_closure_path",
        "child_runtime_exec_inode_verified": False,
        "release_gate_eligible": False,
    }


def arguments() -> dict[str, str]:
    tail = sys.argv[1:]
    if len(tail) % 2:
        raise SystemExit(91)
    return dict(zip(tail[::2], tail[1::2], strict=True))


def append_call() -> int:
    log = Path(os.environ["FAKE_ADAPTER_LOG"])
    prior = []
    if log.exists():
        prior = log.read_text(encoding="utf-8").splitlines()
    with log.open("a", encoding="utf-8") as stream:
        stream.write(json.dumps(sys.argv[1:], separators=(",", ":")) + "\n")
    return len(prior)


def matching_envelope(values: dict[str, str], matching_index: int) -> dict[str, object]:
    scenario = os.environ.get("FAKE_ADAPTER_SCENARIO", "success")
    request = json.loads(Path(values["--request"]).read_text(encoding="utf-8"))
    runtime = request["runtime_closure"]
    build = request["build_identity"]
    experiment = request["experiment"]
    pair_digest = digest("pairs")
    if scenario == "bootstrap_mismatch" and matching_index == 1:
        pair_digest = digest("different-pairs")
    selection_sha256 = digest("selection")
    feature_database_digest = digest("feature-db")
    if scenario == "selection_mismatch" and matching_index == 1:
        selection_sha256 = digest("different-selection")
    if scenario == "logical_database_mismatch" and matching_index == 1:
        feature_database_digest = digest("different-feature-db")
    pipeline_log = "Logs/pipeline.log"
    if scenario == "artifact_layout_mismatch" and matching_index == 1:
        pipeline_log = "Logs/different-pipeline.log"
    database_path = str(Path(values["--project-root"]) / "SfM/colmap/database.db")
    database_device_id = Path(values["--project-root"]).parent.stat().st_dev
    selected_image_names = [f"frame-{index:03}.jpg" for index in range(1, 31)]
    if scenario == "foreign_database" and matching_index == 0:
        database_path = str(Path(values["--project-root"]).parent / "foreign.db")
    colmap_compute_mode = "gpu"
    fallback_reasons: list[str] = []
    recovery_level = "normal"
    rejected_vocabulary_retrieval_history: list[dict[str, object]] = []
    if scenario == "compute_mode_mismatch" and matching_index == 1:
        colmap_compute_mode = "cpu"
    if scenario == "fallback_history_mismatch" and matching_index == 1:
        fallback_reasons = ["normal graph rejected"]
        recovery_level = "expanded"
    if scenario == "rejected_retrieval_mismatch" and matching_index == 1:
        rejected_vocabulary_retrieval_history = [
            {
                "retrieval_attempt_ordinal": 1,
                "pair_attempt_ordinal": 1,
                "pairing_policy": "segmented_mixed",
                "recovery_level": "normal",
                "selected_view_count": 30,
                "query_count": 1,
                "no_ranked_neighbor_query_count": 1,
                "candidate_count": 20,
                "returned_neighbor_count": 8,
                "retrieval_request_digest": digest("retrieval-request"),
                "retrieval_output_digest": digest("retrieval-output"),
            }
        ]
    envelope: dict[str, object] = {
        "schema_version": (
            3.0 if scenario == "floating_matching_schema" and matching_index == 0 else 3
        ),
        "measurement_scope": "matching_only",
        "variant": "candidate",
        "started_monotonic_seconds": 10.0 + matching_index,
        "ended_monotonic_seconds": 11.0 + matching_index,
        "project_root": values["--project-root"],
        "database_path": database_path,
        "database_project_relative_path": "SfM/colmap/database.db",
        "selection_manifest": "Frames/selected_frames.json",
        "selection_manifest_sha256": selection_sha256,
        "pair_graph_evidence": "SfM/pair_graph_evidence.json",
        "pair_graph_evidence_sha256": digest(f"pair-evidence-{matching_index}"),
        "pair_graph_schema_version": 4,
        "worker_execution": "SfM/worker_execution.json",
        "worker_execution_sha256": digest(f"worker-{matching_index}"),
        "worker_execution_schema_version": 2,
        "pipeline_log": pipeline_log,
        "request_sha256": hashlib.sha256(
            Path(values["--request"]).read_bytes()
        ).hexdigest(),
        "execution_assurance": execution_assurance(),
        "evidence_class": request["evidence_class"],
        "request_kind": request["request_kind"],
        "source_provenance_scope": build["source_provenance_scope"],
        "source_tree_state": build["source_tree_state"],
        "toolchain_provenance_status": runtime["toolchain_provenance_status"],
        "adapter_executable_bytes": runtime["adapter_executable_bytes"],
        "adapter_executable_sha256": runtime["adapter_executable_sha256"],
        "fixed_mapper_options": experiment["fixed_mapper_options"],
        "fixed_mapper_options_sha256": experiment["fixed_mapper_options_sha256"],
        "cadence_schedule_sha256": experiment["cadence_schedule_sha256"],
        "quality_thresholds_sha256": experiment["quality_thresholds_sha256"],
        "experiment_contract_sha256": experiment["experiment_contract_sha256"],
        "resolved_plan_binding_sha256": digest("plan"),
        "deterministic_seed": 42,
        "colmap_runtime_closure_sha256": request["runtime_closure"][
            "colmap_runtime_closure_sha256"
        ],
        "database_file_sha256": digest(f"database-{matching_index}"),
        "database_file_bytes": 4096,
        "database_source_device_id": database_device_id,
        "database_source_inode": 750 + matching_index,
        "database_source_mode": 0o100400,
        "selected_frames_digest": digest("frames"),
        "selected_image_count": len(selected_image_names),
        "selected_image_names": selected_image_names,
        "pairing_policy": "segmented_mixed",
        "pair_attempt_ordinal": 1,
        "pair_list_digest": pair_digest,
        "descriptor_matcher": "faiss",
        "colmap_compute_mode": colmap_compute_mode,
        "fallback_reasons": fallback_reasons,
        "recovery_level": recovery_level,
        "exact_recovery_reason": None,
        "rejected_vocabulary_retrieval_count": len(
            rejected_vocabulary_retrieval_history
        ),
        "rejected_vocabulary_retrieval_history": (
            rejected_vocabulary_retrieval_history
        ),
        "feature_database_digest": feature_database_digest,
        "matching_database_digest": digest("matching-db"),
        "scheduled_pair_count": 29,
        "attempted_pair_count": 29,
        "raw_matched_pair_count": 29,
        "spatially_verified_pair_count": 29,
        "local_pair_count": 29,
        "retrieval_pair_count": 0,
        "loop_revisit_pair_count": 0,
        "connected_component_count": 1,
        "component_view_counts": [len(selected_image_names)],
        "isolated_view_count": 0,
        "descriptorless_view_count": 0,
        "articulation_view_count": 0,
        "biconnected_block_count": 1,
        "largest_biconnected_block_view_count": len(selected_image_names),
        "second_largest_biconnected_block_view_count": 0,
        "degree_p10": 2,
        "degree_median": 2,
        "degree_p90": 2,
        "feature_invocation_count": 1,
        "matching_invocation_count": 1,
        "retrieval_invocation_count": 1,
        "matching_duration_seconds": 1.0 + matching_index,
        "pipeline_stage_seconds": {"sfmMatching": 1.0 + matching_index},
        "stage_seconds": {"end_to_end": 2.0 + matching_index},
        "peak_memory_bytes": 1_000_000 + matching_index,
    }
    if scenario == "matching_assurance_mismatch" and matching_index == 1:
        envelope["execution_assurance"] = {
            **execution_assurance(),
            "release_gate_eligible": True,
        }
    if scenario == "matching_assurance_boolean_as_integer" and matching_index == 1:
        envelope["execution_assurance"] = {
            **execution_assurance(),
            "release_gate_eligible": 0,
        }
    if scenario == "matching_provenance_mismatch" and matching_index == 1:
        envelope["source_tree_state"] = "clean"
    if scenario == "matching_unknown_field" and matching_index == 1:
        envelope["untrusted_note"] = "looks equivalent"
    return envelope


def trial_envelope(values: dict[str, str], call_index: int) -> dict[str, object]:
    trial_root = Path(values["--trial-root"])
    trial_name = trial_root.name
    ordinal = 0 if "warmup" in trial_name else int(trial_name.split("-")[2])
    cadence = values["--mapper-cadence"]
    ratio = 1.1 if cadence == "frequent-global" else 1.4
    checkpoint = json.loads(
        Path(values["--mapping-from-checkpoint"]).read_text(encoding="utf-8")
    )
    request = json.loads(Path(values["--request"]).read_text(encoding="utf-8"))
    experiment = request["experiment"]
    runtime = request["runtime_closure"]
    build = request["build_identity"]
    elapsed_by_ordinal = {
        0: 30.0,
        1: 10.0,
        2: 20.0,
        3: 22.0,
        4: 12.0,
        5: 14.0,
        6: 24.0,
        7: 26.0,
        8: 16.0,
    }
    scenario = os.environ.get("FAKE_ADAPTER_SCENARIO", "success")
    if scenario == "nonzero_exit" and call_index == 2:
        sys.stderr.write("discarded adapter prefix\n" + ("x" * 32768) + "\n")
        sys.stderr.write(
            "mapper failed: frozen database has live SQLite companion database.db-shm\n"
        )
        raise SystemExit(17)
    if scenario == "missing_trial" and call_index == 2:
        return {}
    destination_name = "database.db"
    inode = 10_000 + ordinal
    if scenario == "duplicate_inode" and ordinal == 2:
        inode = 10_001
    if scenario == "duplicate_path" and ordinal == 2:
        destination_name = "../mapper-cadence-01-1p1/database.db"
    if scenario == "symlink_escape" and ordinal == 1:
        (trial_root / "escape").symlink_to(trial_root.parent / "matching-decision")
        destination_name = "escape/database.db"
    if scenario == "extra_trial_directory" and ordinal == 1:
        extra = trial_root.parent / "mapper-cadence-99-extra"
        extra.mkdir(mode=0o700)
        (extra / "trial-envelope.json").write_text("{}", encoding="utf-8")
    request_sha256 = checkpoint["request_sha256"]
    if scenario == "tampered_closure" and ordinal == 1:
        request_sha256 = digest("tampered-request")
    trial_ordinal = ordinal
    if scenario == "duplicate_trial" and ordinal == 2:
        trial_ordinal = 1
    if scenario == "extra_trial" and ordinal == 1:
        trial_ordinal = 99
    if scenario == "boolean_trial_ordinal" and ordinal == 1:
        trial_ordinal = True
    wall = elapsed_by_ordinal[ordinal]
    if scenario == "timing_range_boundary" and ordinal in {2, 3, 6, 7}:
        wall = {2: 20.0, 3: 50.0, 6: 30.0, 7: 40.0}[ordinal]
    if scenario == "timing_range_over" and ordinal in {2, 3, 6, 7}:
        wall = {2: 20.0, 3: 50.000_001, 6: 30.0, 7: 40.0}[ordinal]
    if scenario == "retry3_timing_multimodality" and ordinal in {2, 3, 6, 7}:
        wall = {
            2: 63.481_024_7,
            3: 169.122_673_5,
            6: 164.954_239_3,
            7: 166.0,
        }[ordinal]
    if scenario == "invalid_metrics" and ordinal == 1:
        wall = 0.0
    if scenario == "schedule_ratio_mismatch" and ordinal == 1:
        ratio = 1.4
    median_residual_pixels = 0.5
    p90_residual_pixels = 1.0
    if scenario == "nontrivial_float_roundtrip":
        median_residual_pixels = 0.500_000_000_000_000_1
        p90_residual_pixels = 1.000_000_000_000_000_2
    if scenario == "absolute_residual_failure" and ordinal == 1:
        median_residual_pixels = 1.6
        p90_residual_pixels = 3.1
    registered_views = 30
    point_count = 100
    observation_count = 300
    poses: object = [
        [1.0, 0.0, 0.0, 0.0, float(index % 6), float(index // 6), 0.0]
        for index in range(registered_views)
    ]
    if scenario == "nontrivial_float_roundtrip":
        poses = [
            [
                1.0,
                0.0,
                0.0,
                0.0,
                float(index % 6) + 0.123_456_789_012_345_66,
                float(index // 6) + 1.234_567_890_123_456_7e-12,
                -4.940_656_458_412_465_4e-324,
            ]
            for index in range(registered_views)
        ]
    if scenario == "invalid_poses" and ordinal == 1:
        poses = [[0.0, 0.0]]
    if scenario == "quality_metric_mismatch" and ordinal == 1:
        registered_views = 29
        point_count = 90
        observation_count = 270
        poses = poses[:registered_views]
    registered_image_names = [
        f"frame-{index:03}.jpg" for index in range(1, registered_views + 1)
    ]
    if scenario == "within_arm_registered_set_mismatch" and ordinal == 7:
        registered_views = 29
        registered_image_names = registered_image_names[:registered_views]
        poses = poses[:registered_views]
        conditioning_measurement_registered_views = registered_views
    else:
        conditioning_measurement_registered_views = registered_views
    if scenario == "pose_name_mismatch" and ordinal == 1:
        registered_image_names = list(reversed(registered_image_names))
    conditioning_measurement: dict[str, object] = {
        "pointCount": point_count,
        "observationCount": observation_count,
        "positiveDepthObservationCount": observation_count,
        "stronglyMeasuredViewCount": conditioning_measurement_registered_views,
        "registeredViewCount": conditioning_measurement_registered_views,
        "perViewObservationMinimum": 50,
        "perViewObservationP10": 75,
        "perViewObservationMedian": 100.0,
        "perViewObservationP90": 125,
        "distinctTrackLengthMinimum": 2,
        "distinctTrackLengthP10": 2,
        "distinctTrackLengthMedian": 3.0,
        "distinctTrackLengthP90": 4,
        "pointsAtLeast1Point5Degrees": point_count,
        "pointsAtLeast2Degrees": point_count,
        "pointsAtLeast3Degrees": point_count,
        "observationsAtLeast1Point5Degrees": observation_count,
        "observationsAtLeast2Degrees": observation_count,
        "observationsAtLeast3Degrees": observation_count,
        "medianObservedDepth": 10.0,
        "cameraBaselineToMedianDepthRatio": 0.1,
        "effectiveCameraCenterCount": conditioning_measurement_registered_views,
        "largestCameraCenterClusterSize": 1,
        "cameraCenterMergeToleranceToMedianDepthRatio": 0.001,
        "numericallyConditionedPointCount": point_count,
        "numericallyConditionedObservationCount": observation_count,
        "adaptiveParallaxThresholdMedianDegrees": 0.1,
        "adaptiveParallaxThresholdP90Degrees": 0.2,
        "cameraCenterEigenvalues": [0.1, 0.3, 0.6],
        "pointEigenvalues": [0.1, 0.3, 0.6],
        "cameraPairEvaluationCount": conditioning_measurement_registered_views,
        "rayPairEvaluationCount": observation_count,
    }
    if scenario == "conditioning_extra_key" and ordinal == 1:
        conditioning_measurement["summary"] = "looks good"
    if scenario == "conditioning_boolean_count" and ordinal == 1:
        conditioning_measurement["pointCount"] = True
    if scenario == "conditioning_unsorted_eigenvalues" and ordinal == 1:
        conditioning_measurement["cameraCenterEigenvalues"] = [0.6, 0.1, 0.3]
    source_database_initial_evidence: dict[str, object] = {
        "source_name": "database.db",
        "parent_device_id": checkpoint["database_source_device_id"],
        "parent_inode": 500,
        "device_id": checkpoint["database_source_device_id"],
        "inode": checkpoint["database_source_inode"],
        "link_count": 1,
        "byte_count": 4096,
        "mode": 0o100400,
        "owner_uid": os.getuid(),
        "owner_gid": os.getgid(),
        "modified_seconds": 1_000,
        "modified_nanoseconds": 100,
        "changed_seconds": 1_000,
        "changed_nanoseconds": 200,
        "companion_names": [],
        "sha256": checkpoint["database_file_sha256"],
    }
    if scenario == "source_digest_mismatch" and ordinal == 1:
        source_database_initial_evidence["sha256"] = digest("tampered-master")
    if scenario == "source_writable_mode" and ordinal == 1:
        source_database_initial_evidence["mode"] = 0o100600
    if scenario == "source_changes_between_trials" and ordinal == 2:
        source_database_initial_evidence["parent_inode"] = 501
    if scenario == "source_sqlite_companion" and ordinal == 1:
        source_database_initial_evidence["companion_names"] = ["database.db-wal"]
    source_database_final_evidence = dict(source_database_initial_evidence)
    if scenario == "source_final_mismatch" and ordinal == 1:
        source_database_final_evidence["modified_nanoseconds"] = 101
    trial_root_status = trial_root.stat()
    clone_database_pre_run_evidence: dict[str, object] = {
        "trial_ordinal": trial_ordinal,
        "trial_name": trial_name,
        "destination_name": destination_name,
        "destination_parent_device_id": trial_root_status.st_dev,
        "destination_parent_inode": trial_root_status.st_ino,
        "clone_strategy": "apfs_clone",
        "destination_device_id": trial_root_status.st_dev,
        "destination_inode": inode,
        "destination_link_count": 1,
        "destination_byte_count": 4096,
        "destination_mode": 0o100600,
        "destination_owner_uid": os.getuid(),
        "destination_owner_gid": os.getgid(),
        "destination_modified_seconds": 1_100,
        "destination_modified_nanoseconds": 100,
        "destination_changed_seconds": 1_100,
        "destination_changed_nanoseconds": 200,
        "destination_sha256": checkpoint["database_file_sha256"],
    }
    if scenario == "clone_before_mismatch" and ordinal == 1:
        clone_database_pre_run_evidence["destination_sha256"] = digest(
            "wrong-clone-before"
        )
    if scenario == "clone_float_byte_count" and ordinal == 1:
        clone_database_pre_run_evidence["destination_byte_count"] = 4096.0
    if scenario == "clone_strategy_fallback" and ordinal == 1:
        clone_database_pre_run_evidence["clone_strategy"] = "descriptor_copy"
    if scenario == "clone_readonly_mode" and ordinal == 1:
        clone_database_pre_run_evidence["destination_mode"] = 0o100400
    if scenario == "clone_parent_identity_mismatch" and ordinal == 1:
        clone_database_pre_run_evidence["destination_parent_inode"] = (
            trial_root_status.st_ino + 1
        )
    if scenario == "clone_file_device_mismatch" and ordinal == 1:
        clone_database_pre_run_evidence["destination_device_id"] = (
            trial_root_status.st_dev + 1
        )
    clone_database_post_run_evidence = {
        key: value
        for key, value in clone_database_pre_run_evidence.items()
        if key not in {"trial_ordinal", "trial_name", "clone_strategy"}
    }
    if scenario == "clone_mutates":
        clone_database_post_run_evidence.update(
            {
                "destination_byte_count": 4_096 + ordinal + 1,
                "destination_modified_nanoseconds": 300 + ordinal,
                "destination_changed_nanoseconds": 400 + ordinal,
                "destination_sha256": digest(f"mapped-clone-{ordinal}"),
            }
        )
    if scenario == "post_identity_mismatch" and ordinal == 1:
        clone_database_post_run_evidence["destination_inode"] = inode + 1
    trial_fixed_options = dict(experiment["fixed_mapper_options"])
    fixed_options_sha256 = experiment["fixed_mapper_options_sha256"]
    if scenario == "fixed_options_value_mismatch" and ordinal == 1:
        trial_fixed_options["minimum_pair_inlier_count"] = 16
    if scenario == "fixed_options_digest_mismatch" and ordinal == 1:
        fixed_options_sha256 = digest("wrong-fixed-options")
    model_hashes = {
        "cameras.txt": digest(f"cameras-{ordinal}"),
        "images.txt": digest(f"images-{ordinal}"),
        "points3D.txt": digest(f"points-{ordinal}"),
    }
    point_track_topology_digest = digest("stable-point-track-topology")
    if scenario == "within_arm_topology_mismatch" and ordinal == 7:
        point_track_topology_digest = digest("different-point-track-topology")
    mapper_log_lines = [
        "I20260102 03:04:00.000000 0xabc mapper.cc:7] Loading database",
        "I20260102 03:04:01.000000 0xabc mapper.cc:7] Keeping successful reconstruction",
        "I20260102 03:04:02.000000 0xabc mapper.cc:7] Elapsed time: 0.033 [minutes]",
    ]
    mapper_log_data = ("\n".join(mapper_log_lines) + "\n").encode("utf-8")
    mapper_log_path = trial_root / "mapper.log"
    mapper_log_path.write_bytes(mapper_log_data)
    envelope: dict[str, object] = {
        "schema_version": (
            3.0
            if scenario == "floating_trial_schema" and ordinal == 1
            else 2
            if scenario == "stale_trial_schema" and ordinal == 1
            else 3
        ),
        "measurement_scope": "mapping_cadence_trial",
        "trial_name": trial_name,
        "trial_ordinal": trial_ordinal,
        "discarded": ordinal == 0,
        "mapper_cadence": cadence,
        "ba_global_frames_ratio": ratio,
        "ba_global_points_ratio": ratio,
        "ba_global_max_refinements": (
            6
            if scenario == "wrong_max_refinements" and ordinal == 1
            else 5.0
            if scenario == "floating_max_refinements" and ordinal == 1
            else 5
        ),
        "request_sha256": request_sha256,
        "execution_assurance": execution_assurance(),
        "evidence_class": request["evidence_class"],
        "request_kind": request["request_kind"],
        "source_provenance_scope": build["source_provenance_scope"],
        "source_tree_state": build["source_tree_state"],
        "toolchain_provenance_status": runtime["toolchain_provenance_status"],
        "adapter_executable_bytes": runtime["adapter_executable_bytes"],
        "adapter_executable_sha256": runtime["adapter_executable_sha256"],
        "resolved_plan_binding_sha256": digest("plan"),
        "deterministic_seed": 42,
        "colmap_runtime_closure_sha256": request["runtime_closure"][
            "colmap_runtime_closure_sha256"
        ],
        "selection_manifest_sha256": checkpoint["selection_manifest_sha256"],
        "selected_frames_digest": digest("frames"),
        "selected_image_names": checkpoint["selected_image_names"],
        "pair_graph_evidence_sha256": checkpoint["pair_graph_evidence_sha256"],
        "pair_list_digest": digest("pairs"),
        "feature_database_digest": checkpoint["feature_database_digest"],
        "matching_database_digest": checkpoint["matching_database_digest"],
        "source_database_initial_evidence": source_database_initial_evidence,
        "source_database_final_evidence": source_database_final_evidence,
        "clone_database_pre_run_evidence": clone_database_pre_run_evidence,
        "clone_database_post_run_evidence": clone_database_post_run_evidence,
        "clone_database_companion_names": (
            ["database.db-wal"]
            if scenario == "sqlite_companion" and ordinal == 1
            else []
        ),
        "clone_feature_database_digest_after": (
            digest("changed-feature-db")
            if scenario == "clone_logical_mismatch" and ordinal == 1
            else checkpoint["feature_database_digest"]
        ),
        "clone_matching_database_digest_after": checkpoint[
            "matching_database_digest"
        ],
        "output_root": str(trial_root),
        "fixed_mapper_options": trial_fixed_options,
        "fixed_mapper_options_sha256": fixed_options_sha256,
        "cadence_schedule_sha256": experiment["cadence_schedule_sha256"],
        "quality_thresholds_sha256": experiment["quality_thresholds_sha256"],
        "experiment_contract_sha256": experiment["experiment_contract_sha256"],
        "point_track_topology_digest": point_track_topology_digest,
        "mapping_elapsed_seconds": wall,
        "peak_memory_bytes": 2_000_000 + ordinal,
        "registered_views": registered_views,
        "registered_image_names": registered_image_names,
        "point_count": point_count,
        "observation_count": observation_count,
        "median_residual_pixels": median_residual_pixels,
        "p90_residual_pixels": p90_residual_pixels,
        "conditioning_status": (
            "rejected"
            if scenario == "conditioning_rejected" and ordinal == 1
            else "accepted"
        ),
        "conditioning_provenance": "colmap-text-conditioning-v2",
        "conditioning_measurement": conditioning_measurement,
        "camera_poses_wxyz_xyz": poses,
        "model_sha256": canonical_digest(model_hashes),
        "model_hashes": model_hashes,
        "mapped_model_order": 0,
        "mapper_log": mapper_log_path.name,
        "mapper_log_sha256": hashlib.sha256(mapper_log_data).hexdigest(),
        "mapper_log_bytes": len(mapper_log_data),
    }
    if scenario == "trial_assurance_mismatch" and ordinal == 1:
        envelope["execution_assurance"] = {
            **execution_assurance(),
            "child_database_open_inode_verified": True,
        }
    if scenario == "trial_contract_mismatch" and ordinal == 1:
        envelope["quality_thresholds_sha256"] = digest("wrong-thresholds")
    if scenario == "model_hash_mismatch" and ordinal == 1:
        envelope["model_sha256"] = digest("wrong-model")
    if scenario == "malformed_topology_digest" and ordinal == 1:
        envelope["point_track_topology_digest"] = "not-a-digest"
    if scenario == "mapper_log_digest_mismatch" and ordinal == 1:
        envelope["mapper_log_sha256"] = digest("wrong-log")
    if scenario == "mapper_log_path_escape" and ordinal == 1:
        envelope["mapper_log"] = "../mapper.log"
    if scenario == "trial_unknown_field" and ordinal == 1:
        envelope["untrusted_note"] = "looks equivalent"
    if scenario == "obsolete_quality_closure_digest" and ordinal == 1:
        envelope["quality_closure_sha256"] = digest("quality-closure")
    if scenario == "obsolete_pose_digest" and ordinal == 1:
        envelope["pose_digest"] = digest("poses")
    return envelope


values = arguments()
call_index = append_call()
output = Path(values["--output"])
if values.get("--matching-only") == "true":
    envelope = matching_envelope(values, call_index)
else:
    envelope = trial_envelope(values, call_index)
if call_index == 10:
    scenario = os.environ.get("FAKE_ADAPTER_SCENARIO", "success")
    if scenario == "mutate_input_after_trials":
        Path(values["--input"]).write_bytes(b"mutated input")
    elif scenario == "mutate_runtime_after_trials":
        (Path(values["--toolchain-root"]) / "lib/libomp.dylib").write_bytes(
            b"mutated runtime"
        )
    elif scenario == "mutate_adapter_after_trials":
        adapter = Path(sys.argv[0])
        adapter.write_text(adapter.read_text(encoding="utf-8") + "\n", encoding="utf-8")
    elif scenario == "mutate_request_after_trials":
        request_path = Path(values["--request"])
        request_path.write_bytes(request_path.read_bytes() + b" ")
if envelope:
    output.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    payload = json.dumps(envelope, separators=(",", ":")).encode("utf-8")
    foundation_serializer = os.environ.get("FAKE_FOUNDATION_JSON_SERIALIZER")
    if foundation_serializer is None:
        output.write_bytes(payload)
    else:
        completed = subprocess.run(
            [foundation_serializer],
            input=payload,
            capture_output=True,
        )
        if completed.returncode != 0:
            sys.stderr.buffer.write(completed.stderr)
            raise SystemExit(92)
        output.write_bytes(completed.stdout)
'''


class MapperCadenceABTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        self.adapter = self.root / "adapter"
        self.adapter.write_text(textwrap.dedent(FAKE_ADAPTER), encoding="utf-8")
        self.adapter.chmod(0o700)
        self.input = self.root / "clip.mp4"
        self.input.write_bytes(b"fixture video")
        self.toolchain = self.root / "toolchain"
        (self.toolchain / "bin").mkdir(parents=True, mode=0o700)
        (self.toolchain / "lib").mkdir(mode=0o700)
        (self.toolchain / "bin/colmap").write_text(
            "#!/bin/sh\nexit 0\n",
            encoding="utf-8",
        )
        (self.toolchain / "bin/colmap").chmod(0o700)
        (self.toolchain / "lib/libomp.dylib").write_bytes(b"fake-openmp")
        self.runtime_digest = runtime_closure_digest(self.toolchain)
        self.request = self.root / "request.json"
        request = request_contract.build_request(
            scene_id="unit_video",
            category="low_light",
            input_kind="video",
            input_path=self.input,
            scale=30,
            candidate_run_configuration=candidate_configuration(),
            adapter_executable=self.adapter,
            colmap_runtime_root=self.toolchain,
            colmap_runtime_closure_sha256=self.runtime_digest,
            fixed_mapper_options=fixed_mapper_options(),
            quality_thresholds=request_contract.QUALITY_THRESHOLDS,
            source_git_commit="a" * 40,
            source_tree_state="dirty",
            measurement_runner_closure_identity=None,
            measurement_runner_closure_root=None,
            xcode_version="Xcode 16.4 (16F6)",
            swift_version="Swift version 6.1.2",
        )
        request_contract.write_request(self.request, request)
        self.work = self.root / "work"
        self.work.mkdir(mode=0o700)
        self.output = self.work / "result.json"
        self.call_log = self.root / "calls.jsonl"

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def run_supervisor(
        self,
        scenario: str = "success",
        *,
        extra_arguments: tuple[str, ...] = ("--profile-seed", "42"),
    ) -> subprocess.CompletedProcess[str]:
        environment = os.environ.copy()
        environment["FAKE_ADAPTER_LOG"] = str(self.call_log)
        environment["FAKE_ADAPTER_SCENARIO"] = scenario
        return subprocess.run(
            [
                sys.executable,
                str(SUPERVISOR),
                "--adapter",
                str(self.adapter),
                "--request",
                str(self.request),
                "--input",
                str(self.input),
                "--toolchain-root",
                str(self.toolchain),
                "--colmap-runtime-closure-sha256",
                self.runtime_digest,
                "--work-root",
                str(self.work),
                "--output",
                str(self.output),
                *extra_arguments,
            ],
            cwd=REPOSITORY_ROOT,
            env=environment,
            text=True,
            capture_output=True,
        )

    def calls(self) -> list[list[str]]:
        if not self.call_log.exists():
            return []
        return [json.loads(line) for line in self.call_log.read_text().splitlines()]

    def run_supervisor_in_process(
        self,
        scenario: str,
        *,
        center_p95: float = 0.0,
        rotation_p95: float = 0.0,
        foundation_json_serializer: Path | None = None,
    ) -> dict[str, object]:
        environment = {
            "FAKE_ADAPTER_LOG": str(self.call_log),
            "FAKE_ADAPTER_SCENARIO": scenario,
        }
        if foundation_json_serializer is not None:
            environment["FAKE_FOUNDATION_JSON_SERIALIZER"] = str(
                foundation_json_serializer
            )
        arguments = supervisor._parser().parse_args(
            [
                "--adapter",
                str(self.adapter),
                "--request",
                str(self.request),
                "--input",
                str(self.input),
                "--toolchain-root",
                str(self.toolchain),
                "--colmap-runtime-closure-sha256",
                self.runtime_digest,
                "--work-root",
                str(self.work),
                "--output",
                str(self.output),
                "--profile-seed",
                "42",
            ]
        )
        deviation = types.SimpleNamespace(
            camera_center_p95_scene_radius_fraction=center_p95,
            rotation_p95_degrees=rotation_p95,
        )
        with mock.patch.dict(os.environ, environment), mock.patch.object(
            supervisor.evidence,
            "sim3_pose_deviation",
            return_value=deviation,
        ):
            return supervisor.run_experiment(arguments)

    def build_foundation_json_serializer(self) -> Path:
        source = self.root / "foundation-json-serializer.swift"
        source.write_text(
            textwrap.dedent(
                """
                import Darwin
                import Foundation

                do {
                    let input = FileHandle.standardInput.readDataToEndOfFile()
                    let object = try JSONSerialization.jsonObject(with: input)
                    let output = try JSONSerialization.data(
                        withJSONObject: object,
                        options: [.sortedKeys, .withoutEscapingSlashes]
                    )
                    FileHandle.standardOutput.write(output)
                } catch {
                    let message = Data("Foundation JSON failure: \\(error)\\n".utf8)
                    FileHandle.standardError.write(message)
                    Darwin.exit(1)
                }
                """
            ),
            encoding="utf-8",
        )
        executable = self.root / "foundation-json-serializer"
        completed = subprocess.run(
            ["/usr/bin/xcrun", "swiftc", str(source), "-o", str(executable)],
            text=True,
            capture_output=True,
        )
        self.assertEqual(completed.returncode, 0, completed.stderr)
        return executable

    def test_runs_bootstrap_decision_warmup_and_counterbalanced_schedule(self) -> None:
        completed = self.run_supervisor()

        self.assertEqual(completed.returncode, 0, completed.stderr)
        calls = self.calls()
        self.assertEqual(len(calls), 11)
        self.assertEqual(calls[0][-2:], ["--matching-only", "true"])
        self.assertEqual(calls[1][-2:], ["--matching-only", "true"])
        self.assertNotEqual(
            calls[0][calls[0].index("--project-root") + 1],
            calls[1][calls[1].index("--project-root") + 1],
        )
        expected = [
            "balanced-global",
            "frequent-global",
            "balanced-global",
            "balanced-global",
            "frequent-global",
            "frequent-global",
            "balanced-global",
            "balanced-global",
            "frequent-global",
        ]
        self.assertEqual(
            [call[call.index("--mapper-cadence") + 1] for call in calls[2:]],
            expected,
        )
        decision_envelope = calls[1][calls[1].index("--output") + 1]
        for call in calls[2:]:
            self.assertEqual(
                call[call.index("--mapping-from-checkpoint") + 1],
                decision_envelope,
            )
            self.assertEqual(call[call.index("--variant") + 1], "candidate")

        result = json.loads(self.output.read_text(encoding="utf-8"))
        self.assertEqual(result["schema_version"], 3)
        self.assertEqual(result["measurement_scope"], "mapper_cadence_ab")
        request = json.loads(self.request.read_text(encoding="utf-8"))
        experiment = request["experiment"]
        self.assertEqual(result["evidence_class"], "development_only")
        self.assertEqual(
            result["source_provenance_scope"],
            "binary_only_dirty_worktree",
        )
        self.assertEqual(
            result["toolchain_provenance_status"],
            "local_adhoc_unsigned",
        )
        self.assertEqual(
            result["execution_assurance"],
            {
                "level": "observational",
                "mutation_threat_model": "no_concurrent_same_uid_mutation",
                "runner_isolation_mode": "owner_private_local_process",
                "child_database_binding": "pre_post_descriptor_path",
                "child_database_open_inode_verified": False,
                "child_runtime_binding": "pre_post_closure_path",
                "child_runtime_exec_inode_verified": False,
                "release_gate_eligible": False,
            },
        )
        for envelope in (
            result["decision_matching_checkpoint"],
            result["discarded_warmup"],
            *result["raw_trials"],
        ):
            self.assertEqual(
                envelope["execution_assurance"],
                result["execution_assurance"],
            )
        self.assertEqual(result["request_bytes"], self.request.stat().st_size)
        self.assertEqual(
            result["expected_colmap_runtime_closure_sha256"],
            self.runtime_digest,
        )
        self.assertEqual(
            result["fixed_mapper_options_sha256"],
            experiment["fixed_mapper_options_sha256"],
        )
        self.assertEqual(
            result["cadence_schedule_sha256"],
            experiment["cadence_schedule_sha256"],
        )
        self.assertEqual(
            result["quality_thresholds_sha256"],
            experiment["quality_thresholds_sha256"],
        )
        self.assertEqual(
            result["measured_schedule"],
            expected[1:],
        )
        self.assertEqual(len(result["raw_trials"]), 8)
        self.assertEqual(result["aggregates"]["frequent-global"]["trial_count"], 4)
        self.assertEqual(
            result["aggregates"]["frequent-global"]["median_mapping_elapsed_seconds"],
            13.0,
        )
        self.assertEqual(result["aggregates"]["balanced-global"]["trial_count"], 4)
        self.assertEqual(
            result["aggregates"]["balanced-global"]["median_mapping_elapsed_seconds"],
            23.0,
        )
        self.assertEqual(
            result["differences"]["balanced_minus_frequent"][
                "median_mapping_elapsed_seconds"
            ],
            10.0,
        )
        self.assertEqual(
            set(result["within_arm_repeatability"]),
            {"frequent-global", "balanced-global"},
        )
        for cadence in ("frequent-global", "balanced-global"):
            repeatability = result["within_arm_repeatability"][cadence]
            self.assertTrue(repeatability["accepted"])
            self.assertEqual(repeatability["trial_count"], 4)
            self.assertEqual(len(repeatability["pairwise_comparisons"]), 6)
        self.assertEqual(result["winner"], "frequent-global")
        self.assertEqual(len(result["quality_comparisons"]), 16)
        self.assertTrue(
            all(comparison["accepted"] for comparison in result["quality_comparisons"])
        )
        self.assertEqual(stat.S_IMODE(self.output.stat().st_mode), 0o600)
        bootstrap = json.loads(
            (self.work / "matching-bootstrap/matching-envelope.json").read_text()
        )
        decision = json.loads(
            (self.work / "matching-decision/matching-envelope.json").read_text()
        )
        for field in (
            "pair_graph_evidence_sha256",
            "worker_execution_sha256",
            "database_file_sha256",
            "matching_duration_seconds",
            "peak_memory_bytes",
        ):
            self.assertNotEqual(bootstrap[field], decision[field])

    def test_bootstrap_mismatch_aborts_before_mapping(self) -> None:
        completed = self.run_supervisor("bootstrap_mismatch")

        self.assertEqual(completed.returncode, 2)
        self.assertEqual(len(self.calls()), 2)
        self.assertFalse(self.output.exists())
        self.assertIn("matching checkpoints do not reproduce", completed.stderr)

    def test_compute_and_recovery_history_are_part_of_the_matching_closure(self) -> None:
        for scenario in (
            "compute_mode_mismatch",
            "fallback_history_mismatch",
            "rejected_retrieval_mismatch",
        ):
            with self.subTest(scenario=scenario):
                self.work = self.root / f"work-{scenario}"
                self.work.mkdir(mode=0o700)
                self.output = self.work / "result.json"
                self.call_log.unlink(missing_ok=True)

                completed = self.run_supervisor(scenario)

                self.assertEqual(completed.returncode, 2)
                self.assertEqual(len(self.calls()), 2)
                self.assertFalse(self.output.exists())
                self.assertIn("matching checkpoints do not reproduce", completed.stderr)

    def test_matching_envelope_cannot_overstate_or_drift_from_request_authority(self) -> None:
        for scenario, expected in (
            ("matching_assurance_mismatch", "execution_assurance"),
            ("matching_assurance_boolean_as_integer", "execution_assurance"),
            ("matching_provenance_mismatch", "request-bound provenance"),
            ("matching_unknown_field", "fields do not match the schema"),
        ):
            with self.subTest(scenario=scenario):
                self.work = self.root / f"work-{scenario}"
                self.work.mkdir(mode=0o700)
                self.output = self.work / "result.json"
                self.call_log.unlink(missing_ok=True)

                completed = self.run_supervisor(scenario)

                self.assertEqual(completed.returncode, 2)
                self.assertEqual(len(self.calls()), 2)
                self.assertFalse(self.output.exists())
                self.assertIn(expected, completed.stderr)

    def test_selection_or_logical_database_mismatch_aborts_before_mapping(self) -> None:
        for scenario in (
            "selection_mismatch",
            "logical_database_mismatch",
            "artifact_layout_mismatch",
        ):
            with self.subTest(scenario=scenario):
                self.work = self.root / f"work-{scenario}"
                self.work.mkdir(mode=0o700)
                self.output = self.work / "result.json"
                self.call_log.unlink(missing_ok=True)

                completed = self.run_supervisor(scenario)

                self.assertEqual(completed.returncode, 2)
                self.assertEqual(len(self.calls()), 2)
                self.assertFalse(self.output.exists())
                self.assertIn("matching checkpoints do not reproduce", completed.stderr)

    def test_matching_database_must_be_the_project_relative_artifact(self) -> None:
        completed = self.run_supervisor("foreign_database")

        self.assertEqual(completed.returncode, 2)
        self.assertEqual(len(self.calls()), 1)
        self.assertFalse(self.output.exists())
        self.assertIn("database path does not match", completed.stderr)

    def test_matching_schema_version_must_be_an_integer(self) -> None:
        completed = self.run_supervisor("floating_matching_schema")

        self.assertEqual(completed.returncode, 2)
        self.assertEqual(len(self.calls()), 1)
        self.assertFalse(self.output.exists())
        self.assertIn("schema_version", completed.stderr)

    def test_nonzero_adapter_exit_is_terminal(self) -> None:
        completed = self.run_supervisor("nonzero_exit")

        self.assertEqual(completed.returncode, 2)
        self.assertEqual(len(self.calls()), 3)
        self.assertFalse(self.output.exists())
        self.assertIn("adapter exited with status 17", completed.stderr)
        self.assertIn("live SQLite companion database.db-shm", completed.stderr)
        self.assertNotIn("discarded adapter prefix", completed.stderr)
        self.assertLessEqual(
            len(completed.stderr.encode("utf-8")),
            supervisor.MAXIMUM_ADAPTER_STDERR_TAIL_BYTES + 256,
        )

    def test_adapter_stderr_tail_replaces_terminal_control_characters(self) -> None:
        self.assertEqual(
            supervisor._display_adapter_stderr_tail(b"before\x1b[31m\r\nafter\x00"),
            "before�[31m\n\nafter�",
        )

    def test_rejects_duplicate_database_identity_or_destination(self) -> None:
        for scenario, expected in (
            ("duplicate_inode", "duplicate trial database"),
            ("duplicate_path", "trial database destination"),
        ):
            with self.subTest(scenario=scenario):
                self.work = self.root / f"work-{scenario}"
                self.work.mkdir(mode=0o700)
                self.output = self.work / "result.json"
                self.call_log.unlink(missing_ok=True)

                completed = self.run_supervisor(scenario)

                self.assertEqual(completed.returncode, 2)
                self.assertFalse(self.output.exists())
                self.assertIn(expected, completed.stderr)

    def test_accepts_a_mapper_mutated_private_clone_but_freezes_its_source(self) -> None:
        completed = self.run_supervisor("clone_mutates")

        self.assertEqual(completed.returncode, 0, completed.stderr)
        result = json.loads(self.output.read_text(encoding="utf-8"))
        for trial in result["raw_trials"]:
            self.assertEqual(
                trial["source_database_initial_evidence"],
                trial["source_database_final_evidence"],
            )
            before = trial["clone_database_pre_run_evidence"]
            after = trial["clone_database_post_run_evidence"]
            self.assertEqual(
                before["destination_inode"],
                after["destination_inode"],
            )
            self.assertNotEqual(before["destination_sha256"], after["destination_sha256"])

        for scenario, expected in (
            ("source_digest_mismatch", "source database"),
            ("source_final_mismatch", "source database final"),
            ("clone_before_mismatch", "clone pre-run"),
            ("post_identity_mismatch", "clone post-run"),
        ):
            with self.subTest(scenario=scenario):
                self.work = self.root / f"work-{scenario}"
                self.work.mkdir(mode=0o700)
                self.output = self.work / "result.json"
                self.call_log.unlink(missing_ok=True)

                rejected = self.run_supervisor(scenario)

                self.assertEqual(rejected.returncode, 2)
                self.assertFalse(self.output.exists())
                self.assertIn(expected, rejected.stderr)

    def test_rejects_non_apfs_or_ill_typed_database_evidence(self) -> None:
        for scenario, expected in (
            ("source_writable_mode", "source database initial evidence.mode"),
            ("clone_float_byte_count", "clone pre-run byte count"),
            ("clone_strategy_fallback", "clone pre-run strategy"),
            ("clone_readonly_mode", "clone pre-run mode"),
            ("clone_parent_identity_mismatch", "trial root identity"),
            ("clone_file_device_mismatch", "clone pre-run device"),
        ):
            with self.subTest(scenario=scenario):
                self.work = self.root / f"work-{scenario}"
                self.work.mkdir(mode=0o700)
                self.output = self.work / "result.json"
                self.call_log.unlink(missing_ok=True)

                completed = self.run_supervisor(scenario)

                self.assertEqual(completed.returncode, 2)
                self.assertFalse(self.output.exists())
                self.assertIn(expected, completed.stderr)

    def test_all_trials_must_share_one_physical_frozen_source(self) -> None:
        completed = self.run_supervisor("source_changes_between_trials")

        self.assertEqual(completed.returncode, 2)
        self.assertFalse(self.output.exists())
        self.assertIn("one physical frozen source database", completed.stderr)

    def test_rejects_tampered_trial_binding_before_publication(self) -> None:
        completed = self.run_supervisor("tampered_closure")

        self.assertEqual(completed.returncode, 2)
        self.assertFalse(self.output.exists())
        self.assertIn("trial binding differs from the matching checkpoint", completed.stderr)

    def test_rejects_noncanonical_request_before_invoking_the_adapter(self) -> None:
        self.request.write_bytes(self.request.read_bytes() + b" ")

        completed = self.run_supervisor()

        self.assertEqual(completed.returncode, 2)
        self.assertEqual(self.calls(), [])
        self.assertFalse(self.output.exists())
        self.assertIn("canonical JSON", completed.stderr)

    def test_external_runtime_authority_must_match_request_and_live_runtime(self) -> None:
        completed = self.run_supervisor(
            extra_arguments=(
                "--profile-seed",
                "42",
                "--colmap-runtime-closure-sha256",
                digest("wrong-runtime"),
            ),
        )

        self.assertEqual(completed.returncode, 2)
        self.assertEqual(self.calls(), [])
        self.assertFalse(self.output.exists())
        self.assertIn("COLMAP runtime", completed.stderr)

    def test_runner_identity_and_live_closure_root_are_an_atomic_pair(self) -> None:
        for extra in (
            ("--measurement-runner-closure-identity", str(self.request)),
            ("--measurement-runner-closure-root", str(self.root)),
        ):
            with self.subTest(argument=extra[0]):
                self.work = self.root / f"work-{extra[0].removeprefix('--')}"
                self.work.mkdir(mode=0o700)
                self.output = self.work / "result.json"

                completed = self.run_supervisor(
                    extra_arguments=("--profile-seed", "42", *extra),
                )

                self.assertEqual(completed.returncode, 2)
                self.assertEqual(self.calls(), [])
                self.assertFalse(self.output.exists())
                self.assertIn("must be supplied together", completed.stderr)

    def test_runner_identity_pair_is_forwarded_to_both_request_validations(self) -> None:
        arguments = supervisor._parser().parse_args(
            [
                "--adapter",
                str(self.adapter),
                "--request",
                str(self.request),
                "--input",
                str(self.input),
                "--toolchain-root",
                str(self.toolchain),
                "--colmap-runtime-closure-sha256",
                self.runtime_digest,
                "--measurement-runner-closure-identity",
                str(self.request),
                "--measurement-runner-closure-root",
                str(self.root),
                "--work-root",
                str(self.work),
                "--output",
                str(self.output),
                "--profile-seed",
                "42",
            ]
        )
        validated_request = json.loads(self.request.read_text(encoding="utf-8"))
        environment = {
            "FAKE_ADAPTER_LOG": str(self.call_log),
            "FAKE_ADAPTER_SCENARIO": "success",
        }
        deviation = types.SimpleNamespace(
            camera_center_p95_scene_radius_fraction=0.0,
            rotation_p95_degrees=0.0,
        )
        with mock.patch.dict(os.environ, environment), mock.patch.object(
            supervisor.request_contract,
            "load_and_validate_request",
            return_value=validated_request,
        ) as validator, mock.patch.object(
            supervisor.evidence,
            "sim3_pose_deviation",
            return_value=deviation,
        ):
            supervisor.run_experiment(arguments)

        self.assertEqual(validator.call_count, 2)
        for call in validator.call_args_list:
            self.assertEqual(
                call.kwargs["measurement_runner_closure_identity"],
                self.request,
            )
            self.assertEqual(
                call.kwargs["measurement_runner_closure_root"],
                self.root,
            )

    def test_trials_bind_fixed_options_and_exact_requested_schedule(self) -> None:
        for scenario, expected in (
            ("fixed_options_value_mismatch", "fixed mapper options"),
            ("fixed_options_digest_mismatch", "fixed mapper options"),
            ("schedule_ratio_mismatch", "requested cadence"),
        ):
            with self.subTest(scenario=scenario):
                self.work = self.root / f"work-{scenario}"
                self.work.mkdir(mode=0o700)
                self.output = self.work / "result.json"
                self.call_log.unlink(missing_ok=True)

                completed = self.run_supervisor(scenario)

                self.assertEqual(completed.returncode, 2)
                self.assertFalse(self.output.exists())
                self.assertIn(expected, completed.stderr)

    def test_trial_receipts_and_observational_assurance_are_not_self_asserted(self) -> None:
        for scenario, expected in (
            ("trial_assurance_mismatch", "execution_assurance"),
            ("trial_contract_mismatch", "request-bound provenance"),
            ("model_hash_mismatch", "model_sha256"),
            ("malformed_topology_digest", "point_track_topology_digest"),
            ("mapper_log_digest_mismatch", "mapper_log_sha256"),
            ("mapper_log_path_escape", "direct child"),
            ("trial_unknown_field", "fields do not match the schema"),
        ):
            with self.subTest(scenario=scenario):
                self.work = self.root / f"work-{scenario}"
                self.work.mkdir(mode=0o700)
                self.output = self.work / "result.json"
                self.call_log.unlink(missing_ok=True)

                completed = self.run_supervisor(scenario)

                self.assertEqual(completed.returncode, 2)
                self.assertFalse(self.output.exists())
                self.assertIn(expected, completed.stderr)

    def test_revalidates_live_request_bindings_after_all_trials(self) -> None:
        original_input = self.input.read_bytes()
        original_runtime = (self.toolchain / "lib/libomp.dylib").read_bytes()
        original_adapter = self.adapter.read_bytes()
        original_request = self.request.read_bytes()
        for scenario, expected in (
            ("mutate_input_after_trials", "source input digest"),
            ("mutate_runtime_after_trials", "COLMAP runtime"),
            ("mutate_adapter_after_trials", "adapter executable"),
            ("mutate_request_after_trials", "canonical JSON"),
        ):
            with self.subTest(scenario=scenario):
                self.input.write_bytes(original_input)
                (self.toolchain / "lib/libomp.dylib").write_bytes(original_runtime)
                self.adapter.write_bytes(original_adapter)
                self.adapter.chmod(0o700)
                self.request.write_bytes(original_request)
                self.work = self.root / f"work-{scenario}"
                self.work.mkdir(mode=0o700)
                self.output = self.work / "result.json"
                self.call_log.unlink(missing_ok=True)

                completed = self.run_supervisor(scenario)

                self.assertEqual(completed.returncode, 2)
                self.assertEqual(len(self.calls()), 11)
                self.assertFalse(self.output.exists())
                self.assertIn(expected, completed.stderr)

    def test_clone_logical_contents_remain_bound_after_mapping(self) -> None:
        completed = self.run_supervisor("clone_logical_mismatch")

        self.assertEqual(completed.returncode, 2)
        self.assertFalse(self.output.exists())
        self.assertIn("clone logical database", completed.stderr)

    def test_rejects_missing_duplicate_or_extra_trial(self) -> None:
        for scenario, expected in (
            ("missing_trial", "adapter did not publish"),
            ("duplicate_trial", "unexpected trial ordinal"),
            ("extra_trial", "unexpected trial ordinal"),
            ("extra_trial_directory", "unexpected work-root entry"),
        ):
            with self.subTest(scenario=scenario):
                self.work = self.root / f"work-{scenario}"
                self.work.mkdir(mode=0o700)
                self.output = self.work / "result.json"
                self.call_log.unlink(missing_ok=True)

                completed = self.run_supervisor(scenario)

                self.assertEqual(completed.returncode, 2)
                self.assertFalse(self.output.exists())
                self.assertIn(expected, completed.stderr)

    def test_rejects_nonpositive_metrics_and_malformed_pose_arrays(self) -> None:
        for scenario, expected in (
            ("invalid_metrics", "mapping_elapsed_seconds"),
            ("invalid_poses", "camera_poses_wxyz_xyz"),
            ("pose_name_mismatch", "registered_image_names"),
            ("absolute_residual_failure", "absolute quality thresholds"),
        ):
            with self.subTest(scenario=scenario):
                self.work = self.root / f"work-{scenario}"
                self.work.mkdir(mode=0o700)
                self.output = self.work / "result.json"
                self.call_log.unlink(missing_ok=True)

                completed = self.run_supervisor(scenario)

                self.assertEqual(completed.returncode, 2)
                self.assertFalse(self.output.exists())
                self.assertIn(expected, completed.stderr)

    def test_schema_three_publishes_no_unverifiable_quality_or_pose_digest(
        self,
    ) -> None:
        result = self.run_supervisor_in_process("success")

        self.assertEqual(result["schema_version"], 3)
        for trial in [result["discarded_warmup"], *result["raw_trials"]]:
            self.assertNotIn("quality_closure_sha256", trial)
            self.assertNotIn("pose_digest", trial)

    def test_schema_three_rejects_obsolete_digest_fields(self) -> None:
        for scenario in (
            "obsolete_quality_closure_digest",
            "obsolete_pose_digest",
        ):
            with self.subTest(scenario=scenario):
                self.work = self.root / f"work-{scenario}"
                self.work.mkdir(mode=0o700)
                self.output = self.work / "result.json"
                self.call_log.unlink(missing_ok=True)

                completed = self.run_supervisor(scenario)

                self.assertEqual(completed.returncode, 2)
                self.assertFalse(self.output.exists())
                self.assertIn(
                    "mapping trial fields do not match the schema",
                    completed.stderr,
                )

    def test_nontrivial_float_roundtrip_keeps_remaining_hashes_self_consistent(
        self,
    ) -> None:
        foundation_json_serializer = self.build_foundation_json_serializer()
        self.run_supervisor_in_process(
            "nontrivial_float_roundtrip",
            foundation_json_serializer=foundation_json_serializer,
        )

        published_text = self.output.read_text(encoding="utf-8")
        published = json.loads(published_text)
        reemitted = json.loads(
            json.dumps(
                published,
                sort_keys=True,
                separators=(",", ":"),
                allow_nan=False,
            )
        )
        self.assertEqual(reemitted, published)
        self.assertEqual(reemitted["schema_version"], 3)
        request = json.loads(self.request.read_text(encoding="utf-8"))
        decision = reemitted["decision_matching_checkpoint"]
        request_sha256 = hashlib.sha256(self.request.read_bytes()).hexdigest()
        adapter_sha256 = hashlib.sha256(self.adapter.read_bytes()).hexdigest()
        trials = [reemitted["discarded_warmup"], *reemitted["raw_trials"]]
        self.assertTrue(
            any(
                abs(pose[4] - round(pose[4])) > 1e-12
                for trial in trials
                for pose in trial["camera_poses_wxyz_xyz"]
            )
        )
        for trial in trials:
            original_path = Path(trial["output_root"]) / "trial-envelope.json"
            original_text = original_path.read_text(encoding="utf-8")
            self.assertIn(
                '"median_residual_pixels":0.50000000000000011',
                original_text,
            )
            original = json.loads(original_text)
            for field in (
                "registered_views",
                "registered_image_names",
                "point_count",
                "observation_count",
                "point_track_topology_digest",
                "median_residual_pixels",
                "p90_residual_pixels",
                "conditioning_status",
                "conditioning_provenance",
                "conditioning_measurement",
                "camera_poses_wxyz_xyz",
                "model_sha256",
                "model_hashes",
            ):
                self.assertEqual(trial[field], original[field])
            self.assertNotIn("quality_closure_sha256", trial)
            self.assertNotIn("pose_digest", trial)
            self.assertEqual(trial["schema_version"], 3)
            self.assertEqual(trial["request_sha256"], request_sha256)
            self.assertEqual(trial["adapter_executable_sha256"], adapter_sha256)
            self.assertEqual(
                trial["fixed_mapper_options_sha256"],
                request_contract.fixed_mapper_options_sha256(
                    trial["fixed_mapper_options"]
                ),
            )
            self.assertEqual(
                trial["model_sha256"],
                request_contract.sha256_canonical(trial["model_hashes"]),
            )
            mapper_log = Path(trial["output_root"]) / trial["mapper_log"]
            mapper_log_data = mapper_log.read_bytes()
            self.assertEqual(trial["mapper_log_bytes"], len(mapper_log_data))
            self.assertEqual(
                trial["mapper_log_sha256"],
                hashlib.sha256(mapper_log_data).hexdigest(),
            )
            self.assertEqual(
                trial["source_database_initial_evidence"]["sha256"],
                decision["database_file_sha256"],
            )
            self.assertEqual(
                trial["source_database_final_evidence"],
                trial["source_database_initial_evidence"],
            )
            self.assertEqual(
                trial["clone_database_pre_run_evidence"]["destination_sha256"],
                decision["database_file_sha256"],
            )
            self.assertEqual(
                trial["feature_database_digest"],
                decision["feature_database_digest"],
            )
            self.assertEqual(
                trial["matching_database_digest"],
                decision["matching_database_digest"],
            )
            for field in (
                "cadence_schedule_sha256",
                "quality_thresholds_sha256",
                "experiment_contract_sha256",
            ):
                self.assertEqual(trial[field], request["experiment"][field])

    def test_raw_quality_contradiction_withholds_a_winner(self) -> None:
        result = self.run_supervisor_in_process("quality_metric_mismatch")

        self.assertIsNone(result["winner"])
        self.assertEqual(
            result["winner_status"],
            "within_arm_repeatability_gate_failed",
        )
        self.assertEqual(result["quality_comparisons"], [])

    def test_exact_timing_range_boundary_preserves_the_happy_path_winner(self) -> None:
        result = self.run_supervisor_in_process("timing_range_boundary")

        self.assertEqual(result["winner"], "frequent-global")
        self.assertEqual(
            result["winner_status"],
            "lower_median_mapping_elapsed_seconds_with_quality_parity",
        )
        balanced = result["within_arm_repeatability"]["balanced-global"]
        self.assertEqual(balanced["mapping_elapsed_range_seconds"], 30.0)
        self.assertTrue(balanced["timing_accepted"])
        self.assertTrue(balanced["accepted"])
        self.assertEqual(len(result["quality_comparisons"]), 16)

    def test_timing_multimodality_blocks_selection_before_cross_arm_quality(
        self,
    ) -> None:
        for scenario, expected_range in (
            ("timing_range_over", 30.000_001),
            ("retry3_timing_multimodality", 105.641_648_8),
        ):
            with self.subTest(scenario=scenario):
                self.work = self.root / f"work-{scenario}"
                self.work.mkdir(mode=0o700)
                self.output = self.work / "result.json"
                self.call_log.unlink(missing_ok=True)

                result = self.run_supervisor_in_process(scenario)

                self.assertIsNone(result["winner"])
                self.assertEqual(
                    result["winner_status"],
                    "within_arm_repeatability_gate_failed",
                )
                self.assertEqual(result["quality_comparisons"], [])
                frequent = result["within_arm_repeatability"]["frequent-global"]
                balanced = result["within_arm_repeatability"]["balanced-global"]
                self.assertTrue(frequent["accepted"])
                self.assertFalse(balanced["accepted"])
                self.assertFalse(balanced["timing_accepted"])
                self.assertTrue(balanced["semantic_repeatability_accepted"])
                self.assertAlmostEqual(
                    balanced["mapping_elapsed_range_seconds"],
                    expected_range,
                )

    def test_one_arm_semantic_failure_blocks_all_cross_arm_selection(self) -> None:
        for scenario, reason in (
            ("within_arm_topology_mismatch", "point_track_topology_digest_mismatch"),
            (
                "within_arm_registered_set_mismatch",
                "registered_image_name_set_mismatch",
            ),
        ):
            with self.subTest(scenario=scenario):
                self.work = self.root / f"work-{scenario}"
                self.work.mkdir(mode=0o700)
                self.output = self.work / "result.json"
                self.call_log.unlink(missing_ok=True)

                result = self.run_supervisor_in_process(scenario)

                self.assertIsNone(result["winner"])
                self.assertEqual(
                    result["winner_status"],
                    "within_arm_repeatability_gate_failed",
                )
                self.assertEqual(result["quality_comparisons"], [])
                self.assertTrue(
                    result["within_arm_repeatability"]["frequent-global"]["accepted"]
                )
                balanced = result["within_arm_repeatability"]["balanced-global"]
                self.assertFalse(balanced["accepted"])
                self.assertTrue(balanced["timing_accepted"])
                self.assertFalse(balanced["semantic_repeatability_accepted"])
                self.assertTrue(
                    any(
                        reason in pair["reasons"]
                        for pair in balanced["pairwise_comparisons"]
                    )
                )

    def test_within_arm_pose_quality_failure_precedes_cross_arm_comparison(
        self,
    ) -> None:
        result = self.run_supervisor_in_process(
            "success",
            rotation_p95=0.200_001,
        )

        self.assertIsNone(result["winner"])
        self.assertEqual(
            result["winner_status"],
            "within_arm_repeatability_gate_failed",
        )
        self.assertEqual(result["quality_comparisons"], [])
        self.assertTrue(
            all(
                not arm["semantic_repeatability_accepted"]
                for arm in result["within_arm_repeatability"].values()
            )
        )

    def test_within_arm_repeatability_accepts_the_exact_timing_boundary(self) -> None:
        trials = [
            repeatability_trial(1, 10.0),
            repeatability_trial(2, 40.0),
            repeatability_trial(3, 20.0),
            repeatability_trial(4, 30.0),
        ]
        thresholds = {
            **request_contract.QUALITY_THRESHOLDS,
            "maximum_within_arm_mapping_elapsed_range_seconds": 30.0,
        }
        deviation = types.SimpleNamespace(
            camera_center_p95_scene_radius_fraction=0.0,
            rotation_p95_degrees=0.0,
        )

        with mock.patch.object(
            supervisor.evidence,
            "sim3_pose_deviation",
            return_value=deviation,
        ):
            result = supervisor._within_arm_repeatability(
                trials,
                "balanced-global",
                thresholds,
            )

        self.assertTrue(result["accepted"])
        self.assertTrue(result["timing_accepted"])
        self.assertTrue(result["semantic_repeatability_accepted"])
        self.assertEqual(result["minimum_mapping_elapsed_seconds"], 10.0)
        self.assertEqual(result["maximum_mapping_elapsed_seconds"], 40.0)
        self.assertEqual(result["mapping_elapsed_range_seconds"], 30.0)
        self.assertEqual(result["maximum_allowed_mapping_elapsed_range_seconds"], 30.0)
        self.assertEqual(len(result["pairwise_comparisons"]), 6)
        self.assertTrue(
            all(pair["accepted"] for pair in result["pairwise_comparisons"])
        )

    def test_within_arm_repeatability_rejects_any_timing_overrun(self) -> None:
        trials = [
            repeatability_trial(1, 10.0),
            repeatability_trial(2, 40.000_001),
            repeatability_trial(3, 20.0),
            repeatability_trial(4, 30.0),
        ]
        thresholds = {
            **request_contract.QUALITY_THRESHOLDS,
            "maximum_within_arm_mapping_elapsed_range_seconds": 30.0,
        }
        deviation = types.SimpleNamespace(
            camera_center_p95_scene_radius_fraction=0.0,
            rotation_p95_degrees=0.0,
        )

        with mock.patch.object(
            supervisor.evidence,
            "sim3_pose_deviation",
            return_value=deviation,
        ):
            result = supervisor._within_arm_repeatability(
                trials,
                "balanced-global",
                thresholds,
            )

        self.assertFalse(result["accepted"])
        self.assertFalse(result["timing_accepted"])
        self.assertTrue(result["semantic_repeatability_accepted"])
        self.assertAlmostEqual(result["mapping_elapsed_range_seconds"], 30.000_001)

    def test_retry3_like_timing_multimodality_fails_before_arm_selection(self) -> None:
        trials = [
            repeatability_trial(2, 63.481_024_7),
            repeatability_trial(3, 169.122_673_5),
            repeatability_trial(6, 164.954_239_3),
            repeatability_trial(7, 166.0),
        ]
        thresholds = {
            **request_contract.QUALITY_THRESHOLDS,
            "maximum_within_arm_mapping_elapsed_range_seconds": 30.0,
        }
        deviation = types.SimpleNamespace(
            camera_center_p95_scene_radius_fraction=0.0,
            rotation_p95_degrees=0.0,
        )

        with mock.patch.object(
            supervisor.evidence,
            "sim3_pose_deviation",
            return_value=deviation,
        ):
            result = supervisor._within_arm_repeatability(
                trials,
                "balanced-global",
                thresholds,
            )

        self.assertFalse(result["accepted"])
        self.assertFalse(result["timing_accepted"])
        self.assertAlmostEqual(result["mapping_elapsed_range_seconds"], 105.641_648_8)

    def test_within_arm_repeatability_requires_names_topology_and_pose_quality(
        self,
    ) -> None:
        thresholds = {
            **request_contract.QUALITY_THRESHOLDS,
            "maximum_within_arm_mapping_elapsed_range_seconds": 30.0,
        }
        accepted_deviation = types.SimpleNamespace(
            camera_center_p95_scene_radius_fraction=0.0,
            rotation_p95_degrees=0.0,
        )
        cases = {
            "registered_names": [
                repeatability_trial(1, 10.0),
                repeatability_trial(
                    2,
                    11.0,
                    registered_image_names=[
                        f"frame-{index:03}.jpg" for index in range(1, 30)
                    ],
                ),
                repeatability_trial(3, 12.0),
                repeatability_trial(4, 13.0),
            ],
            "topology": [
                repeatability_trial(1, 10.0),
                repeatability_trial(
                    2,
                    11.0,
                    topology_digest=digest("different-topology"),
                ),
                repeatability_trial(3, 12.0),
                repeatability_trial(4, 13.0),
            ],
        }
        for label, trials in cases.items():
            with (
                self.subTest(label=label),
                mock.patch.object(
                    supervisor.evidence,
                    "sim3_pose_deviation",
                    return_value=accepted_deviation,
                ),
            ):
                result = supervisor._within_arm_repeatability(
                    trials,
                    "balanced-global",
                    thresholds,
                )
            self.assertFalse(result["accepted"])
            self.assertTrue(result["timing_accepted"])
            self.assertFalse(result["semantic_repeatability_accepted"])
            self.assertTrue(
                any(not pair["accepted"] for pair in result["pairwise_comparisons"])
            )

        high_pose_deviation = types.SimpleNamespace(
            camera_center_p95_scene_radius_fraction=0.02,
            rotation_p95_degrees=0.21,
        )
        stable_trials = [repeatability_trial(index, 10.0 + index) for index in range(4)]
        with mock.patch.object(
            supervisor.evidence,
            "sim3_pose_deviation",
            return_value=high_pose_deviation,
        ):
            pose_result = supervisor._within_arm_repeatability(
                stable_trials,
                "balanced-global",
                thresholds,
            )
        self.assertFalse(pose_result["accepted"])
        self.assertFalse(pose_result["semantic_repeatability_accepted"])
        self.assertTrue(
            all(not pair["accepted"] for pair in pose_result["pairwise_comparisons"])
        )

    def test_quality_thresholds_include_counts_residuals_and_sim3_pose(self) -> None:
        names = [f"frame-{index:03}.jpg" for index in range(100)]
        poses = [
            [1.0, 0.0, 0.0, 0.0, float(index % 10), float(index // 10), 0.0]
            for index in range(100)
        ]
        reference: dict[str, object] = {
            "registered_views": 100,
            "registered_image_names": names,
            "point_count": 1_000,
            "observation_count": 3_000,
            "median_residual_pixels": 0.50,
            "p90_residual_pixels": 1.00,
            "conditioning_status": "accepted",
            "camera_poses_wxyz_xyz": poses,
        }
        candidate = dict(reference)
        candidate.update(
            {
                "registered_views": 99,
                "registered_image_names": names[:99],
                "point_count": 990,
                "observation_count": 2_970,
                "median_residual_pixels": 0.55,
                "p90_residual_pixels": 1.10,
                "camera_poses_wxyz_xyz": poses[:99],
            }
        )
        accepted_deviation = types.SimpleNamespace(
            camera_center_p95_scene_radius_fraction=0.01,
            rotation_p95_degrees=0.20,
        )
        with mock.patch.object(
            supervisor.evidence,
            "sim3_pose_deviation",
            return_value=accepted_deviation,
        ):
            accepted = supervisor._compare_trial_quality(reference, candidate)
        self.assertTrue(accepted["accepted"])

        improved_residuals = dict(candidate)
        improved_residuals["median_residual_pixels"] = 0.10
        improved_residuals["p90_residual_pixels"] = 0.20
        with mock.patch.object(
            supervisor.evidence,
            "sim3_pose_deviation",
            return_value=accepted_deviation,
        ):
            improved = supervisor._compare_trial_quality(
                reference,
                improved_residuals,
            )
        self.assertTrue(improved["accepted"])

        rejected_cases = (
            ("registered_views", 98),
            ("point_count", 989),
            ("observation_count", 2_969),
            ("median_residual_pixels", 0.550_001),
            ("p90_residual_pixels", 1.100_001),
        )
        for field, value in rejected_cases:
            with self.subTest(field=field):
                rejected_candidate = dict(candidate)
                rejected_candidate[field] = value
                with mock.patch.object(
                    supervisor.evidence,
                    "sim3_pose_deviation",
                    return_value=accepted_deviation,
                ):
                    comparison = supervisor._compare_trial_quality(
                        reference,
                        rejected_candidate,
                    )
                self.assertFalse(comparison["accepted"])

        for center_p95, rotation_p95 in ((0.010_001, 0.20), (0.01, 0.200_001)):
            with self.subTest(center_p95=center_p95, rotation_p95=rotation_p95):
                deviation = types.SimpleNamespace(
                    camera_center_p95_scene_radius_fraction=center_p95,
                    rotation_p95_degrees=rotation_p95,
                )
                with mock.patch.object(
                    supervisor.evidence,
                    "sim3_pose_deviation",
                    return_value=deviation,
                ):
                    comparison = supervisor._compare_trial_quality(reference, candidate)
                self.assertFalse(comparison["accepted"])

        rejected_conditioning = dict(candidate)
        rejected_conditioning["conditioning_status"] = "rejected"
        with mock.patch.object(
            supervisor.evidence,
            "sim3_pose_deviation",
            return_value=accepted_deviation,
        ):
            comparison = supervisor._compare_trial_quality(
                reference,
                rejected_conditioning,
            )
        self.assertFalse(comparison["accepted"])
        self.assertIn("conditioning_not_accepted", comparison["reasons"])

    def test_rejects_wrong_refinement_limit_companions_and_symlink_escape(self) -> None:
        for scenario, expected in (
            ("wrong_max_refinements", "ba_global_max_refinements"),
            ("sqlite_companion", "SQLite companion"),
            ("source_sqlite_companion", "SQLite companion"),
            ("symlink_escape", "database destination"),
        ):
            with self.subTest(scenario=scenario):
                self.work = self.root / f"work-{scenario}"
                self.work.mkdir(mode=0o700)
                self.output = self.work / "result.json"
                self.call_log.unlink(missing_ok=True)

                completed = self.run_supervisor(scenario)

                self.assertEqual(completed.returncode, 2)
                self.assertFalse(self.output.exists())
                self.assertIn(expected, completed.stderr)

    def test_rejects_noninteger_trial_identity_fields(self) -> None:
        for scenario, expected in (
            ("floating_trial_schema", "schema_version"),
            ("boolean_trial_ordinal", "trial_ordinal"),
            ("floating_max_refinements", "ba_global_max_refinements"),
        ):
            with self.subTest(scenario=scenario):
                self.work = self.root / f"work-{scenario}"
                self.work.mkdir(mode=0o700)
                self.output = self.work / "result.json"
                self.call_log.unlink(missing_ok=True)

                completed = self.run_supervisor(scenario)

                self.assertEqual(completed.returncode, 2)
                self.assertFalse(self.output.exists())
                self.assertIn(expected, completed.stderr)

    def test_rejects_stale_trial_schema(self) -> None:
        completed = self.run_supervisor("stale_trial_schema")

        self.assertEqual(completed.returncode, 2)
        self.assertFalse(self.output.exists())
        self.assertIn(
            "adapter did not publish a mapping cadence trial",
            completed.stderr,
        )

    def test_requires_full_accepted_geometry_conditioning_evidence(self) -> None:
        for scenario, expected in (
            ("conditioning_rejected", "conditioning_status"),
            ("conditioning_extra_key", "conditioning_measurement keys"),
            ("conditioning_boolean_count", "conditioning_measurement.pointCount"),
            (
                "conditioning_unsorted_eigenvalues",
                "conditioning_measurement.cameraCenterEigenvalues",
            ),
        ):
            with self.subTest(scenario=scenario):
                self.work = self.root / f"work-{scenario}"
                self.work.mkdir(mode=0o700)
                self.output = self.work / "result.json"
                self.call_log.unlink(missing_ok=True)

                completed = self.run_supervisor(scenario)

                self.assertEqual(completed.returncode, 2)
                self.assertFalse(self.output.exists())
                self.assertIn(expected, completed.stderr)

    def test_profile_seed_must_match_the_bound_checkpoint(self) -> None:
        completed = self.run_supervisor(
            extra_arguments=("--profile-seed", "7"),
        )

        self.assertEqual(completed.returncode, 2)
        self.assertEqual(len(self.calls()), 0)
        self.assertFalse(self.output.exists())
        self.assertIn("profile seed differs from the validated request", completed.stderr)

    def test_existing_mapper_profiler_parses_each_declared_log(self) -> None:
        completed = self.run_supervisor("mapper_log")

        self.assertEqual(completed.returncode, 0, completed.stderr)
        result = json.loads(self.output.read_text(encoding="utf-8"))
        self.assertEqual(len(result["mapping_profiles"]), 9)
        for profile in result["mapping_profiles"].values():
            self.assertEqual(profile["schema_version"], 1)
            self.assertEqual(profile["marker_counts"]["registration_attempts"], 0)

    def test_rejects_an_existing_output_without_replacing_it(self) -> None:
        sentinel = b"do-not-replace\n"
        self.output.write_bytes(sentinel)

        completed = self.run_supervisor()

        self.assertEqual(completed.returncode, 2)
        self.assertEqual(self.output.read_bytes(), sentinel)
        self.assertEqual(self.calls(), [])

    def test_atomic_publication_cleans_temporary_file_when_link_fails(self) -> None:
        private_root = self.root / "atomic-output"
        private_root.mkdir(mode=0o700)
        output = private_root / "result.json"

        with mock.patch.object(supervisor.os, "link", side_effect=OSError("failed")):
            with self.assertRaises(OSError):
                supervisor._write_atomic_json({"complete": True}, output)

        self.assertFalse(output.exists())
        self.assertEqual(list(private_root.iterdir()), [])


if __name__ == "__main__":
    unittest.main()
