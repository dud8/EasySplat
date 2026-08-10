import hashlib
import json
import itertools
import importlib.util
import os
import stat
import subprocess
import tempfile
import unittest
from pathlib import Path

from scripts.benchmark import evidence_protocol as evidence


ROOT = Path(__file__).resolve().parents[3]
SCRIPT = ROOT / "scripts/benchmark/measurement_runner_closure.py"
ADAPTER_SOURCE = (
    ROOT / "Tools/MeasurementRunner/Adapters/PipelineMeasurementAdapter.swift"
)
SUPPORT_SOURCE = (
    ROOT
    / "Tools/MeasurementRunner/Sources/MeasurementAdapterSupport/MeasurementAdapterSupport.swift"
)
ADAPTER_BUILDER = ROOT / "scripts/benchmark/build_measurement_adapters.py"
RUNNER_SOURCE = ROOT / "Tools/MeasurementRunner/Sources/MeasurementRunner/main.swift"
RUN_PLAN_TEST_SOURCE = (
    ROOT / "EasySplatCore/Tests/EasySplatCoreTests/RunPlanResolverTests.swift"
)
PAIR_GRAPH_STORE_SOURCE = (
    ROOT / "EasySplatCore/Sources/EasySplatCore/SfM/PairGraphEvidenceStore.swift"
)
PAIR_LIST_BUILDER_SOURCE = (
    ROOT
    / "Tools/MeasurementRunner/Sources/MeasurementRunnerCore/MeasurementPairListBuilder.swift"
)
MEASUREMENT_RUNNER_CORE_SOURCE = (
    ROOT
    / "Tools/MeasurementRunner/Sources/MeasurementRunnerCore/MeasurementRunnerCore.swift"
)

ADAPTER_BUILDER_SPEC = importlib.util.spec_from_file_location(
    "build_measurement_adapters", ADAPTER_BUILDER
)
assert ADAPTER_BUILDER_SPEC is not None
assert ADAPTER_BUILDER_SPEC.loader is not None
adapter_builder = importlib.util.module_from_spec(ADAPTER_BUILDER_SPEC)
ADAPTER_BUILDER_SPEC.loader.exec_module(adapter_builder)


class MeasurementRunnerClosureTests(unittest.TestCase):
    @staticmethod
    def _git(checkout: Path, *arguments: str) -> str:
        completed = subprocess.run(
            ["/usr/bin/git", "-C", str(checkout), *arguments],
            check=True,
            text=True,
            capture_output=True,
            env={"PATH": "/usr/bin:/bin"},
        )
        return completed.stdout.strip()

    def _checkout_fixture(self, root: Path) -> tuple[Path, str]:
        checkout = root / "checkout"
        checkout.mkdir()
        self._git(checkout, "init", "--quiet")
        self._git(checkout, "config", "user.name", "EasySplat Tests")
        self._git(checkout, "config", "user.email", "tests@easysplat.invalid")
        (checkout / "tracked.swift").write_text("let value = 0\n", encoding="utf-8")
        self._git(checkout, "add", "tracked.swift")
        self._git(checkout, "commit", "--quiet", "-m", "fixture")
        return checkout, self._git(checkout, "rev-parse", "HEAD")

    def _compile_pair_list_builder_probe(self, root: Path) -> Path:
        support = root / "PairListBuilderProbe.swift"
        support.write_text(
            """
import Foundation

@main
private struct PairListBuilderProbe {
  static func main() throws {
    guard CommandLine.arguments.count == 4,
      let selectedFrameCount = Int(CommandLine.arguments[2])
    else { throw MeasurementRunnerError.subprocessFailed("invalid probe arguments") }
    _ = try MeasurementPairListBuilder.write(
      source: URL(fileURLWithPath: CommandLine.arguments[1]),
      selectedFrameCount: selectedFrameCount,
      to: URL(fileURLWithPath: CommandLine.arguments[3])
    )
  }
}
""",
            encoding="utf-8",
        )
        executable = root / "PairListBuilderProbe"
        subprocess.run(
            [
                "/usr/bin/swiftc",
                "-parse-as-library",
                str(MEASUREMENT_RUNNER_CORE_SOURCE),
                str(PAIR_LIST_BUILDER_SOURCE),
                str(support),
                "-o",
                str(executable),
            ],
            check=True,
            text=True,
            capture_output=True,
        )
        return executable

    @staticmethod
    def _pair_graph_exact_recovery_fixture() -> dict[str, object]:
        image_names = ["a.jpg", "b.jpg", "c.jpg", "d.jpg"]
        image_group_lines = [
            "a.jpg\t0",
            "b.jpg\t0",
            "c.jpg\t1",
            "d.jpg\t1",
        ]

        def receipt_digest(fields: list[str]) -> str:
            hasher = hashlib.sha256()
            for field in fields:
                encoded = field.encode("utf-8")
                hasher.update(f"{len(encoded)}:".encode("utf-8"))
                hasher.update(encoded)
            return hasher.hexdigest()

        image_group_list_digest = receipt_digest(
            ["crossGroupV1", *image_group_lines]
        )
        request_digest = receipt_digest(
            [
                "localSiftVocabularyV2",
                "2",
                "20",
                "8",
                "0",
                "crossGroupV1",
                image_group_list_digest,
                "a.jpg",
                "c.jpg",
            ]
        )
        output_digest = receipt_digest(
            [
                (
                    "EASYSPLAT_RETRIEVAL_OUTCOMES_V3 localSiftVocabularyV2 "
                    "2 20 8 0 crossGroupV1 "
                    f"{image_group_list_digest} 2 {request_digest}"
                ),
                "Q ranked a.jpg 1 d.jpg",
                "Q noRankedNeighbors c.jpg 0",
                "P a.jpg d.jpg",
            ]
        )
        pairs = [
            {"firstImageName": "a.jpg", "secondImageName": "b.jpg", "role": "local"},
            {
                "firstImageName": "a.jpg",
                "secondImageName": "d.jpg",
                "role": "retrieval",
            },
            {"firstImageName": "c.jpg", "secondImageName": "d.jpg", "role": "local"},
        ]
        pair_digest = hashlib.sha256(
            b"a.jpg b.jpg\na.jpg d.jpg\nc.jpg d.jpg\n"
        ).hexdigest()
        retrieval = {
            "engine": "localSiftVocabularyV2",
            "queryImageNames": ["a.jpg", "c.jpg"],
            "queryStride": 2,
            "candidateCount": 20,
            "returnedNeighborCount": 8,
            "minimumFrameSeparation": 0,
            "candidatePolicy": "crossGroupV1",
            "imageGroupListDigest": image_group_list_digest,
            "imageGroupLines": image_group_lines,
            "queryOutcomes": [
                {
                    "queryImageName": "a.jpg",
                    "status": "ranked",
                    "rankedNeighborImageNames": ["d.jpg"],
                },
                {
                    "queryImageName": "c.jpg",
                    "status": "noRankedNeighbors",
                    "rankedNeighborImageNames": [],
                },
            ],
            "directedPairLines": ["a.jpg d.jpg"],
            "outputDigest": output_digest,
        }
        completed_artifact = {
            "attemptNumber": 2,
            "matcher": "exact",
            "exactRecoveryReason": "faissCrash",
            "recoveryLevel": "normal",
            "outcome": "completed",
            "scheduledPairCount": 3,
            "attemptedPairCount": 3,
            "rawMatchedPairCount": 3,
            "spatiallyVerifiedPairCount": 3,
            "durationSeconds": 1.25,
        }
        failed_artifact = {
            **completed_artifact,
            "attemptNumber": 1,
            "matcher": "faiss",
            "exactRecoveryReason": None,
            "outcome": "failed",
            "attemptedPairCount": 0,
            "rawMatchedPairCount": 0,
            "spatiallyVerifiedPairCount": 0,
            "durationSeconds": 0.25,
        }
        return {
            "schemaVersion": 20,
            "selectedFramesDigest": "1" * 64,
            "imageNames": image_names,
            "pairingPolicy": "segmentedMixed",
            "planBinding": {
                "pairingPolicy": "segmentedMixed",
                "geometryBackend": "colmap",
                "modelIdentifier": "none",
                "temporalPairing": "linear",
                "temporalOffsets": [1],
                "retrievalEngine": "localSiftVocabularyV2",
                "retrievalCandidateCount": 20,
                "retrievalNeighborCount": 8,
                "retrievalQueryStride": 2,
                "requiresCrossClipRetrieval": True,
                "normalDescriptorMatcher": "faiss",
                "cameraInitializationRecipe": "colmapAutomatic",
                "runSeed": 42,
            },
            "attempts": [
                {
                    "artifact": failed_artifact,
                    "scheduledPairs": pairs,
                    "retrieval": retrieval,
                    "retrievalWasExecuted": True,
                },
                {
                    "artifact": completed_artifact,
                    "scheduledPairs": pairs,
                    "retrieval": retrieval,
                    "retrievalWasExecuted": False,
                },
            ],
            "acceptedAttemptNumber": 2,
            "acceptedInspection": {
                "scheduledPairCount": 3,
                "attemptedPairCount": 3,
                "rawMatchedPairCount": 3,
                "spatiallyVerifiedPairCount": 3,
                "localPairCount": 2,
                "retrievalPairCount": 1,
                "loopRevisitPairCount": 0,
                "connectedComponentCount": 1,
                "isolatedViewCount": 0,
                "descriptorlessViewCount": 0,
                "componentViewCounts": [4],
                "articulationViewCount": 2,
                "biconnectedBlockCount": 3,
                "largestBiconnectedBlockViewCount": 2,
                "secondLargestBiconnectedBlockViewCount": 2,
                "degreeP10": 1,
                "degreeMedian": 1,
                "degreeP90": 2,
                "featureDatabaseDigest": "2" * 64,
                "matchingDatabaseDigest": "3" * 64,
                "attemptedPairs": pairs,
                "rawMatchedPairs": pairs,
                "spatiallyVerifiedPairs": pairs,
            },
            "retrievalWasScheduled": True,
            "usedLocalVocabularyRetrieval": True,
            "pairListDigest": pair_digest,
            "matchingDurationSeconds": 1.5,
            "fallbackReasons": ["FAISS crashed"],
        }

    def test_python_accepts_actual_swift_pair_list_v2_receipt_and_exact_retry(
        self,
    ) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = root / "pair_graph_evidence.json"
            destination = root / "pair-list.json"
            source.write_bytes(
                evidence.canonical_json_bytes(self._pair_graph_exact_recovery_fixture())
                + b"\n"
            )
            probe = self._compile_pair_list_builder_probe(root)
            subprocess.run(
                [str(probe), str(source), "4", str(destination)],
                check=True,
                text=True,
                capture_output=True,
            )

            selection = evidence.SelectionManifestSources(
                image_names=("a.jpg", "b.jpg", "c.jpg", "d.jpg"),
                clip_ids=("clip-a", "clip-a", "clip-b", "clip-b"),
                source_kinds=("video", "video", "video", "video"),
                video_source_count=2,
            )
            configuration = {
                "input_topology": "segmented_mixed",
                "pairing_policy": "segmented_mixed",
                "temporal_offsets": [1],
                "vocabulary_candidate_count": 20,
                "vocabulary_returned_neighbor_count": 8,
                "vocabulary_query_stride": 2,
            }
            metrics = {
                "scheduled_pairs": 3,
                "attempted_pairs": 3,
                "raw_matched_pairs": 3,
                "spatially_verified_pairs": 3,
                "local_pairs": 2,
                "retrieval_pairs": 1,
                "loop_pairs": 0,
                "connected_components": 1,
                "isolated_views": 0,
                "articulation_views": 2,
                "biconnected_blocks": 3,
                "largest_biconnected_block_views": 2,
                "second_largest_biconnected_block_views": 2,
            }
            digest = evidence._validate_pair_list(
                destination, 4, selection, configuration, metrics
            )
            self.assertRegex(digest, r"^sha256:[0-9a-f]{64}$")
            pair_list = json.loads(destination.read_bytes())
            self.assertEqual(pair_list["schema_version"], 5)
            self.assertTrue(pair_list["attempts"][0]["retrieval"]["executed"])
            self.assertFalse(pair_list["attempts"][1]["retrieval"]["executed"])

    def test_dirty_adapter_checkout_requires_explicit_opt_in(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            checkout, commit = self._checkout_fixture(Path(directory))
            (checkout / "tracked.swift").write_text("let value = 1\n", encoding="utf-8")

            with self.assertRaisesRegex(adapter_builder.BuildError, "must be clean"):
                adapter_builder.require_checkout(checkout, commit)

            evidence = adapter_builder.require_checkout(
                checkout, commit, allow_dirty=True
            )
            self.assertRegex(evidence, r"^dirty:[0-9a-f]{64}$")

    def test_dirty_adapter_checkout_evidence_binds_changed_and_untracked_bytes(
        self,
    ) -> None:
        with tempfile.TemporaryDirectory() as directory:
            checkout, commit = self._checkout_fixture(Path(directory))
            tracked = checkout / "tracked.swift"
            tracked.write_text("let value = 1\n", encoding="utf-8")
            first = adapter_builder.require_checkout(checkout, commit, allow_dirty=True)

            tracked.write_text("let value = 2\n", encoding="utf-8")
            second = adapter_builder.require_checkout(
                checkout, commit, allow_dirty=True
            )
            self.assertNotEqual(first, second)
            self.assertEqual(
                self._git(checkout, "status", "--porcelain", "--untracked-files=all"),
                "M tracked.swift",
            )

            untracked = checkout / "new.swift"
            untracked.write_text("let newValue = 1\n", encoding="utf-8")
            third = adapter_builder.require_checkout(checkout, commit, allow_dirty=True)
            untracked.write_text("let newValue = 2\n", encoding="utf-8")
            fourth = adapter_builder.require_checkout(
                checkout, commit, allow_dirty=True
            )
            self.assertNotEqual(second, third)
            self.assertNotEqual(third, fourth)

    def test_dirty_adapter_checkout_must_remain_unchanged_during_build(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            checkout, commit = self._checkout_fixture(Path(directory))
            tracked = checkout / "tracked.swift"
            tracked.write_text("let value = 1\n", encoding="utf-8")
            expected = adapter_builder.require_checkout(
                checkout, commit, allow_dirty=True
            )

            tracked.write_text("let value = 2\n", encoding="utf-8")
            with self.assertRaisesRegex(
                adapter_builder.BuildError, "changed during adapter build"
            ):
                adapter_builder.require_unchanged_checkout(
                    checkout,
                    commit,
                    expected_state=expected,
                    allow_dirty=True,
                )

    def test_dirty_adapter_opt_in_is_current_checkout_only(self) -> None:
        builder = ADAPTER_BUILDER.read_text(encoding="utf-8")

        self.assertIn("--allow-dirty-current-checkout", builder)
        self.assertNotIn("--allow-dirty-baseline", builder)

    def _compile_adapter_argument_probe(
        self, root: Path, compile_time_variant: str
    ) -> Path:
        source = ADAPTER_SOURCE.read_text(encoding="utf-8")
        parser_source = source[: source.index("func mapping(")].replace(
            "@testable import EasySplatCore\n", ""
        )
        probe = root / f"AdapterArguments-{compile_time_variant}.swift"
        probe.write_text(
            parser_source
            + """
@main
private struct AdapterArgumentsProbe {
  static func main() {
    do {
      let parsed = try AdapterArguments.parse(CommandLine.arguments)
      print(
        "geometry=\\(parsed.geometryOnly) matching=\\(parsed.matchingOnly) "
          + "mapping=\\(parsed.mappingFromCheckpoint != nil) "
          + "cadence=\\(parsed.mapperCadence ?? \"none\") "
          + "trial=\\(parsed.trialRoot?.path ?? \"none\")"
      )
    } catch {
      FileHandle.standardError.write(Data("\\(error.localizedDescription)\\n".utf8))
      Foundation.exit(1)
    }
  }
}
""",
            encoding="utf-8",
        )
        executable = root / f"AdapterArguments-{compile_time_variant}"
        subprocess.run(
            [
                "/usr/bin/swiftc",
                "-parse-as-library",
                "-D",
                compile_time_variant,
                str(probe),
                "-o",
                str(executable),
            ],
            check=True,
            text=True,
            capture_output=True,
        )
        return executable

    def _compile_json_integer_probe(self, root: Path) -> Path:
        source = ADAPTER_SOURCE.read_text(encoding="utf-8")
        integer_source = source[: source.index("func files(")].replace(
            "@testable import EasySplatCore\n", ""
        )
        probe = root / "AdapterJSONIntegerProbe.swift"
        probe.write_text(
            integer_source
            + """
@main
private struct AdapterJSONIntegerProbe {
  static func main() {
    do {
      let value = try JSONSerialization.jsonObject(
        with: Data(CommandLine.arguments[1].utf8),
        options: [.fragmentsAllowed]
      )
      if CommandLine.arguments[2] == "holdout_indices" {
        _ = try integerArray(value, "holdout_indices")
      } else {
        _ = try integer(value, CommandLine.arguments[2])
      }
    } catch {
      FileHandle.standardError.write(Data("\\(error.localizedDescription)\\n".utf8))
      Foundation.exit(1)
    }
  }
}
""",
            encoding="utf-8",
        )
        executable = root / "AdapterJSONIntegerProbe"
        subprocess.run(
            [
                "/usr/bin/swiftc",
                "-parse-as-library",
                "-D",
                "CURRENT_ADAPTER",
                str(probe),
                "-o",
                str(executable),
            ],
            check=True,
            text=True,
            capture_output=True,
        )
        return executable

    def _compile_exact_directory_tree_probe(self, root: Path) -> Path:
        source = ADAPTER_SOURCE.read_text(encoding="utf-8")
        helper_start = source.index("func requireExactDirectoryTree(")
        helper_end = source.index(
            "\n  func requireCleanMatchingArtifactClosure(", helper_start
        )
        helper = source[helper_start:helper_end]
        probe = root / "ExactDirectoryTreeProbe.swift"
        probe.write_text(
            """
import Foundation
import Darwin

private enum AdapterError: LocalizedError {
  case pipelineFailed(String)

  var errorDescription: String? {
    switch self {
    case .pipelineFailed(let message): message
    }
  }
}

"""
            + helper
            + """

@main
private struct ExactDirectoryTreeProbe {
  static func main() {
    do {
      let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
      let acceptsAbsent = CommandLine.arguments.dropFirst(2).first == "--allow-absent"
      var index = acceptsAbsent ? 3 : 2
      var expectedDirectories = Set<String>()
      var expectedFiles = Set<String>()
      while index < CommandLine.arguments.count {
        if CommandLine.arguments[index] == "--file" {
          guard index + 1 < CommandLine.arguments.count else {
            throw AdapterError.pipelineFailed("missing expected file name")
          }
          expectedFiles.insert(CommandLine.arguments[index + 1])
          index += 2
        } else {
          expectedDirectories.insert(CommandLine.arguments[index])
          index += 1
        }
      }
      if acceptsAbsent {
        try requireAbsentOrExactDirectoryTree(
          root: root,
          expectedDirectories: expectedDirectories,
          label: "probe"
        )
      } else {
        try requireExactDirectoryTree(
          root: root,
          expectedDirectories: expectedDirectories,
          expectedFiles: expectedFiles,
          label: "probe"
        )
      }
    } catch {
      FileHandle.standardError.write(Data("\\(error.localizedDescription)\\n".utf8))
      Foundation.exit(1)
    }
  }
}
""",
            encoding="utf-8",
        )
        executable = root / "ExactDirectoryTreeProbe"
        subprocess.run(
            [
                "/usr/bin/swiftc",
                "-parse-as-library",
                str(probe),
                "-o",
                str(executable),
            ],
            check=True,
            text=True,
            capture_output=True,
        )
        return executable

    def _compile_evidence_binding_probe(self, root: Path) -> Path:
        source = ADAPTER_SOURCE.read_text(encoding="utf-8")
        binding_start = source.index("final class MeasurementEvidenceFileBinding")
        binding_end = source.index(
            "\n  struct AuthenticatedMapperCadenceTrial", binding_start
        )
        binding = source[binding_start:binding_end]
        probe = root / "EvidenceBindingProbe.swift"
        probe.write_text(
            """
import CryptoKit
import Darwin
import Foundation

private enum AdapterError: LocalizedError {
  case pipelineFailed(String)

  var errorDescription: String? {
    switch self {
    case .pipelineFailed(let message): message
    }
  }
}

"""
            + binding
            + """

@main
private struct EvidenceBindingProbe {
  static func main() {
    do {
      let url = URL(fileURLWithPath: CommandLine.arguments[1])
      let binding = try MeasurementEvidenceFileBinding(
        url: url,
        maximumBytes: 1_048_576
      )
      switch CommandLine.arguments[2] {
      case "verify":
        guard try binding.dataSnapshot() == Data(CommandLine.arguments[3].utf8) else {
          throw AdapterError.pipelineFailed("evidence bytes differ")
        }
      case "mutate":
        try Data("changed-after-binding".utf8).write(to: url, options: .atomic)
        try binding.revalidate()
      default:
        throw AdapterError.pipelineFailed("unknown probe mode")
      }
    } catch {
      FileHandle.standardError.write(Data("\\(error.localizedDescription)\\n".utf8))
      Foundation.exit(1)
    }
  }
}
""",
            encoding="utf-8",
        )
        executable = root / "EvidenceBindingProbe"
        subprocess.run(
            [
                "/usr/bin/swiftc",
                "-parse-as-library",
                str(probe),
                "-o",
                str(executable),
            ],
            check=True,
            text=True,
            capture_output=True,
        )
        return executable

    @staticmethod
    def _adapter_arguments(*extra: str, variant: str = "candidate") -> list[str]:
        return [
            "--request",
            "/private/tmp/request.json",
            "--input",
            "/private/tmp/input",
            "--toolchain-root",
            "/private/tmp/toolchain",
            "--project-root",
            "/private/tmp/project.easysplatproj",
            "--variant",
            variant,
            "--output",
            "/private/tmp/output.json",
            *extra,
        ]

    def test_accurate_reference_is_a_separate_compile_time_locked_worker(self) -> None:
        source = ADAPTER_SOURCE.read_text(encoding="utf-8")
        builder = ADAPTER_BUILDER.read_text(encoding="utf-8")
        self.assertIn("#if ACCURATE_REFERENCE", source)
        self.assertIn("descriptorMatcher: .exact", source)
        self.assertIn("plan.trainerIterationLimit = 30_000", source)
        self.assertIn("AccurateReferenceMeasurementAdapter", builder)
        self.assertIn('.define("ACCURATE_REFERENCE")', builder)
        self.assertIn('"--disable-sandbox"', builder)

    def test_each_pipeline_worker_is_compile_time_locked_to_its_variant(self) -> None:
        source = ADAPTER_SOURCE.read_text(encoding="utf-8")
        builder = ADAPTER_BUILDER.read_text(encoding="utf-8")

        self.assertIn("#if BASELINE_ADAPTER", source)
        self.assertIn('values["--variant"] == "baseline"', source)
        self.assertIn('values["--variant"] == "candidate"', source)
        self.assertIn('values["--variant"] == "fast_candidate"', source)
        self.assertIn('.define("CURRENT_ADAPTER")', builder)
        self.assertIn('.define("BASELINE_ADAPTER")', builder)
        self.assertIn('.define("ACCURATE_REFERENCE")', builder)

    def test_adapter_rejects_every_zero_or_multi_variant_definition(self) -> None:
        variants = ("CURRENT_ADAPTER", "BASELINE_ADAPTER", "ACCURATE_REFERENCE")
        source = ADAPTER_SOURCE.read_text(encoding="utf-8")
        guard_start = source.index("#if !CURRENT_ADAPTER")
        guard_end = source.index("#endif", guard_start) + len("#endif")
        variant_guard = source[guard_start:guard_end]
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            guard_source = root / "MeasurementAdapterVariantGuard.swift"
            guard_source.write_text(
                variant_guard + "\nprivate enum MeasurementAdapterVariantGuard {}\n",
                encoding="utf-8",
            )

            for count in range(4):
                for enabled in itertools.combinations(variants, count):
                    command = ["/usr/bin/swiftc", "-typecheck"]
                    for variant in enabled:
                        command.extend(["-D", variant])
                    command.append(str(guard_source))
                    completed = subprocess.run(command, text=True, capture_output=True)
                    if count == 1:
                        self.assertEqual(
                            completed.returncode, 0, (enabled, completed.stderr)
                        )
                    else:
                        self.assertNotEqual(completed.returncode, 0, enabled)
                        self.assertIn(
                            "Exactly one measurement adapter variant must be defined",
                            completed.stderr,
                        )

    def test_pipeline_adapter_uses_the_bound_run_seed(self) -> None:
        source = ADAPTER_SOURCE.read_text(encoding="utf-8")

        self.assertIn("benchmarkSeed: Int(plan.runSeed)", source)
        self.assertIn(
            'let seed = try integer(configuration["run_seed"], "run_seed")', source
        )
        self.assertIn(
            "DevelopmentOverrides(candidateRoute: .colmap, benchmarkSeed: seed)", source
        )
        self.assertIn("configuration: configuration", source)
        self.assertNotIn("benchmarkSeed: Int(plan.keyframeBudget)", source)

    def test_current_request_is_validated_before_any_input_admission(self) -> None:
        source = ADAPTER_SOURCE.read_text(encoding="utf-8")

        validation = source.index(
            "try RunPlanResolver.validate(\n"
            "          requestedOptions: options,\n"
            "          input: input,\n"
            "          hardware: hardware\n"
            "        )"
        )
        admission = source.index("try await publishCurrentMeasurementProject(")
        self.assertLess(validation, admission)
        baseline_start = source.index("#if BASELINE_ADAPTER", validation)
        baseline_end = source.index("#else", baseline_start)
        self.assertNotIn(
            "RunPlanResolver.validate", source[baseline_start:baseline_end]
        )

    def test_current_project_uses_authenticated_exclusive_publication(self) -> None:
        source = ADAPTER_SOURCE.read_text(encoding="utf-8")

        self.assertIn(
            "ProjectPublicationTransaction.candidateURL(\n"
            '      in: projectParent, title: "project", attempt: 0\n'
            "    )",
            source,
        )
        self.assertIn("ProjectPublicationTransaction.begin(", source)
        self.assertIn("publication.reached(.videoAdopted)", source)
        self.assertIn("publication.reached(.photosAdopted)", source)
        self.assertIn("let projectID = UUID()", source)
        self.assertIn('let title = "project"', source)
        self.assertIn("id: projectID,\n      title: title,", source)
        self.assertIn(
            "resolvedRunPlan: plan,\n      lastRunStartedAt: Date()",
            source,
        )
        self.assertIn(
            "publication.validateAndSeal(expectedMetadata: metadata)\n"
            "    try Task.checkCancellation()\n"
            "    let freshPublication: FreshProjectPublication",
            source,
        )
        self.assertIn(
            "freshPublication = try publication.publishWithFreshAttestation(\n"
            "        videoInputIntegrityHandoff: videoInputIntegrityHandoff\n"
            "      )",
            source,
        )
        self.assertIn(
            "freshPublication = try publication."
            "publishWithFreshAttestationForProjectWithoutVideos()",
            source,
        )
        self.assertIn(
            "freshPublication.projectURL.resolvingSymlinksInPath().standardizedFileURL\n"
            "      == projectRoot.resolvingSymlinksInPath().standardizedFileURL",
            source,
        )
        self.assertIn(
            "freshPublicationAttestation: freshPublication.attestation",
            source,
        )
        self.assertNotIn("publication.publish()", source)
        self.assertNotIn("mkdir(projectRoot.path", source)
        self.assertNotIn("removeItem(at: projectRoot)", source)

    def test_current_project_persists_the_authenticated_photo_selection_receipt(
        self,
    ) -> None:
        source = ADAPTER_SOURCE.read_text(encoding="utf-8")
        publication_start = source.index("func publishCurrentMeasurementProject(")
        publication_end = source.index("\n#endif", publication_start)
        publication = source[publication_start:publication_end]

        adoption = publication.index("try inputAdoption.adoptPhotos(")
        metadata = publication.index("let metadata = ProjectMetadata(")
        receipt = publication.index(
            "photoSelectionReceipt: inputAdoption.photoSelectionReceipt,"
        )
        metadata_save = publication.index("try ProjectMetadataStore.save(")
        validation = publication.index(
            "try publication.validateAndSeal(expectedMetadata: metadata)"
        )
        self.assertLess(adoption, metadata)
        self.assertLess(metadata, receipt)
        self.assertLess(receipt, metadata_save)
        self.assertLess(metadata_save, validation)
        self.assertNotIn("VideoInputReceiptValidator.validateFiles", publication)
        self.assertNotIn("PhotoInputReceiptValidator.validateFiles", publication)

    def test_current_and_accurate_pipeline_consume_fresh_attestation_once(self) -> None:
        source = ADAPTER_SOURCE.read_text(encoding="utf-8")

        self.assertEqual(
            source.count(
                "freshPublicationAttestation: "
                "publishedProject.freshPublicationAttestation"
            ),
            2,
        )
        self.assertEqual(
            source.count("freshPublicationAttestation: freshPublicationAttestation"),
            1,
        )
        self.assertIn("videoInputIntegrityHandoff?.discard()", source)
        self.assertIn("pendingFreshPublicationAttestation?.discard()", source)

    def test_invalid_input_evidence_comes_from_a_typed_worker_receipt(self) -> None:
        adapter = ADAPTER_SOURCE.read_text(encoding="utf-8")
        runner = RUNNER_SOURCE.read_text(encoding="utf-8")

        self.assertIn("PipelineRunner.captureFailureType(for: error)", adapter)
        self.assertIn("MeasurementInvalidInputRejectionReceipt(", adapter)
        self.assertIn("failureType: failureType.rawValue", adapter)
        self.assertIn("failure.failureType == expectedFailureType", runner)
        self.assertIn("invalidFailureType = failure.failureType", runner)
        self.assertIn(
            '"output_sha256": "sha256:\\(failure.failureReceiptSHA256)"',
            runner,
        )
        self.assertNotIn("invalidFailureType = failureType", runner)

    def test_fresh_attestation_uses_the_canonical_published_project_path(self) -> None:
        source = ADAPTER_SOURCE.read_text(encoding="utf-8")
        accurate_start = source.index("func runAccurateReference(")
        accurate_end = source.index("\n  }\n#endif", accurate_start)
        accurate = source[accurate_start:accurate_end]
        self.assertIn("projectURL: paths.root", accurate)
        self.assertNotIn("projectURL: arguments.projectRoot", accurate)

        main = source[source.index("static func main() async") :]
        project_url_binding = main.index("let pipelineProjectURL")
        pipeline_start = main.rindex("#if BASELINE_ADAPTER", 0, project_url_binding)
        pipeline_end = main.index("let geometryEnded", pipeline_start)
        pipeline = main[pipeline_start:pipeline_end]
        self.assertIn(
            "#if BASELINE_ADAPTER\n"
            "          let pipelineProjectURL = arguments.projectRoot\n"
            "        #else\n"
            "          let pipelineProjectURL = paths.root\n"
            "        #endif",
            pipeline,
        )
        self.assertIn("projectURL: pipelineProjectURL", pipeline)
        self.assertNotIn("projectURL: arguments.projectRoot", pipeline)

    def test_current_and_accurate_video_preflight_are_bound_to_the_resolved_plan(
        self,
    ) -> None:
        source = ADAPTER_SOURCE.read_text(encoding="utf-8")
        shared_start = source.index("func publishCurrentMeasurementProject(")
        shared_end = source.index("\n#endif", shared_start)
        publication = source[shared_start:shared_end]
        preflight_start = publication.index(
            "preparedVideos = try await VideoInputPreflight().prepare("
        )
        preflight_end = publication.index("\n      )", preflight_start)
        preflight = publication[preflight_start:preflight_end]

        self.assertIn(
            "analysisPolicy: VideoFrameAnalysisPolicy(resolvedRunPlan: plan)",
            preflight,
        )
        self.assertIn("pairingPolicy: plan.pairingPolicy", preflight)

    def test_current_and_accurate_pipeline_timing_starts_before_publication(
        self,
    ) -> None:
        source = ADAPTER_SOURCE.read_text(encoding="utf-8")
        main = source[source.index("static func main() async") :]
        clock = main.index("let candidateStartedMonotonicSeconds =")
        wall_clock = main.index("let candidatePreparationStartedAt = Date()")
        publication = main.index("try await publishCurrentMeasurementProject(")

        self.assertLess(clock, publication)
        self.assertLess(wall_clock, publication)
        self.assertIn(
            "prePipelineDurationSeconds: ProcessInfo.processInfo.systemUptime\n"
            "              - candidateStartedMonotonicSeconds",
            main,
        )
        self.assertIn(
            "prePipelineStartedAt: candidatePreparationStartedAt",
            main,
        )
        self.assertIn("let started = candidateStartedMonotonicSeconds", main)
        self.assertGreaterEqual(
            main.count('"started_monotonic_seconds": started'),
            2,
        )
        self.assertIn('"end_to_end": ended - started', main)
        self.assertIn('timings["end_to_end"] = ended - started', main)
        self.assertIn(
            '"started_monotonic_seconds": candidateStartedMonotonicSeconds',
            source,
        )
        self.assertIn(
            '"end_to_end": ended - candidateStartedMonotonicSeconds',
            source,
        )
        self.assertEqual(
            source.count(
                "prePipelineDurationSeconds: ProcessInfo.processInfo.systemUptime"
            ),
            2,
        )
        self.assertEqual(
            source.count("prePipelineStartedAt: candidatePreparationStartedAt"),
            2,
        )

    def test_protected_runner_passes_the_transaction_candidate_leaf(self) -> None:
        source = RUNNER_SOURCE.read_text(encoding="utf-8")

        self.assertIn(
            "ProjectPublicationTransaction.candidateURL(\n"
            '      in: runParent, title: "project", attempt: 0\n'
            "    )",
            source,
        )
        self.assertIn(
            '"worker-runs/\\(runID)/project.easysplatproj/SfM/worker_execution.json"',
            source,
        )
        self.assertIn(
            '"worker-runs/\\(runID)/project.easysplatproj/SfM/geometry_manifest.json"',
            source,
        )

    def test_protected_runner_authenticates_the_exact_published_geometry(self) -> None:
        source = RUNNER_SOURCE.read_text(encoding="utf-8")
        helper_start = source.index("private func runtimeGeometryEvidence(")
        helper_end = source.index("\nprivate func referenceMapperInvocation(", helper_start)
        helper = source[helper_start:helper_end]

        decode = helper.index(
            "geometry = try decoder.decode(GeometryArtifact.self, "
            "from: manifestEvidence.geometry.data)"
        )
        validation = helper.index(
            "ProjectArtifactValidator.validatePublishedGeometry(\n"
            "      at: project,\n"
            "      expectedGeometry: geometry\n"
            "    )"
        )
        receipt = helper.index("let receipt: [String: Any] = [")
        self.assertLess(decode, validation)
        self.assertLess(validation, receipt)
        self.assertIn("authenticatedGeometry == geometry", helper)
        self.assertIn(
            '"geometry_manifest_sha256": '
            '"sha256:\\(manifestEvidence.geometry.sha256)"',
            helper,
        )

    def test_current_adapter_has_explicit_geometry_only_boundary(self) -> None:
        source = ADAPTER_SOURCE.read_text(encoding="utf-8")

        self.assertIn('"--geometry-only"', source)
        self.assertIn("let geometryOnly: Bool", source)
        self.assertIn('"measurement_scope": "geometry_only"', source)
        self.assertIn('"pair_graph_evidence": paths.pairGraphEvidenceURL.path', source)
        self.assertIn(
            '"canonical_text_model": try projectSpelledPath('
            "\n                paths: paths, artifact: textModel)",
            source,
        )
        self.assertIn("let measured = try ColmapResidualAnalyzer.analyze", source)
        self.assertRegex(
            source,
            r"guard snapshot\.metadata\.state\.stage == \.sfmMapping,\s+"
            r"snapshot\.metadata\.state\.lastError == nil,\s+"
            r"snapshot\.geometryArtifact != nil else",
        )
        metadata_guard = source.index(
            "guard snapshot.metadata.state.stage == .sfmMapping,"
        )
        model_conversion = source.index(
            "try await runMeasurementModelConverter(", metadata_guard
        )
        self.assertLess(metadata_guard, model_conversion)

    def test_matching_only_argument_is_current_only_and_mutually_exclusive(
        self,
    ) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            current = self._compile_adapter_argument_probe(root, "CURRENT_ADAPTER")
            baseline = self._compile_adapter_argument_probe(root, "BASELINE_ADAPTER")
            reference = self._compile_adapter_argument_probe(root, "ACCURATE_REFERENCE")

            current_matching = subprocess.run(
                [
                    str(current),
                    *self._adapter_arguments("--matching-only", "true"),
                ],
                text=True,
                capture_output=True,
            )
            self.assertEqual(current_matching.returncode, 0, current_matching.stderr)
            self.assertEqual(
                current_matching.stdout.strip(),
                "geometry=false matching=true mapping=false cadence=none trial=none",
            )

            current_geometry = subprocess.run(
                [
                    str(current),
                    *self._adapter_arguments("--geometry-only", "true"),
                ],
                text=True,
                capture_output=True,
            )
            self.assertEqual(current_geometry.returncode, 0, current_geometry.stderr)
            self.assertEqual(
                current_geometry.stdout.strip(),
                "geometry=true matching=false mapping=false cadence=none trial=none",
            )

            for command in (
                [
                    str(current),
                    *self._adapter_arguments(
                        "--geometry-only",
                        "true",
                        "--matching-only",
                        "true",
                    ),
                ],
                [
                    str(current),
                    *self._adapter_arguments("--matching-only", "false"),
                ],
                [
                    str(baseline),
                    *self._adapter_arguments(
                        "--matching-only", "true", variant="baseline"
                    ),
                ],
                [
                    str(reference),
                    *self._adapter_arguments(
                        "--matching-only", "true", variant="accurate_reference"
                    ),
                ],
            ):
                rejected = subprocess.run(command, text=True, capture_output=True)
                self.assertNotEqual(rejected.returncode, 0, command)

    def test_mapping_checkpoint_arguments_are_current_only_complete_and_exclusive(
        self,
    ) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            current = self._compile_adapter_argument_probe(root, "CURRENT_ADAPTER")
            baseline = self._compile_adapter_argument_probe(root, "BASELINE_ADAPTER")
            reference = self._compile_adapter_argument_probe(root, "ACCURATE_REFERENCE")
            mapping_arguments = (
                "--mapping-from-checkpoint",
                "/private/tmp/matching-envelope.json",
                "--mapper-cadence",
                "balanced-global",
                "--trial-root",
                "/private/tmp/mapper-cadence-02-1p4",
            )

            accepted = subprocess.run(
                [str(current), *self._adapter_arguments(*mapping_arguments)],
                text=True,
                capture_output=True,
            )
            self.assertEqual(accepted.returncode, 0, accepted.stderr)
            self.assertEqual(
                accepted.stdout.strip(),
                "geometry=false matching=false mapping=true "
                "cadence=balanced-global trial=/private/tmp/mapper-cadence-02-1p4",
            )

            rejected_arguments = (
                ("--mapping-from-checkpoint", "/private/tmp/matching-envelope.json"),
                (
                    "--mapping-from-checkpoint",
                    "/private/tmp/matching-envelope.json",
                    "--mapper-cadence",
                    "invalid",
                    "--trial-root",
                    "/private/tmp/trial",
                ),
                (*mapping_arguments, "--matching-only", "true"),
                (*mapping_arguments, "--geometry-only", "true"),
            )
            for extra in rejected_arguments:
                rejected = subprocess.run(
                    [str(current), *self._adapter_arguments(*extra)],
                    text=True,
                    capture_output=True,
                )
                self.assertNotEqual(rejected.returncode, 0, extra)

            for executable, variant in (
                (baseline, "baseline"),
                (reference, "accurate_reference"),
            ):
                rejected = subprocess.run(
                    [
                        str(executable),
                        *self._adapter_arguments(*mapping_arguments, variant=variant),
                    ],
                    text=True,
                    capture_output=True,
                )
                self.assertNotEqual(rejected.returncode, 0, variant)

    def test_mapping_checkpoint_branch_precedes_input_resolution_and_publication(
        self,
    ) -> None:
        source = ADAPTER_SOURCE.read_text(encoding="utf-8")
        main = source[source.index("static func main() async") :]

        branch = main.index("if arguments.mappingFromCheckpoint != nil")
        input_resolution = main.index("let input = try inputSpec(")
        publication = main.index("try await publishCurrentMeasurementProject(")
        self.assertLess(branch, input_resolution)
        self.assertLess(branch, publication)
        branch_end = main.index("let requestData =", branch)
        mapping_branch = main[branch:branch_end]
        self.assertIn("try await runMappingCadenceTrial(", mapping_branch)
        self.assertIn("return", mapping_branch)
        self.assertNotIn("publishCurrentMeasurementProject", mapping_branch)
        self.assertNotIn("inputSpec", mapping_branch)

    def test_partial_mapper_modes_authenticate_the_development_request_boundary(
        self,
    ) -> None:
        source = ADAPTER_SOURCE.read_text(encoding="utf-8")
        main = source[source.index("static func main() async") :]
        request_parse = main.index('"request"')
        input_resolution = main.index("let input = try inputSpec(")
        auth_literal = "authenticateMapperCadenceDevelopmentRequest("
        self.assertIn(auth_literal, main[request_parse:input_resolution])
        authentication = main.index(auth_literal, request_parse)
        self.assertLess(request_parse, authentication)
        self.assertLess(authentication, input_resolution)
        partial_binding = main.index("let partialRequestBinding")
        self.assertLess(partial_binding, request_parse)
        self.assertIn("arguments.matchingOnly", main[partial_binding:request_parse])

        auth_start = source.index("func authenticateMapperCadenceDevelopmentRequest(")
        auth_end = source.index("\n  }", auth_start)
        auth = source[auth_start:auth_end]
        for required in (
            '"schema_version"',
            '"evidence_class"',
            '"development_only"',
            '"request_kind"',
            '"mapper_cadence_ab"',
            '"source_provenance_scope"',
            '"binary_only_dirty_worktree"',
            '"source_tree_state"',
            '"dirty"',
            '"local_adhoc_unsigned"',
            '"adapter_executable_bytes"',
            '"adapter_executable_sha256"',
            '"colmap_runtime_components"',
            '"colmap_runtime_closure_sha256"',
            "executingAdapterURL()",
            "MeasurementEvidenceFileBinding(",
        ):
            self.assertIn(required, auth)
        executable_helper_start = source.index(
            "func executingAdapterURL() throws -> URL"
        )
        executable_helper_end = source.index("\n  }", executable_helper_start)
        executable_helper = source[executable_helper_start:executable_helper_end]
        self.assertIn("CommandLine.arguments.first", executable_helper)

    def test_partial_mapper_envelopes_disclose_observational_execution_assurance(
        self,
    ) -> None:
        source = ADAPTER_SOURCE.read_text(encoding="utf-8")
        helper_start = source.index("func developmentExecutionAssurance()")
        helper_end = source.index("\n  }", helper_start)
        assurance = source[helper_start:helper_end]

        for required in (
            '"level": "observational"',
            '"mutation_threat_model": "no_concurrent_same_uid_mutation"',
            '"runner_isolation_mode": "owner_private_local_process"',
            '"child_database_binding": "pre_post_descriptor_path"',
            '"child_database_open_inode_verified": false',
            '"child_runtime_binding": "pre_post_closure_path"',
            '"child_runtime_exec_inode_verified": false',
            '"release_gate_eligible": false',
        ):
            self.assertIn(required, assurance)

        mapping_start = source.index("func runMappingCadenceTrial(")
        mapping_end = source.index(
            "\n  func verifiedMatchingOnlyMeasurement(", mapping_start
        )
        matching_start = source.index("func verifiedMatchingOnlyMeasurement(")
        matching_end = source.index("\n  }\n#endif", matching_start)
        for envelope in (
            source[mapping_start:mapping_end],
            source[matching_start:matching_end],
        ):
            self.assertEqual(
                envelope.count(
                    '"execution_assurance": developmentExecutionAssurance()'
                ),
                1,
            )

    def test_matching_checkpoint_requires_exact_empty_artifact_roots(self) -> None:
        source = ADAPTER_SOURCE.read_text(encoding="utf-8")
        closure_start = source.index("func requireCleanMatchingArtifactClosure(")
        closure_end = source.index(
            "\n  func requirePrivateTrialDirectory(", closure_start
        )
        closure = source[closure_start:closure_end]
        mapping_start = source.index("func runMappingCadenceTrial(")
        mapping_end = source.index(
            "\n  func verifiedMatchingOnlyMeasurement(", mapping_start
        )
        matching_start = source.index("func verifiedMatchingOnlyMeasurement(")
        matching_end = source.index("\n  }\n#endif", matching_start)
        mapping = source[mapping_start:mapping_end]
        matching = source[matching_start:matching_end]

        self.assertIn(
            "root: paths.colmapSparseURL,\n      expectedDirectories: []",
            closure,
        )
        self.assertIn(
            "root: paths.colmapSeedURL,",
            closure,
        )
        self.assertIn("expectedFiles: Set(seedSidecars.keys)", closure)
        self.assertIn(
            "root: paths.outputURL,\n      expectedDirectories: []",
            closure,
        )
        for expected_training_directory in (
            '"checkpoints"',
            '"checkpoints/msplat"',
            '"msplat"',
            '"msplat_dataset"',
            '"msplat_dataset/images"',
            '"msplat_dataset/sparse"',
            '"msplat_dataset/sparse/0"',
        ):
            self.assertIn(expected_training_directory, closure)
        self.assertIn("requireAbsentOrExactDirectoryTree(", closure)
        self.assertIn("paths.geometryManifestURL", closure)
        for consumer in (mapping, matching):
            self.assertEqual(
                consumer.count("try requireCleanMatchingArtifactClosure("),
                1,
            )

    def test_matching_seed_sidecars_are_semantically_bound_to_durable_evidence(
        self,
    ) -> None:
        source = ADAPTER_SOURCE.read_text(encoding="utf-8")
        core_source = PAIR_GRAPH_STORE_SOURCE.read_text(encoding="utf-8")
        expected_start = core_source.index("static func matchingSeedSidecarContents(")
        expected_end = core_source.index(
            "\n    static func retrievalRequestDigest(", expected_start
        )
        expected = core_source[expected_start:expected_end]
        closure_start = source.index("func requireCleanMatchingArtifactClosure(")
        closure_end = source.index(
            "\n  func requirePrivateTrialDirectory(", closure_start
        )
        closure = source[closure_start:closure_end]

        for required in (
            "try workerExecution.validate(",
            "try validateSchedule(",
            "try validateWorkerExecution(",
            "evidence.attempts",
            "workerExecution.rejectedVocabularyRetrievalInvocations",
            "pairExecution?.attemptOrdinal",
            "rejected.planBinding == expectedPlanBinding",
            "rejected.groups == groups",
            "ColmapPairPlan.persisted(",
            ".serializedData",
            "PipelineRunner.baseColmapPairPlan(",
            "PipelineRunner.PairRecoveryLevel(",
            '"match_pairs_attempt_\\(attempt.artifact.attemptNumber).txt"',
            '"retrieval_queries_\\(recoveryLevel).txt"',
            '"retrieval_exclusions_\\(recoveryLevel).txt"',
            '"retrieval_pairs_\\(recoveryLevel).txt"',
            "retrievalContractLines(closure.retrieval)",
        ):
            self.assertIn(required, expected)
        for required in (
            "PairGraphEvidenceStore.matchingSeedSidecarContents(",
            "MeasurementEvidenceFileBinding(",
            "try binding.dataSnapshot() == expectedData",
            "sidecarBindings",
        ):
            self.assertIn(required, closure)
        self.assertNotIn("func expectedMatchingSeedSidecars(", source)

        mapping_start = source.index("func runMappingCadenceTrial(")
        mapping_end = source.index(
            "\n  func verifiedMatchingOnlyMeasurement(", mapping_start
        )
        matching_start = mapping_end + 3
        matching_end = source.index("\n  }\n#endif", matching_start)
        for consumer in (
            source[mapping_start:mapping_end],
            source[matching_start:matching_end],
        ):
            self.assertIn("for binding in seedSidecarBindings", consumer)
            self.assertIn("try binding.revalidate()", consumer)

    def test_retrieval_sidecars_bind_each_recovery_level_to_its_base_plan(
        self,
    ) -> None:
        source = PAIR_GRAPH_STORE_SOURCE.read_text(encoding="utf-8")
        start = source.index("static func matchingSeedSidecarContents(")
        end = source.index("\n    static func retrievalRequestDigest(", start)
        helper = source[start:end]

        rejected_loop = helper.index(
            "for rejected in workerExecution.rejectedVocabularyRetrievalInvocations"
        )
        rejected_base = helper.index(
            "PipelineRunner.baseColmapPairPlan(", rejected_loop
        )
        rejected_assignment = helper.index(
            "try recordRetrieval(",
            rejected_base,
        )
        accepted_loop = helper.index(
            "for attempt in evidence.attempts where attempt.retrievalWasExecuted"
        )
        accepted_base = helper.index(
            "PipelineRunner.baseColmapPairPlan(", accepted_loop
        )
        accepted_assignment = helper.index(
            "try recordRetrieval(",
            accepted_base,
        )
        exclusion = helper.index("closure.basePlan.serializedData", accepted_assignment)

        self.assertLess(rejected_loop, rejected_base)
        self.assertLess(rejected_base, rejected_assignment)
        self.assertLess(rejected_assignment, accepted_loop)
        self.assertLess(accepted_loop, accepted_base)
        self.assertLess(accepted_base, accepted_assignment)
        self.assertLess(accepted_assignment, exclusion)
        self.assertIn("let key = recoveryLevel.rawValue", helper)
        self.assertIn("existing.retrieval == retrieval", helper)
        self.assertIn("existing.basePlan == basePlan", helper)
        self.assertNotIn("scheduledPairs.filter", helper)

    def test_seed_sidecar_binding_rejects_missing_wrong_and_mutated_bytes(
        self,
    ) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            probe = self._compile_evidence_binding_probe(root)
            sidecar = root / "match_pairs_attempt_1.txt"
            sidecar.write_text("first.jpg second.jpg\n", encoding="utf-8")

            accepted = subprocess.run(
                [
                    str(probe),
                    str(sidecar),
                    "verify",
                    "first.jpg second.jpg\n",
                ],
                text=True,
                capture_output=True,
            )
            self.assertEqual(accepted.returncode, 0, accepted.stderr)

            wrong = subprocess.run(
                [str(probe), str(sidecar), "verify", "tampered\n"],
                text=True,
                capture_output=True,
            )
            self.assertNotEqual(wrong.returncode, 0)

            mutated = subprocess.run(
                [str(probe), str(sidecar), "mutate"],
                text=True,
                capture_output=True,
            )
            self.assertNotEqual(mutated.returncode, 0)

            missing = subprocess.run(
                [str(probe), str(root / "missing.txt"), "verify", "missing\n"],
                text=True,
                capture_output=True,
            )
            self.assertNotEqual(missing.returncode, 0)

    def test_exact_directory_tree_rejects_hidden_numeric_file_and_symlink_leaves(
        self,
    ) -> None:
        expected_training = (
            "checkpoints",
            "checkpoints/msplat",
            "msplat",
            "msplat_dataset",
            "msplat_dataset/images",
            "msplat_dataset/sparse",
            "msplat_dataset/sparse/0",
        )
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            probe = self._compile_exact_directory_tree_probe(root)

            empty = root / "empty"
            empty.mkdir()
            accepted = subprocess.run(
                [str(probe), str(empty)], text=True, capture_output=True
            )
            self.assertEqual(accepted.returncode, 0, accepted.stderr)

            allowed_sidecars = root / "allowed-sidecars"
            allowed_sidecars.mkdir()
            (allowed_sidecars / "match_pairs_attempt_1.txt").write_text(
                "first.jpg second.jpg\n", encoding="utf-8"
            )
            accepted = subprocess.run(
                [
                    str(probe),
                    str(allowed_sidecars),
                    "--file",
                    "match_pairs_attempt_1.txt",
                ],
                text=True,
                capture_output=True,
            )
            self.assertEqual(accepted.returncode, 0, accepted.stderr)

            for leaf, make_leaf in (
                ("1", lambda path: path.mkdir()),
                ("10", lambda path: path.mkdir()),
                (".text-model-stale", lambda path: path.mkdir()),
                ("cameras.bin", lambda path: path.write_bytes(b"stale")),
                (
                    "redirect",
                    lambda path: path.symlink_to(empty, target_is_directory=True),
                ),
            ):
                artifact_root = root / f"artifact-{leaf.replace('/', '-')}"
                artifact_root.mkdir()
                make_leaf(artifact_root / leaf)
                rejected = subprocess.run(
                    [str(probe), str(artifact_root)],
                    text=True,
                    capture_output=True,
                )
                self.assertNotEqual(rejected.returncode, 0, leaf)

            training = root / "Training"
            absent_training = root / "AbsentTraining"
            accepted = subprocess.run(
                [
                    str(probe),
                    str(absent_training),
                    "--allow-absent",
                    *expected_training,
                ],
                text=True,
                capture_output=True,
            )
            self.assertEqual(accepted.returncode, 0, accepted.stderr)

            for relative in expected_training:
                (training / relative).mkdir(parents=True, exist_ok=True)
            accepted = subprocess.run(
                [
                    str(probe),
                    str(training),
                    "--allow-absent",
                    *expected_training,
                ],
                text=True,
                capture_output=True,
            )
            self.assertEqual(accepted.returncode, 0, accepted.stderr)

            (training / "msplat_dataset" / ".stale").write_bytes(b"stale")
            rejected = subprocess.run(
                [
                    str(probe),
                    str(training),
                    "--allow-absent",
                    *expected_training,
                ],
                text=True,
                capture_output=True,
            )
            self.assertNotEqual(rejected.returncode, 0)

            (training / "msplat_dataset" / ".stale").unlink()
            (training / "msplat_dataset" / "sparse" / "0").rmdir()
            rejected = subprocess.run(
                [
                    str(probe),
                    str(training),
                    "--allow-absent",
                    *expected_training,
                ],
                text=True,
                capture_output=True,
            )
            self.assertNotEqual(rejected.returncode, 0)

    def test_mapping_trial_binds_request_plan_fixed_options_and_schedule(self) -> None:
        source = ADAPTER_SOURCE.read_text(encoding="utf-8")
        start = source.index("func runMappingCadenceTrial(")
        end = source.index("\n  }\n#endif", start)
        helper = source[start:end]

        for required in (
            "authenticateMapperCadenceDevelopmentRequest(",
            "validateMapperCadenceResolvedPlan(",
            "bindingSHA256(",
            "minimumPairInlierCount: minimumPairInlierCount",
            "ColmapMappingPolicy.minimumPairInlierCount",
            "authenticatedRequest.trial(",
            "authenticatedTrial.ordinal == trial.ordinal",
            "authenticatedTrial.mapperCadence == requestedCadence",
            "authenticatedTrial.ratio == trial.ratio",
            "authenticatedTrial.discarded == (trial.ordinal == 0)",
            'decision["execution_assurance"]',
            '"expected execution assurance"',
            '"fixed_mapper_options"',
            '"fixed_mapper_options_sha256"',
            '"experiment_contract_sha256"',
        ):
            self.assertIn(required, helper)

    def test_multi_video_automatic_camera_source_accepts_its_resolved_grouping(
        self,
    ) -> None:
        source = ADAPTER_SOURCE.read_text(encoding="utf-8")
        validation_start = source.index("func validateMapperCadenceResolvedPlan(")
        validation_end = source.index(
            "\n  final class MeasurementBoundedMapperLog", validation_start
        )
        validation = source[validation_start:validation_end]
        resolver_tests = RUN_PLAN_TEST_SOURCE.read_text(encoding="utf-8")
        resolver_start = resolver_tests.index(
            "func testAutomaticOrderingDoesNotPretendSeparateClipsAreOneContinuousCapture()"
        )
        resolver_end = resolver_tests.index("\n    }", resolver_start)
        resolver_contract = resolver_tests[resolver_start:resolver_end]

        self.assertIn("requestedOptions: RequestedRunOptions()", resolver_contract)
        self.assertIn(
            'input: .video(files: ["/tmp/first.mov", "/tmp/second.mov"])',
            resolver_contract,
        )
        self.assertIn(
            "XCTAssertEqual(plan.cameraGrouping, .mixedCamerasOrLenses)",
            resolver_contract,
        )
        self.assertIn("configuredOptions == expectedRequestedOptions", validation)
        self.assertNotIn(
            "resolvedPlan.cameraGrouping == expectedRequestedOptions.cameraGrouping",
            validation,
        )

    def test_mapping_checkpoint_uses_frozen_descriptor_held_evidence(self) -> None:
        source = ADAPTER_SOURCE.read_text(encoding="utf-8")
        start = source.index("func runMappingCadenceTrial(")
        end = source.index("\n  }\n#endif", start)
        helper = source[start:end]

        for required in (
            "MeasurementEvidenceFileBinding(",
            "MeasurementFrozenCOLMAPDatabase(",
            "makeTrialCloneLease(",
            "lease.revalidatePreRunUnchanged()",
            "lease.finalizePostRun()",
            "frozenDatabase.finalizeSourceRehash()",
            "cloneEvidence.strategy == .apfsClone",
            "PairGraphEvidenceStore.loadVerified(",
            "PairGraphEvidenceStore.validateSchedule(",
            "PairGraphEvidenceStore.validateWorkerExecution(",
            "ColmapDatabaseDigester.digests(",
            "ColmapRunner().captureRuntimeClosure(",
            "runMapper(",
            "MeasurementSparseModelSelector.select(",
            "runMeasurementModelConverter(",
            "ColmapResidualAnalyzer.analyzeConditioning(",
            '"source_database_initial_evidence"',
            '"source_database_final_evidence"',
            '"clone_database_pre_run_evidence"',
            '"clone_database_post_run_evidence"',
            '"conditioning_measurement"',
            '"registered_image_names"',
            '"camera_poses_wxyz_xyz"',
            '"measurement_scope": "mapping_cadence_trial"',
        ):
            self.assertIn(required, helper)
        for forbidden in (
            "publishCurrentMeasurementProject",
            "prepareMeasurementDataset",
            "runMeasurementTraining",
            '"geometry_manifest"',
            '"training_manifest"',
            '"output_ply"',
        ):
            self.assertNotIn(forbidden, helper)

    def test_matching_measurements_bind_feature_evidence_to_resolved_camera_initialization(
        self,
    ) -> None:
        source = ADAPTER_SOURCE.read_text(encoding="utf-8")
        ranges = (
            (
                source.index("func runMappingCadenceTrial("),
                source.index("\n  }\n#endif", source.index("func runMappingCadenceTrial(")),
            ),
            (
                source.index("func verifiedMatchingOnlyMeasurement("),
                source.index(
                    "\n  }\n#endif",
                    source.index("func verifiedMatchingOnlyMeasurement("),
                ),
            ),
        )

        for start, end in ranges:
            helper = source[start:end]
            self.assertIn(
                "let expectedCameraInitialization = try "
                "ColmapCameraInitializationReceipt.resolve(",
                helper,
            )
            self.assertIn("plan: resolvedPlan", helper)
            self.assertIn(
                "detailProfile: metadata.requestedRunOptions.detailProfile",
                helper,
            )
            self.assertIn("selectedImages: selectedImages", helper)
            self.assertIn(
                "expectedCameraInitializationReceipt: expectedCameraInitialization",
                helper,
            )

    def test_json_booleans_are_never_accepted_as_measurement_integers(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            probe = self._compile_json_integer_probe(Path(directory))
            for payload, label in (
                ("true", "binding.scale"),
                ("true", "run_seed"),
                ("[0,true]", "holdout_indices"),
            ):
                completed = subprocess.run(
                    [str(probe), payload, label],
                    text=True,
                    capture_output=True,
                )
                self.assertNotEqual(completed.returncode, 0, (payload, label))
                self.assertIn("must be an integer", completed.stderr)

            for payload, label in (("42", "run_seed"), ("[0,2]", "holdout_indices")):
                completed = subprocess.run(
                    [str(probe), payload, label],
                    text=True,
                    capture_output=True,
                )
                self.assertEqual(completed.returncode, 0, completed.stderr)

    def test_matching_memory_sampling_starts_before_request_and_input_preflight(
        self,
    ) -> None:
        source = ADAPTER_SOURCE.read_text(encoding="utf-8")
        main = source[source.index("static func main() async") :]

        parsed = main.index("let arguments = try AdapterArguments.parse")
        started = main.index("let candidateStartedMonotonicSeconds =")
        sampler = main.index("let matchingMemorySampler", started)
        sampler_start = main.index("matchingMemorySampler?.start()", sampler)
        request = main.index(
            "let requestData = try Data(contentsOf: arguments.request)"
        )
        publication = main.index("try await publishCurrentMeasurementProject(")
        self.assertLess(parsed, started)
        self.assertLess(started, sampler)
        self.assertLess(sampler, sampler_start)
        self.assertLess(sampler_start, request)
        self.assertLess(request, publication)

    def test_matching_only_stops_before_mapping_and_emits_verified_evidence(
        self,
    ) -> None:
        source = ADAPTER_SOURCE.read_text(encoding="utf-8")

        self.assertIn('"measurement_scope": "matching_only"', source)
        self.assertIn(
            "stopAfterStage: arguments.matchingOnly ? .sfmMatching : .sfmMapping",
            source,
        )
        self.assertIn("func verifiedMatchingOnlyMeasurement(", source)
        helper_start = source.index("func verifiedMatchingOnlyMeasurement(")
        helper_end = source.index("\n  }\n#endif", helper_start)
        helper = source[helper_start:helper_end]
        for required in (
            "metadata.state.stage == .sfmMatching",
            "metadata.state.lastError == nil",
            "metadata.checkpoint == nil",
            "requireCleanMatchingArtifactClosure(",
            "PairGraphEvidenceStore.loadVerified(",
            "PairGraphEvidenceStore.validateSchedule(",
            "PairGraphEvidenceStore.validateWorkerExecution(",
            "ColmapDatabaseDigester.digests(at: paths.colmapDatabaseURL)",
            "GeometryWorkerExecutionArtifactStore.load(",
            "workerExecution.mappingAndRefinementInvocations.isEmpty",
            '"selection_manifest_sha256"',
            '"pair_graph_evidence_sha256"',
            '"selected_image_names"',
            '"feature_database_digest"',
            '"matching_database_digest"',
            '"database_file_sha256"',
            '"request_sha256"',
            '"resolved_plan_binding_sha256"',
            '"deterministic_seed"',
            '"pair_list_digest"',
            '"spatially_verified_pair_count"',
            '"component_view_counts"',
            '"peak_memory_bytes"',
            "MeasurementFrozenCOLMAPDatabase(",
            "frozenDatabase.finalizeSourceRehash()",
        ):
            self.assertIn(required, helper)
        for forbidden in (
            "runModelConverter",
            "prepareMeasurementDataset",
            "runMeasurementTraining",
        ):
            self.assertNotIn(forbidden, helper)
        envelope = helper[helper.index("    return [") :]
        for forbidden_key in (
            '"geometry_manifest":',
            '"training_manifest":',
            '"output_ply":',
        ):
            self.assertNotIn(forbidden_key, envelope)

        matching_branch = source.index("if arguments.matchingOnly {")
        mapping_guard = source.index(
            "guard snapshot.metadata.state.stage == .sfmMapping,"
        )
        model_conversion = source.index(
            "try await runMeasurementModelConverter(", mapping_guard
        )
        self.assertLess(matching_branch, mapping_guard)
        self.assertLess(matching_branch, model_conversion)

    def test_matching_only_revalidates_runtime_and_freezes_database_before_emit(
        self,
    ) -> None:
        source = ADAPTER_SOURCE.read_text(encoding="utf-8")
        helper_start = source.index("func verifiedMatchingOnlyMeasurement(")
        helper_end = source.index("\n  }\n#endif", helper_start)
        helper = source[helper_start:helper_end]

        worker = helper.index("GeometryWorkerExecutionArtifactStore.load(")
        runtime = helper.index("ColmapRunner().captureRuntimeClosure(")
        frozen = helper.index("MeasurementFrozenCOLMAPDatabase(")
        final_rehash = helper.index("frozenDatabase.finalizeSourceRehash()")
        final_logical = helper.rindex(
            "ColmapDatabaseDigester.digests(at: paths.colmapDatabaseURL)"
        )
        envelope = helper.index("    return [")
        self.assertLess(worker, runtime)
        self.assertLess(runtime, envelope)
        self.assertLess(frozen, final_rehash)
        self.assertLess(final_rehash, final_logical)
        self.assertLess(final_logical, envelope)
        self.assertIn(
            "liveRuntimeClosure == workerExecution.colmapRuntimeClosure", helper
        )
        self.assertIn("sourceEvidence.mode == UInt32(S_IFREG | S_IRUSR)", helper)
        self.assertIn('"database_source_inode"', helper)
        self.assertIn('"database_source_mode"', helper)

    def test_matching_json_sidecars_are_held_and_revalidated(self) -> None:
        source = ADAPTER_SOURCE.read_text(encoding="utf-8")
        self.assertIn("final class MeasurementEvidenceFileBinding", source)
        binding_start = source.index("final class MeasurementEvidenceFileBinding")
        helper_start = source.index("func verifiedMatchingOnlyMeasurement(")
        binding = source[binding_start:helper_start]
        for required in (
            "O_NOFOLLOW",
            "O_CLOEXEC",
            "Darwin.fstat(",
            "Darwin.lstat(",
            "status.st_uid == geteuid()",
            "status.st_nlink == 1",
            "(status.st_mode & S_IFMT) == S_IFREG",
            "status.st_size > 0",
            "status.st_size <= maximumBytes",
            "Darwin.pread(",
            "func revalidate() throws",
        ):
            self.assertIn(required, binding)

        helper_end = source.index("\n  }\n#endif", helper_start)
        helper = source[helper_start:helper_end]
        capture = helper.index("let selectionManifestBinding")
        validators = helper.index("pipeline.loadSelectedFrameManifest(")
        revalidate = helper.index("try selectionManifestBinding.revalidate()")
        envelope = helper.index("    return [")
        self.assertLess(capture, validators)
        self.assertLess(validators, revalidate)
        self.assertLess(revalidate, envelope)
        self.assertIn("try pairGraphEvidenceBinding.revalidate()", helper)
        self.assertIn("try workerExecutionBinding.revalidate()", helper)

    def test_matching_sidecar_semantics_are_decoded_from_bound_bytes(self) -> None:
        source = ADAPTER_SOURCE.read_text(encoding="utf-8")
        helper_start = source.index("func verifiedMatchingOnlyMeasurement(")
        helper_end = source.index("\n  }\n#endif", helper_start)
        helper = source[helper_start:helper_end]

        for required in (
            "selectionManifestBinding.dataSnapshot()",
            "pairGraphEvidenceBinding.dataSnapshot()",
            "workerExecutionBinding.dataSnapshot()",
            "loadSelectedFrameManifest(\n      data:",
            "PairGraphEvidenceStore.loadVerified(\n      data:",
            "GeometryWorkerExecutionArtifactStore.load(\n      data:",
        ):
            self.assertIn(required, helper)
        self.assertNotIn("pipeline.loadSelectedFrameManifest(\n      from:", helper)
        self.assertNotIn("PairGraphEvidenceStore.loadVerified(\n      from:", helper)
        self.assertNotIn(
            "GeometryWorkerExecutionArtifactStore.load(\n      from:", helper
        )

    def test_matching_metadata_semantics_are_decoded_from_bound_bytes(self) -> None:
        source = ADAPTER_SOURCE.read_text(encoding="utf-8")
        helper_start = source.index("func verifiedMatchingOnlyMeasurement(")
        helper_end = source.index("\n  }\n#endif", helper_start)
        helper = source[helper_start:helper_end]

        binding_literal = "let metadataBinding = try MeasurementEvidenceFileBinding("
        self.assertIn(binding_literal, helper)
        capture = helper.index(binding_literal)
        decode = helper.index("ProjectMetadataStore.decodeValidatedMetadataSnapshot(")
        semantic_guard = helper.index(
            "ProjectMetadataStore.acceptedFormatVersions.contains(metadata.formatVersion)"
        )
        revalidate = helper.index("try metadataBinding.revalidate()")
        envelope = helper.rindex("    return [")
        self.assertLess(capture, decode)
        self.assertLess(decode, semantic_guard)
        self.assertLess(semantic_guard, revalidate)
        self.assertLess(revalidate, envelope)
        self.assertIn("metadataBinding.dataSnapshot()", helper)

    def test_matching_checkpoint_binds_clean_recovery_and_compute_semantics(
        self,
    ) -> None:
        source = ADAPTER_SOURCE.read_text(encoding="utf-8")
        helper_start = source.index("func verifiedMatchingOnlyMeasurement(")
        helper_end = source.index("\n  }\n#endif", helper_start)
        helper = source[helper_start:helper_end]
        recovery_start = source.index("func verifiedMatchingRecovery(")
        recovery_end = source.index("\n  }", recovery_start)
        recovery = source[recovery_start:recovery_end]

        for required in (
            "ProjectMetadataStore.acceptedFormatVersions.contains(metadata.formatVersion)",
            "metadata.lastRunStartedAt == nil",
            "metadata.resolvedRunPlan == resolvedPlan",
            "verifiedMatchingRecovery(",
            '"colmap_compute_mode"',
            '"fallback_reasons"',
            '"recovery_level"',
            '"exact_recovery_reason"',
            '"rejected_vocabulary_retrieval_count"',
            '"rejected_vocabulary_retrieval_history"',
        ):
            self.assertIn(required, helper)
        for required in (
            "metadata.geometryRecovery",
            "recovery.validateBinding(",
            "recovery.validatePairGraphBinding(",
            "recovery.mappingFallbackReasons == pairEvidence.fallbackReasons",
        ):
            self.assertIn(required, recovery)

    def test_mapping_checkpoint_authenticates_matching_recovery_semantics(self) -> None:
        source = ADAPTER_SOURCE.read_text(encoding="utf-8")
        start = source.index("func runMappingCadenceTrial(")
        end = source.index("\n  }\n#endif", start)
        helper = source[start:end]
        recovery_start = source.index("func verifiedMatchingRecovery(")
        recovery_end = source.index("\n  }", recovery_start)
        recovery = source[recovery_start:recovery_end]
        decision_start = source.index("func validateDecisionRecoverySemantics(")
        decision_end = source.index("\n  }", decision_start)
        decision = source[decision_start:decision_end]

        for required in (
            "metadata.lastRunStartedAt == nil",
            "verifiedMatchingRecovery(",
            "validateDecisionRecoverySemantics(",
            "selectionBinding.dataSnapshot()",
            "pairBinding.dataSnapshot()",
            "workerBinding.dataSnapshot()",
            '"clone_database_companion_names": []',
        ):
            self.assertIn(required, helper)
        self.assertIn("metadata.geometryRecovery", recovery)
        for required in (
            'decision["colmap_compute_mode"]',
            'decision["fallback_reasons"]',
            'decision["recovery_level"]',
            'decision["exact_recovery_reason"]',
            'decision["rejected_vocabulary_retrieval_count"]',
            'decision["rejected_vocabulary_retrieval_history"]',
        ):
            self.assertIn(required, decision)

    def test_matching_envelope_authenticates_recovery_and_retrieval_history(
        self,
    ) -> None:
        source = ADAPTER_SOURCE.read_text(encoding="utf-8")
        helper_start = source.index("func verifiedMatchingOnlyMeasurement(")
        helper_end = source.index("\n  }\n#endif", helper_start)
        helper = source[helper_start:helper_end]
        recovery_start = source.index("func verifiedMatchingRecovery(")
        recovery_end = source.index("\n  }", recovery_start)
        recovery = source[recovery_start:recovery_end]
        history_start = source.index("func rejectedVocabularyRetrievalHistory(")
        history_end = source.index("\n  }", history_start)
        history = source[history_start:history_end]

        for binding in (
            "try recovery.validate()",
            "recovery.activeBackend == .colmap",
            "recovery.pendingPairRecoveryLevel == nil",
            "recovery.mappingFallbackReasons == pairEvidence.fallbackReasons",
            "recovery.validateBinding(",
            "recovery.validatePairGraphBinding(",
        ):
            self.assertIn(binding, recovery)
        self.assertIn(
            "geometryRecovery.matchingDatabaseDigest == databaseDigests.matching",
            helper,
        )
        for binding in (
            "GeometryWorkerExecutionArtifact.validateRejectedVocabularyRetrievalHistory(",
            "rejected.planBinding == PairGraphPlanBinding(resolvedPlan)",
            "rejected.imageNames == selectedImageNames",
            "rejected.groups == groups",
            "pairExecution.attemptOrdinal <= acceptedPairAttemptNumber",
        ):
            self.assertIn(binding, history)
        self.assertNotIn("noRankedNeighborQueryCount > 0", history)

        for field in (
            '"colmap_compute_mode"',
            '"fallback_reasons"',
            '"recovery_level"',
            '"exact_recovery_reason"',
            '"rejected_vocabulary_retrieval_count"',
            '"rejected_vocabulary_retrieval_history"',
        ):
            self.assertIn(field, helper)

        object_start = history.index("return [")
        object_end = history.index("\n      ]", object_start)
        history_object = history[object_start:object_end]
        expected_history_keys = {
            "retrieval_attempt_ordinal",
            "pair_attempt_ordinal",
            "pairing_policy",
            "recovery_level",
            "selected_view_count",
            "query_count",
            "no_ranked_neighbor_query_count",
            "candidate_count",
            "returned_neighbor_count",
            "retrieval_request_digest",
            "retrieval_output_digest",
        }
        actual_history_keys = {
            line.split('"')[1]
            for line in history_object.splitlines()
            if line.lstrip().startswith('"')
        }
        self.assertEqual(actual_history_keys, expected_history_keys)
        self.assertNotIn("duration", history)

    def test_adapter_creates_reserved_text_model_below_a_verified_training_parent(
        self,
    ) -> None:
        source = ADAPTER_SOURCE.read_text(encoding="utf-8")

        self.assertIn("func createMeasurementTextModelDirectory(", source)
        helper = source.index("func createMeasurementTextModelDirectory(")
        helper_end = source.index("\n}\n", helper)
        body = source[helper:helper_end]
        self.assertIn("try paths.ensureMutableTrainingDirectories()", body)
        self.assertIn("try paths.resolveProjectRelativePath(relativePath)", body)
        self.assertIn("!fileManager.fileExists(atPath: destination.path)", body)
        self.assertIn("destinationOfSymbolicLink(atPath: destination.path)", body)
        self.assertIn("withIntermediateDirectories: false", body)
        self.assertIn(
            "try paths.projectRelativePath(for: destination) == relativePath", body
        )
        call = source.index(
            "let textModel = try createMeasurementTextModelDirectory(",
        )
        geometry_only_branch = source.index("if arguments.geometryOnly {", call)
        normal_training = source.index(
            "let dataset = try await prepareMeasurementDataset(", call
        )
        self.assertLess(call, geometry_only_branch)
        self.assertLess(geometry_only_branch, normal_training)

    def test_adapter_reports_verified_artifacts_with_the_project_root_spelling(
        self,
    ) -> None:
        source = ADAPTER_SOURCE.read_text(encoding="utf-8")

        self.assertIn("func projectSpelledPath(", source)
        helper = source.index("func projectSpelledPath(")
        helper_end = source.index("\n}\n", helper)
        body = source[helper:helper_end]
        self.assertIn("try paths.projectRelativePath(for: artifact)", body)
        self.assertIn("paths.root.appendingPathComponent(relativePath).path", body)

    def test_build_and_verify_bind_executable_adapter_and_build_identity(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            executable = root / "EasySplatMeasurementRunner"
            executable.write_bytes(b"#!/bin/sh\nexit 0\n")
            executable.chmod(0o755)
            adapter = root / "PipelineMeasurementAdapter.swift"
            adapter.write_text("import Foundation\n", encoding="utf-8")
            support = root / "MeasurementAdapterSupport.swift"
            support.write_text("import Foundation\n", encoding="utf-8")
            candidate_adapter = root / "PipelineMeasurementAdapter-current"
            baseline_adapter = root / "PipelineMeasurementAdapter-baseline"
            reference_adapter = root / "AccurateReferenceMeasurementAdapter"
            for worker in (candidate_adapter, baseline_adapter, reference_adapter):
                worker.write_bytes(b"#!/bin/sh\nexit 0\n")
                worker.chmod(0o755)
            package = root / "package"
            identity = root / "identity.json"

            subprocess.run(
                [
                    "python3",
                    str(SCRIPT),
                    "build",
                    "--executable",
                    str(executable),
                    "--adapter-source",
                    str(adapter),
                    "--support-source",
                    str(support),
                    "--candidate-adapter",
                    str(candidate_adapter),
                    "--baseline-adapter",
                    str(baseline_adapter),
                    "--reference-adapter",
                    str(reference_adapter),
                    "--source-commit",
                    "a" * 40,
                    "--xcode-version",
                    "Xcode 16.4",
                    "--swift-version",
                    "Swift version 6.1.2",
                    "--output",
                    str(package / "closure"),
                    "--identity-output",
                    str(identity),
                ],
                check=True,
            )
            subprocess.run(
                [
                    "python3",
                    str(SCRIPT),
                    "verify",
                    "--closure",
                    str(package / "closure"),
                    "--identity",
                    str(identity),
                ],
                check=True,
            )

            decoded = json.loads(identity.read_text(encoding="utf-8"))
            self.assertEqual(decoded["source_commit"], "a" * 40)
            self.assertEqual(decoded["xcode_version"], "Xcode 16.4")
            self.assertEqual(decoded["swift_version"], "Swift version 6.1.2")
            self.assertRegex(decoded["sha256"], r"^[0-9a-f]{64}$")
            self.assertEqual(
                set(decoded["files"]),
                {
                    "EasySplatMeasurementRunner",
                    "PipelineMeasurementAdapter.swift",
                    "MeasurementAdapterSupport.swift",
                    "PipelineMeasurementAdapter-current",
                    "PipelineMeasurementAdapter-baseline",
                    "AccurateReferenceMeasurementAdapter",
                },
            )
            mode = (package / "closure/EasySplatMeasurementRunner").stat().st_mode
            self.assertTrue(mode & stat.S_IXUSR)

    def test_build_rejects_identity_output_that_aliases_an_input_or_closure_member(
        self,
    ) -> None:
        for alias_kind in ("input", "closure-member"):
            with self.subTest(alias_kind=alias_kind), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                executable = root / "runner"
                original_executable = b"#!/bin/sh\nexit 0\n"
                executable.write_bytes(original_executable)
                executable.chmod(0o755)
                adapter = root / "adapter.swift"
                adapter.write_text("import Foundation\n", encoding="utf-8")
                support = root / "support.swift"
                support.write_text("import Foundation\n", encoding="utf-8")
                candidate_adapter = root / "candidate"
                baseline_adapter = root / "baseline"
                reference_adapter = root / "reference"
                for worker in (candidate_adapter, baseline_adapter, reference_adapter):
                    worker.write_bytes(b"#!/bin/sh\nexit 0\n")
                    worker.chmod(0o755)
                closure = root / "closure"
                identity = (
                    executable
                    if alias_kind == "input"
                    else closure / "EasySplatMeasurementRunner"
                )

                completed = subprocess.run(
                    [
                        "python3",
                        str(SCRIPT),
                        "build",
                        "--executable",
                        str(executable),
                        "--adapter-source",
                        str(adapter),
                        "--support-source",
                        str(support),
                        "--candidate-adapter",
                        str(candidate_adapter),
                        "--baseline-adapter",
                        str(baseline_adapter),
                        "--reference-adapter",
                        str(reference_adapter),
                        "--source-commit",
                        "a" * 40,
                        "--xcode-version",
                        "Xcode 16.4",
                        "--swift-version",
                        "Swift version 6.1.2",
                        "--output",
                        str(closure),
                        "--identity-output",
                        str(identity),
                    ],
                    text=True,
                    capture_output=True,
                )

                self.assertNotEqual(completed.returncode, 0)
                self.assertIn("alias", completed.stderr.lower())
                self.assertEqual(executable.read_bytes(), original_executable)
                self.assertFalse(closure.exists())

    def test_verify_rejects_a_changed_adapter(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            executable = root / "runner"
            executable.write_bytes(b"runner")
            executable.chmod(0o755)
            adapter = root / "adapter.swift"
            adapter.write_text("original\n", encoding="utf-8")
            support = root / "support.swift"
            support.write_text("support\n", encoding="utf-8")
            candidate_adapter = root / "candidate"
            baseline_adapter = root / "baseline"
            reference_adapter = root / "reference"
            for worker in (candidate_adapter, baseline_adapter, reference_adapter):
                worker.write_bytes(b"worker")
                worker.chmod(0o755)
            closure = root / "closure"
            identity = root / "identity.json"
            subprocess.run(
                [
                    "python3",
                    str(SCRIPT),
                    "build",
                    "--executable",
                    str(executable),
                    "--adapter-source",
                    str(adapter),
                    "--support-source",
                    str(support),
                    "--candidate-adapter",
                    str(candidate_adapter),
                    "--baseline-adapter",
                    str(baseline_adapter),
                    "--reference-adapter",
                    str(reference_adapter),
                    "--source-commit",
                    "b" * 40,
                    "--xcode-version",
                    "Xcode 16.4",
                    "--swift-version",
                    "Swift version 6.1.2",
                    "--output",
                    str(closure),
                    "--identity-output",
                    str(identity),
                ],
                check=True,
            )
            (closure / "PipelineMeasurementAdapter.swift").write_text(
                "changed\n", encoding="utf-8"
            )

            completed = subprocess.run(
                [
                    "python3",
                    str(SCRIPT),
                    "verify",
                    "--closure",
                    str(closure),
                    "--identity",
                    str(identity),
                ],
                text=True,
                capture_output=True,
            )
            self.assertNotEqual(completed.returncode, 0)
            self.assertIn("digest", completed.stderr.lower())

    def test_verify_rejects_symlinked_files(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            closure = root / "closure"
            closure.mkdir()
            target = root / "target"
            target.write_text("runner", encoding="utf-8")
            os.symlink(target, closure / "EasySplatMeasurementRunner")
            (closure / "PipelineMeasurementAdapter.swift").write_text(
                "adapter", encoding="utf-8"
            )
            (closure / "MeasurementAdapterSupport.swift").write_text(
                "support", encoding="utf-8"
            )
            for name in (
                "PipelineMeasurementAdapter-current",
                "PipelineMeasurementAdapter-baseline",
                "AccurateReferenceMeasurementAdapter",
            ):
                worker = closure / name
                worker.write_text("worker", encoding="utf-8")
                worker.chmod(0o755)
            identity = root / "identity.json"
            identity.write_text(
                json.dumps(
                    {
                        "schema_version": 1,
                        "label": "tracked-measurement-runner",
                        "source_commit": "c" * 40,
                        "xcode_version": "Xcode 16.4",
                        "swift_version": "Swift version 6.1.2",
                        "files": {},
                        "sha256": "0" * 64,
                    },
                    sort_keys=True,
                    separators=(",", ":"),
                )
                + "\n",
                encoding="utf-8",
            )

            completed = subprocess.run(
                [
                    "python3",
                    str(SCRIPT),
                    "verify",
                    "--closure",
                    str(closure),
                    "--identity",
                    str(identity),
                ],
                text=True,
                capture_output=True,
            )
            self.assertNotEqual(completed.returncode, 0)
            self.assertIn("symlink", completed.stderr.lower())


if __name__ == "__main__":
    unittest.main()
