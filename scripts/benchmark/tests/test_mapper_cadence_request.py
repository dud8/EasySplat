from __future__ import annotations

import copy
import hashlib
import json
import os
import stat
import tempfile
import unittest
from contextlib import redirect_stderr, redirect_stdout
from io import StringIO
from pathlib import Path
from unittest import mock

from scripts.benchmark import easysplat_benchmark as benchmark
from scripts.benchmark import mapper_cadence_request as subject


def digest(label: str) -> str:
    return hashlib.sha256(label.encode("utf-8")).hexdigest()


def prefixed_digest(label: str) -> str:
    return f"sha256:{digest(label)}"


def canonical_file(path: Path, value: object, mode: int = 0o600) -> None:
    path.write_bytes(subject.canonical_json_bytes(value) + b"\n")
    path.chmod(mode)


def subset_digest(root: Path, relative_paths: list[str]) -> str:
    hasher = hashlib.sha256()

    def add(value: bytes) -> None:
        hasher.update(len(value).to_bytes(8, "big"))
        hasher.update(value)

    add(b"easysplat-benchmark-input-v1")
    for relative_path in relative_paths:
        path = root / relative_path
        payload = path.read_bytes()
        add(relative_path.encode("utf-8"))
        hasher.update(len(payload).to_bytes(8, "big"))
        hasher.update(payload)
    return f"sha256:{hasher.hexdigest()}"


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
        "selected_frame_count": 250,
        "capture_path": "large_area",
        "input_topology": "segmented_mixed",
        "camera_grouping": "automatic",
        "lens_projection": "automatic",
        "resource_policy": "maximum_performance",
        "compute_policy": "metal_for_supported_stages",
        "pairing_policy": "segmented_mixed",
        "temporal_pairing": "linear",
        "temporal_offsets": [1, 2, 3, 4, 5, 6],
        "vocabulary_candidate_count": 20,
        "vocabulary_returned_neighbor_count": 8,
        "vocabulary_query_stride": 1,
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


class MapperCadenceRequestTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        self.input = self.root / "City Square"
        self.input.mkdir(mode=0o700)
        for ordinal in range(1, 5):
            (self.input / f"DJI_{ordinal:04d}.MP4").write_bytes(
                f"video-{ordinal}".encode("utf-8")
            )
            (self.input / f"DJI_{ordinal:04d}.SRT").write_bytes(
                f"telemetry-{ordinal}".encode("utf-8")
            )
        self.runner_closure = self.root / "measurement-runner-closure"
        self.runner_closure.mkdir(mode=0o700)
        executable_names = {
            "EasySplatMeasurementRunner",
            "PipelineMeasurementAdapter-current",
            "PipelineMeasurementAdapter-baseline",
            "AccurateReferenceMeasurementAdapter",
        }
        for name in (
            "EasySplatMeasurementRunner",
            "PipelineMeasurementAdapter.swift",
            "MeasurementAdapterSupport.swift",
            "PipelineMeasurementAdapter-current",
            "PipelineMeasurementAdapter-baseline",
            "AccurateReferenceMeasurementAdapter",
        ):
            path = self.runner_closure / name
            path.write_text(f"#!/bin/sh\n# {name}\nexit 0\n", encoding="utf-8")
            path.chmod(0o700 if name in executable_names else 0o600)
        self.adapter = self.runner_closure / "PipelineMeasurementAdapter-current"
        self.runtime = self.root / "colmap-runtime"
        (self.runtime / "bin").mkdir(parents=True, mode=0o700)
        (self.runtime / "lib").mkdir(mode=0o700)
        (self.runtime / "bin/colmap").write_text(
            "#!/bin/sh\nexit 0\n", encoding="utf-8"
        )
        (self.runtime / "bin/colmap").chmod(0o700)
        (self.runtime / "lib/libomp.dylib").write_bytes(b"fake-openmp")
        self.identity = self.root / "measurement-runner-identity.json"
        unsigned_identity = {
            "schema_version": 1,
            "label": "tracked-measurement-runner",
            "source_commit": "a" * 40,
            "xcode_version": "Xcode 16.4 (16F6)",
            "swift_version": "Swift version 6.1.2",
            "files": {
                path.name: {
                    "bytes": path.stat().st_size,
                    "sha256": hashlib.sha256(path.read_bytes()).hexdigest(),
                }
                for path in sorted(self.runner_closure.iterdir())
            },
        }
        identity = dict(unsigned_identity)
        identity["sha256"] = hashlib.sha256(
            subject.canonical_json_bytes(unsigned_identity) + b"\n"
        ).hexdigest()
        canonical_file(self.identity, identity)
        self.request_path = self.root / "mapper-cadence-request.json"
        self.runtime_digest = runtime_closure_digest(self.runtime)
        self.identity_digest = hashlib.sha256(self.identity.read_bytes()).hexdigest()

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def build(self, **overrides: object) -> dict[str, object]:
        arguments: dict[str, object] = {
            "scene_id": "city_square_private",
            "category": "large_area_exterior",
            "input_kind": "multi_video",
            "input_path": self.input,
            "scale": 250,
            "candidate_run_configuration": candidate_configuration(),
            "adapter_executable": self.adapter,
            "colmap_runtime_root": self.runtime,
            "colmap_runtime_closure_sha256": self.runtime_digest,
            "fixed_mapper_options": fixed_mapper_options(),
            "quality_thresholds": subject.QUALITY_THRESHOLDS,
            "source_git_commit": "a" * 40,
            "source_tree_state": "dirty",
            "measurement_runner_closure_identity": self.identity,
            "measurement_runner_closure_root": self.runner_closure,
            "xcode_version": "Xcode 16.4 (16F6)",
            "swift_version": "Swift version 6.1.2",
        }
        arguments.update(overrides)
        return subject.build_request(**arguments)

    def write(self, value: dict[str, object] | None = None) -> dict[str, object]:
        request = self.build() if value is None else value
        subject.write_request(self.request_path, request)
        return request

    def load(self, **overrides: object) -> dict[str, object]:
        arguments: dict[str, object] = {
            "input_path": self.input,
            "adapter_executable": self.adapter,
            "colmap_runtime_root": self.runtime,
            "colmap_runtime_closure_sha256": self.runtime_digest,
            "measurement_runner_closure_identity": self.identity,
            "measurement_runner_closure_root": self.runner_closure,
        }
        arguments.update(overrides)
        return subject.load_and_validate_request(self.request_path, **arguments)

    def rewrite_unsafe(self, value: object) -> None:
        self.request_path.write_bytes(subject.canonical_json_bytes(value) + b"\n")
        self.request_path.chmod(0o600)

    def test_city_square_request_binds_source_consumed_and_ignored_closures(self) -> None:
        request = self.write()
        loaded = self.load()
        self.assertEqual(loaded, request)
        self.assertEqual(request["schema_version"], 1)
        self.assertEqual(request["evidence_class"], "development_only")
        self.assertEqual(request["request_kind"], "mapper_cadence_ab")
        self.assertEqual(request["video_source_count"], 4)
        closure = request["input_closure"]
        assert isinstance(closure, dict)
        consumed = [f"DJI_{ordinal:04d}.MP4" for ordinal in range(1, 5)]
        ignored = [f"DJI_{ordinal:04d}.SRT" for ordinal in range(1, 5)]
        self.assertEqual(closure["consumed_media_paths"], consumed)
        self.assertEqual(
            closure["source_input_digest"],
            benchmark.digest_input(self.input, trusted_root=self.input),
        )
        self.assertEqual(
            closure["consumed_media_digest"], subset_digest(self.input, consumed)
        )
        ignored_manifest = closure["ignored_input_manifest"]
        assert isinstance(ignored_manifest, list)
        self.assertEqual(
            [entry["relative_path"] for entry in ignored_manifest], ignored
        )
        expected_ignored_digest = digest(
            subject.canonical_json_bytes(ignored_manifest).decode("utf-8")
        )
        self.assertEqual(
            closure["ignored_input_manifest_sha256"], expected_ignored_digest
        )
        self.assertNotIn(str(self.input), subject.canonical_json_bytes(request).decode())

    def test_request_binds_exact_schedule_options_thresholds_and_build(self) -> None:
        request = self.build()
        experiment = request["experiment"]
        assert isinstance(experiment, dict)
        self.assertEqual(experiment["warmup"], subject.WARMUP)
        self.assertEqual(experiment["measured_trials"], list(subject.MEASURED_SCHEDULE))
        self.assertEqual(experiment["deterministic_seed"], 42)
        self.assertEqual(
            experiment["fixed_mapper_options_sha256"],
            subject.fixed_mapper_options_sha256(fixed_mapper_options()),
        )
        schedule = {
            "warmup": subject.WARMUP,
            "measured_trials": list(subject.MEASURED_SCHEDULE),
        }
        self.assertEqual(
            experiment["cadence_schedule_sha256"],
            subject.sha256_canonical(schedule),
        )
        self.assertEqual(
            experiment["cadence_schedule_sha256"],
            "dbaca0655def6198950dbaa1cb31acf8b9f4b8a1fda090120682a073378046fb",
        )
        self.assertEqual(
            experiment["quality_thresholds_sha256"],
            subject.sha256_canonical(subject.QUALITY_THRESHOLDS),
        )
        self.assertEqual(
            experiment["quality_thresholds"][
                "maximum_within_arm_mapping_elapsed_range_seconds"
            ],
            30.0,
        )
        self.assertEqual(
            experiment["quality_thresholds_sha256"],
            "12e5e642381b5ced787f83471462dc8e9166b000d3f7f70be34bcdbc37f26ebc",
        )
        runtime = request["runtime_closure"]
        assert isinstance(runtime, dict)
        self.assertEqual(runtime["toolchain_provenance_status"], "local_adhoc_unsigned")
        self.assertEqual(runtime["colmap_runtime_closure_sha256"], self.runtime_digest)
        self.assertEqual(runtime["adapter_executable_bytes"], self.adapter.stat().st_size)
        self.assertEqual(runtime["adapter_executable_sha256"], subject.sha256_file(self.adapter))
        build = request["build_identity"]
        assert isinstance(build, dict)
        self.assertEqual(
            build["source_provenance_scope"], "binary_only_dirty_worktree"
        )
        self.assertEqual(build["source_tree_state"], "dirty")
        self.assertEqual(
            build["measurement_runner_closure_identity_sha256"],
            self.identity_digest,
        )

    def test_fixed_measured_schedule_is_mirrored_and_pair_balanced(self) -> None:
        trials = list(subject.MEASURED_SCHEDULE)
        cadences = [trial["mapper_cadence"] for trial in trials]

        self.assertEqual(len(trials), 8)
        self.assertEqual(cadences.count("frequent-global"), 4)
        self.assertEqual(cadences.count("balanced-global"), 4)
        self.assertEqual(cadences, list(reversed(cadences)))
        self.assertEqual(
            list(zip(cadences[::2], cadences[1::2], strict=True)),
            [
                ("frequent-global", "balanced-global"),
                ("balanced-global", "frequent-global"),
                ("frequent-global", "balanced-global"),
                ("balanced-global", "frequent-global"),
            ],
        )

    def test_fixed_option_binary_digest_matches_cross_language_vector(self) -> None:
        self.assertEqual(
            subject.fixed_mapper_options_sha256(fixed_mapper_options()),
            "b62c0ec3cc6d36e410fd99d021f4c710c8fc3b786f3293cd6ceae3eeb85b5a89",
        )

    def test_validation_rejects_source_input_mutation(self) -> None:
        self.write()
        (self.input / "DJI_0001.SRT").write_text("changed", encoding="utf-8")
        with self.assertRaisesRegex(subject.MapperCadenceRequestError, "source input digest"):
            self.load()

    def test_validation_reads_each_input_inode_exactly_once(self) -> None:
        self.write()
        expected = {
            (path.stat().st_dev, path.stat().st_ino): path.stat().st_size
            for path in self.input.iterdir()
        }
        opened = dict.fromkeys(expected, 0)
        bytes_read = dict.fromkeys(expected, 0)
        descriptor_identity: dict[int, tuple[int, int]] = {}
        real_open = os.open
        real_read = os.read
        real_close = os.close

        def tracking_open(*args: object, **kwargs: object) -> int:
            descriptor = real_open(*args, **kwargs)
            metadata = os.fstat(descriptor)
            identity = (metadata.st_dev, metadata.st_ino)
            if identity in expected:
                descriptor_identity[descriptor] = identity
                opened[identity] += 1
            return descriptor

        def tracking_read(descriptor: int, count: int) -> bytes:
            chunk = real_read(descriptor, count)
            identity = descriptor_identity.get(descriptor)
            if identity is not None:
                bytes_read[identity] += len(chunk)
            return chunk

        def tracking_close(descriptor: int) -> None:
            descriptor_identity.pop(descriptor, None)
            real_close(descriptor)

        with mock.patch.object(subject.os, "open", side_effect=tracking_open), mock.patch.object(
            subject.os, "read", side_effect=tracking_read
        ), mock.patch.object(
            subject.os, "close", side_effect=tracking_close
        ):
            self.load()

        self.assertEqual(opened, dict.fromkeys(expected, 1))
        self.assertEqual(bytes_read, expected)

    def test_validation_rejects_consumed_media_mutation_even_if_source_digest_is_rebound(
        self,
    ) -> None:
        request = self.write()
        (self.input / "DJI_0001.MP4").write_text("changed", encoding="utf-8")
        closure = request["input_closure"]
        assert isinstance(closure, dict)
        closure["source_input_digest"] = benchmark.digest_input(
            self.input, trusted_root=self.input
        )
        self.rewrite_unsafe(request)
        with self.assertRaisesRegex(subject.MapperCadenceRequestError, "consumed media digest"):
            self.load()

    def test_validation_rejects_adapter_mutation(self) -> None:
        self.write()
        self.adapter.write_text("#!/bin/sh\nexit 7\n", encoding="utf-8")
        with self.assertRaisesRegex(subject.MapperCadenceRequestError, "adapter executable"):
            self.load()

    def test_validation_rejects_runtime_and_runner_identity_mismatch(self) -> None:
        self.write()
        with self.assertRaisesRegex(subject.MapperCadenceRequestError, "COLMAP runtime"):
            self.load(colmap_runtime_closure_sha256=digest("other-runtime"))
        (self.runtime / "lib/libomp.dylib").write_bytes(b"mutated-openmp")
        with self.assertRaisesRegex(subject.MapperCadenceRequestError, "COLMAP runtime"):
            self.load()
        (self.runtime / "lib/libomp.dylib").write_bytes(b"fake-openmp")
        other_identity = self.root / "other-identity.json"
        other_identity.write_bytes(self.identity.read_bytes())
        other_identity.chmod(0o600)
        value = json.loads(other_identity.read_text(encoding="utf-8"))
        value["xcode_version"] = "Xcode 99"
        unsigned = {key: item for key, item in value.items() if key != "sha256"}
        value["sha256"] = hashlib.sha256(
            subject.canonical_json_bytes(unsigned) + b"\n"
        ).hexdigest()
        canonical_file(other_identity, value)
        with self.assertRaisesRegex(subject.MapperCadenceRequestError, "runner closure"):
            self.load(measurement_runner_closure_identity=other_identity)

    def test_validation_rejects_wrong_evidence_class_kind_and_provenance(self) -> None:
        base = self.build()
        cases = (
            ("evidence class", ("evidence_class",), "release"),
            ("request kind", ("request_kind",), "release_suite"),
            (
                "toolchain provenance",
                ("runtime_closure", "toolchain_provenance_status"),
                "signed_release",
            ),
        )
        for label, path, replacement in cases:
            with self.subTest(case=label):
                changed = copy.deepcopy(base)
                cursor: dict[str, object] = changed
                for component in path[:-1]:
                    nested = cursor[component]
                    assert isinstance(nested, dict)
                    cursor = nested
                cursor[path[-1]] = replacement
                self.rewrite_unsafe(changed)
                with self.assertRaises(subject.MapperCadenceRequestError):
                    self.load()

    def test_validation_rejects_schedule_configuration_seed_and_boolean_tampering(
        self,
    ) -> None:
        base = self.build()
        cases: tuple[tuple[str, tuple[str, ...], object], ...] = (
            (
                "schedule",
                ("experiment", "measured_trials"),
                list(reversed(subject.MEASURED_SCHEDULE)),
            ),
            (
                "configuration",
                ("candidate_run_configuration", "descriptor_matcher"),
                "exact",
            ),
            ("seed", ("experiment", "deterministic_seed"), 43),
            ("boolean scale", ("binding", "scale"), True),
            (
                "boolean config integer",
                ("candidate_run_configuration", "run_seed"),
                True,
            ),
        )
        for label, path, replacement in cases:
            with self.subTest(case=label):
                changed = copy.deepcopy(base)
                cursor: dict[str, object] = changed
                for component in path[:-1]:
                    nested = cursor[component]
                    assert isinstance(nested, dict)
                    cursor = nested
                cursor[path[-1]] = replacement
                self.rewrite_unsafe(changed)
                with self.assertRaises(subject.MapperCadenceRequestError):
                    self.load()

    def test_build_rejects_unknown_config_fields_and_inconsistent_topology(self) -> None:
        configuration = candidate_configuration()
        configuration["mystery"] = 1
        with self.assertRaisesRegex(subject.MapperCadenceRequestError, "invalid fields"):
            self.build(candidate_run_configuration=configuration)
        configuration = candidate_configuration()
        configuration["input_topology"] = "continuous"
        with self.assertRaisesRegex(subject.MapperCadenceRequestError, "topology"):
            self.build(candidate_run_configuration=configuration)
        configuration = candidate_configuration()
        configuration["capture_path"] = "automatic"
        with self.assertRaisesRegex(subject.MapperCadenceRequestError, "capture path"):
            self.build(candidate_run_configuration=configuration)

    def test_build_rejects_boolean_integer_and_nonfinite_number(self) -> None:
        configuration = candidate_configuration()
        configuration["run_seed"] = True
        with self.assertRaisesRegex(subject.MapperCadenceRequestError, "run_seed"):
            self.build(candidate_run_configuration=configuration)
        options = fixed_mapper_options()
        options["global_function_tolerance"] = float("nan")
        with self.assertRaisesRegex(subject.MapperCadenceRequestError, "finite"):
            self.build(fixed_mapper_options=options)

    def test_load_rejects_duplicate_keys_nonfinite_and_noncanonical_json(self) -> None:
        request = self.build()
        raw = subject.canonical_json_bytes(request) + b"\n"
        duplicated = raw.replace(
            b'{"binding":', b'{"schema_version":1,"binding":', 1
        )
        self.request_path.write_bytes(duplicated)
        self.request_path.chmod(0o600)
        with self.assertRaisesRegex(subject.MapperCadenceRequestError, "duplicate key"):
            self.load()
        nonfinite = raw.replace(b'"scale":250', b'"scale":NaN', 1)
        self.request_path.write_bytes(nonfinite)
        with self.assertRaisesRegex(subject.MapperCadenceRequestError, "non-finite"):
            self.load()
        self.request_path.write_text(json.dumps(request, indent=2), encoding="utf-8")
        with self.assertRaisesRegex(subject.MapperCadenceRequestError, "canonical JSON"):
            self.load()

    def test_writer_is_atomic_private_and_never_overwrites(self) -> None:
        request = self.build()
        subject.write_request(self.request_path, request)
        self.assertEqual(stat.S_IMODE(self.request_path.stat().st_mode), 0o600)
        self.assertEqual(
            self.request_path.read_bytes(), subject.canonical_json_bytes(request) + b"\n"
        )
        with self.assertRaisesRegex(subject.MapperCadenceRequestError, "already exists"):
            subject.write_request(self.request_path, request)
        self.assertEqual(
            self.request_path.read_bytes(), subject.canonical_json_bytes(request) + b"\n"
        )
        self.assertEqual(
            [path for path in self.root.iterdir() if path.name.startswith(".request-")],
            [],
        )

    def test_load_rejects_nonprivate_or_hardlinked_request(self) -> None:
        self.write()
        self.request_path.chmod(0o644)
        with self.assertRaisesRegex(subject.MapperCadenceRequestError, "mode 0600"):
            self.load()

        self.request_path.chmod(0o600)
        os.link(self.request_path, self.root / "request-hardlink.json")
        with self.assertRaisesRegex(subject.MapperCadenceRequestError, "one hard link"):
            self.load()

    def test_build_rejects_hardlinked_input(self) -> None:
        os.link(
            self.input / "DJI_0001.SRT",
            self.input / "DJI_0001-copy.SRT",
        )
        with self.assertRaisesRegex(subject.MapperCadenceRequestError, "single-link"):
            self.build()

    def test_build_rejects_hardlinked_adapter(self) -> None:
        adapter_hardlink = self.root / "adapter-hardlink"
        os.link(self.adapter, adapter_hardlink)
        with self.assertRaisesRegex(subject.MapperCadenceRequestError, "one hard link"):
            self.build(adapter_executable=adapter_hardlink)

    def test_build_rejects_hardlinked_runtime_component(self) -> None:
        os.link(
            self.runtime / "lib/libomp.dylib",
            self.runtime / "lib/libomp-hardlink.dylib",
        )
        with self.assertRaisesRegex(subject.MapperCadenceRequestError, "single-link"):
            self.build()

    def test_rejects_symlinked_or_non_owned_paths(self) -> None:
        input_link = self.root / "input-link"
        input_link.symlink_to(self.input)
        with self.assertRaisesRegex(subject.MapperCadenceRequestError, "symbolic link"):
            self.build(input_path=input_link)
        adapter_link = self.root / "adapter-link"
        adapter_link.symlink_to(self.adapter)
        with self.assertRaisesRegex(subject.MapperCadenceRequestError, "symbolic link"):
            self.build(adapter_executable=adapter_link)
        self.write()
        request_link = self.root / "request-link.json"
        request_link.symlink_to(self.request_path)
        with self.assertRaisesRegex(subject.MapperCadenceRequestError, "symbolic link"):
            subject.load_and_validate_request(
                request_link,
                input_path=self.input,
                adapter_executable=self.adapter,
                colmap_runtime_root=self.runtime,
                colmap_runtime_closure_sha256=self.runtime_digest,
                measurement_runner_closure_root=self.runner_closure,
            )
        with mock.patch("os.getuid", return_value=os.getuid() + 1):
            with self.assertRaisesRegex(subject.MapperCadenceRequestError, "current user"):
                self.build()

    def test_writer_rejects_symlinked_output_parent(self) -> None:
        real_parent = self.root / "real-output"
        real_parent.mkdir(mode=0o700)
        linked_parent = self.root / "linked-output"
        linked_parent.symlink_to(real_parent)
        with self.assertRaisesRegex(subject.MapperCadenceRequestError, "symbolic link"):
            subject.write_request(linked_parent / "request.json", self.build())

    def test_build_rejects_symlinked_runtime_component_directory(self) -> None:
        real_bin = self.runtime / "real-bin"
        (self.runtime / "bin").rename(real_bin)
        (self.runtime / "bin").symlink_to(real_bin, target_is_directory=True)
        with self.assertRaisesRegex(subject.MapperCadenceRequestError, "symbolic link"):
            self.build()

    def test_build_rejects_runner_identity_for_a_different_adapter(self) -> None:
        identity = json.loads(self.identity.read_text(encoding="utf-8"))
        identity["files"]["PipelineMeasurementAdapter-current"]["sha256"] = digest(
            "different-adapter"
        )
        unsigned = {key: value for key, value in identity.items() if key != "sha256"}
        identity["sha256"] = hashlib.sha256(
            subject.canonical_json_bytes(unsigned) + b"\n"
        ).hexdigest()
        canonical_file(self.identity, identity)
        with self.assertRaisesRegex(subject.MapperCadenceRequestError, "runner closure"):
            self.build()

    def test_build_rejects_runner_identity_when_any_live_closure_file_differs(self) -> None:
        (self.runner_closure / "PipelineMeasurementAdapter-baseline").write_text(
            "#!/bin/sh\nexit 9\n", encoding="utf-8"
        )
        with self.assertRaisesRegex(subject.MapperCadenceRequestError, "runner closure"):
            self.build()

    def test_build_rejects_non_video_single_input(self) -> None:
        text_input = self.root / "not-a-video.txt"
        text_input.write_text("not media", encoding="utf-8")
        configuration = candidate_configuration()
        configuration.update(
            {
                "input_topology": "continuous",
                "pairing_policy": "large_area",
                "temporal_pairing": "multiscale",
                "temporal_offsets": [1, 2, 4, 8, 16, 32, 64, 128],
                "vocabulary_returned_neighbor_count": 4,
                "vocabulary_query_stride": 10,
                "ba_global_frames_ratio": 4.0,
                "ba_global_points_ratio": 4.0,
                "ba_local_max_refinements": 1,
            }
        )
        options = fixed_mapper_options()
        options["local_max_refinements"] = 1
        with self.assertRaisesRegex(subject.MapperCadenceRequestError, "video extension"):
            self.build(
                input_kind="video",
                input_path=text_input,
                candidate_run_configuration=configuration,
                fixed_mapper_options=options,
            )

    def test_optional_runner_closure_identity_must_be_bound_consistently(self) -> None:
        request = self.build(
            measurement_runner_closure_identity=None,
            measurement_runner_closure_root=None,
        )
        self.write(request)
        self.load(
            measurement_runner_closure_identity=None,
            measurement_runner_closure_root=None,
        )
        with self.assertRaisesRegex(subject.MapperCadenceRequestError, "runner closure"):
            self.load(measurement_runner_closure_identity=self.identity)

    def test_cli_creates_then_validates_the_same_private_request(self) -> None:
        configuration_path = self.root / "candidate.json"
        options_path = self.root / "mapper-options.json"
        canonical_file(configuration_path, candidate_configuration())
        canonical_file(options_path, fixed_mapper_options())
        create_arguments = [
            "create",
            "--input",
            str(self.input),
            "--scene-id",
            "city_square_private",
            "--category",
            "large_area_exterior",
            "--input-kind",
            "multi_video",
            "--scale",
            "250",
            "--candidate-configuration",
            str(configuration_path),
            "--fixed-mapper-options",
            str(options_path),
            "--adapter-executable",
            str(self.adapter),
            "--colmap-runtime-root",
            str(self.runtime),
            "--colmap-runtime-closure-sha256",
            self.runtime_digest,
            "--source-git-commit",
            "a" * 40,
            "--source-tree-state",
            "dirty",
            "--measurement-runner-closure-identity",
            str(self.identity),
            "--measurement-runner-closure-root",
            str(self.runner_closure),
            "--xcode-version",
            "Xcode 16.4 (16F6)",
            "--swift-version",
            "Swift version 6.1.2",
            "--output",
            str(self.request_path),
        ]
        stdout = StringIO()
        with redirect_stdout(stdout), redirect_stderr(StringIO()):
            self.assertEqual(subject.main(create_arguments), 0)
        status = json.loads(stdout.getvalue())
        self.assertEqual(status["status"], "created")
        validate_arguments = [
            "validate",
            "--request",
            str(self.request_path),
            "--input",
            str(self.input),
            "--adapter-executable",
            str(self.adapter),
            "--colmap-runtime-root",
            str(self.runtime),
            "--colmap-runtime-closure-sha256",
            self.runtime_digest,
            "--measurement-runner-closure-identity",
            str(self.identity),
            "--measurement-runner-closure-root",
            str(self.runner_closure),
        ]
        stdout = StringIO()
        with redirect_stdout(stdout), redirect_stderr(StringIO()):
            self.assertEqual(subject.main(validate_arguments), 0)
        status = json.loads(stdout.getvalue())
        self.assertEqual(status["status"], "valid")
        self.assertEqual(status["evidence_class"], "development_only")


if __name__ == "__main__":
    unittest.main()
