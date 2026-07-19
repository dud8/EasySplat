import Foundation
import Testing

@testable import EasySplatMeasurementRunnerCore

@Suite("Measurement mapper evidence exporter")
struct MeasurementMapperEvidenceExporterTests {
  @Test("exports authenticated mapper options without cadence inference")
  func exportsAuthenticatedMapperOptions() throws {
    let cadence = MeasurementMapperCadenceEvidence(
      localMaxRefinements: 2,
      globalFramesRatio: 1.4,
      globalPointsRatio: 1.4,
      globalMaxRefinements: 5,
      localMaxNumIterations: 10,
      localFunctionTolerance: 0.001,
      globalFunctionTolerance: 0.000_001,
      localImageCount: 6
    )
    let invocation = MeasurementMapperInvocationEvidence(
      mappingAttemptOrdinal: 3,
      incrementalCadence: cadence,
      globalMaxNumIterations: 75,
      randomSeed: 42,
      refineFocalLength: true,
      minimumPairInlierCount: 15,
      pairGraphAttemptOrdinal: 2,
      pairListDigest: String(repeating: "a", count: 64),
      descriptorMatcher: "faiss",
      matchingDatabaseDigest: String(repeating: "b", count: 64),
      evaluation: MeasurementMapperEvaluationEvidence(
        status: "rejected",
        fallbackTrigger: "insufficientParallax"
      )
    )

    let exported = try MeasurementMapperEvidenceExporter.export([invocation])
    let item = try #require(exported.first)
    let exportedCadence = try #require(item["incremental_cadence"] as? [String: Any])
    let evaluation = try #require(item["evaluation"] as? [String: Any])
    let argv = try #require(item["argv"] as? [String])

    #expect(exported.count == 1)
    #expect(item["mapping_attempt_ordinal"] as? Int == 3)
    #expect(item["global_max_num_iterations"] as? Int == 75)
    #expect(item["random_seed"] as? Int32 == 42)
    #expect(item["refine_focal_length"] as? Bool == true)
    #expect(item["minimum_pair_inlier_count"] as? Int == 15)
    #expect(item["pair_graph_attempt_ordinal"] as? Int == 2)
    #expect(item["pair_list_digest"] as? String == "sha256:" + String(repeating: "a", count: 64))
    #expect(item["descriptor_matcher"] as? String == "faiss")
    #expect(item["matching_database_digest"] as? String == "sha256:" + String(repeating: "b", count: 64))
    #expect(exportedCadence["globalFramesRatio"] as? Double == 1.4)
    #expect(exportedCadence["localMaxRefinements"] as? Int == 2)
    #expect(evaluation["status"] as? String == "rejected")
    #expect(evaluation["fallback_trigger"] as? String == "insufficientParallax")
    #expect(argv.contains("--Mapper.ba_global_frames_ratio"))
    #expect(argv.contains("1.4"))
    #expect(argv.contains("--Mapper.ba_global_max_num_iterations"))
    #expect(argv.contains("75"))
    #expect(argv.contains("--Mapper.random_seed"))
    #expect(argv.contains("42"))
  }

  @Test("fails closed when successful mapper evaluation evidence is missing")
  func rejectsMissingEvaluation() {
    let invocation = MeasurementMapperInvocationEvidence(
      mappingAttemptOrdinal: 1,
      incrementalCadence: .orderedFast,
      globalMaxNumIterations: 50,
      randomSeed: 7,
      refineFocalLength: true,
      minimumPairInlierCount: 15,
      pairGraphAttemptOrdinal: 1,
      pairListDigest: String(repeating: "c", count: 64),
      descriptorMatcher: "exact",
      matchingDatabaseDigest: String(repeating: "d", count: 64),
      evaluation: nil
    )

    #expect(throws: MeasurementRunnerError.subprocessFailed(
      "successful mapper execution lacks authenticated evaluation evidence"
    )) {
      try MeasurementMapperEvidenceExporter.export([invocation])
    }
  }

  @Test("rejects an untyped cadence fallback trigger")
  func rejectsUntypedFallbackTrigger() {
    let invocation = MeasurementMapperInvocationEvidence(
      mappingAttemptOrdinal: 1,
      incrementalCadence: .orderedFast,
      globalMaxNumIterations: 50,
      randomSeed: 7,
      refineFocalLength: true,
      minimumPairInlierCount: 15,
      pairGraphAttemptOrdinal: 1,
      pairListDigest: String(repeating: "c", count: 64),
      descriptorMatcher: "faiss",
      matchingDatabaseDigest: String(repeating: "d", count: 64),
      evaluation: MeasurementMapperEvaluationEvidence(
        status: "rejected",
        fallbackTrigger: "freeform-retry"
      )
    )

    #expect(throws: MeasurementRunnerError.subprocessFailed(
      "authenticated mapper execution evidence is invalid"
    )) {
      try MeasurementMapperEvidenceExporter.export([invocation])
    }
  }
}
