import Foundation

public struct MeasurementMapperCadenceEvidence: Sendable, Equatable {
  public let localMaxRefinements: Int
  public let globalFramesRatio: Double
  public let globalPointsRatio: Double
  public let globalMaxRefinements: Int
  public let localMaxNumIterations: Int
  public let localFunctionTolerance: Double
  public let globalFunctionTolerance: Double
  public let localImageCount: Int

  public init(
    localMaxRefinements: Int,
    globalFramesRatio: Double,
    globalPointsRatio: Double,
    globalMaxRefinements: Int,
    localMaxNumIterations: Int,
    localFunctionTolerance: Double,
    globalFunctionTolerance: Double,
    localImageCount: Int
  ) {
    self.localMaxRefinements = localMaxRefinements
    self.globalFramesRatio = globalFramesRatio
    self.globalPointsRatio = globalPointsRatio
    self.globalMaxRefinements = globalMaxRefinements
    self.localMaxNumIterations = localMaxNumIterations
    self.localFunctionTolerance = localFunctionTolerance
    self.globalFunctionTolerance = globalFunctionTolerance
    self.localImageCount = localImageCount
  }

  public static let orderedFast = Self(
    localMaxRefinements: 1,
    globalFramesRatio: 4,
    globalPointsRatio: 4,
    globalMaxRefinements: 5,
    localMaxNumIterations: 10,
    localFunctionTolerance: 0.001,
    globalFunctionTolerance: 0.000_001,
    localImageCount: 6
  )

  public var jsonObject: [String: Any] {
    [
      "localMaxRefinements": localMaxRefinements,
      "globalFramesRatio": globalFramesRatio,
      "globalPointsRatio": globalPointsRatio,
      "globalMaxRefinements": globalMaxRefinements,
      "localMaxNumIterations": localMaxNumIterations,
      "localFunctionTolerance": localFunctionTolerance,
      "globalFunctionTolerance": globalFunctionTolerance,
      "localImageCount": localImageCount,
    ]
  }

  fileprivate var isValid: Bool {
    localMaxRefinements > 0
      && globalFramesRatio.isFinite && globalFramesRatio > 1
      && globalPointsRatio.isFinite && globalPointsRatio > 1
      && globalMaxRefinements > 0
      && localMaxNumIterations > 0
      && localFunctionTolerance.isFinite && localFunctionTolerance > 0
      && globalFunctionTolerance.isFinite && globalFunctionTolerance > 0
      && localImageCount > 0
  }
}

public struct MeasurementMapperEvaluationEvidence: Sendable, Equatable {
  public let status: String
  public let fallbackTrigger: String?

  public init(status: String, fallbackTrigger: String?) {
    self.status = status
    self.fallbackTrigger = fallbackTrigger
  }
}

public struct MeasurementMapperInvocationEvidence: Sendable, Equatable {
  public let mappingAttemptOrdinal: Int
  public let incrementalCadence: MeasurementMapperCadenceEvidence
  public let globalMaxNumIterations: Int
  public let randomSeed: Int32
  public let refineFocalLength: Bool
  public let minimumPairInlierCount: Int
  public let pairGraphAttemptOrdinal: Int
  public let pairListDigest: String
  public let descriptorMatcher: String
  public let matchingDatabaseDigest: String
  public let evaluation: MeasurementMapperEvaluationEvidence?

  public init(
    mappingAttemptOrdinal: Int,
    incrementalCadence: MeasurementMapperCadenceEvidence,
    globalMaxNumIterations: Int,
    randomSeed: Int32,
    refineFocalLength: Bool,
    minimumPairInlierCount: Int,
    pairGraphAttemptOrdinal: Int,
    pairListDigest: String,
    descriptorMatcher: String,
    matchingDatabaseDigest: String,
    evaluation: MeasurementMapperEvaluationEvidence?
  ) {
    self.mappingAttemptOrdinal = mappingAttemptOrdinal
    self.incrementalCadence = incrementalCadence
    self.globalMaxNumIterations = globalMaxNumIterations
    self.randomSeed = randomSeed
    self.refineFocalLength = refineFocalLength
    self.minimumPairInlierCount = minimumPairInlierCount
    self.pairGraphAttemptOrdinal = pairGraphAttemptOrdinal
    self.pairListDigest = pairListDigest
    self.descriptorMatcher = descriptorMatcher
    self.matchingDatabaseDigest = matchingDatabaseDigest
    self.evaluation = evaluation
  }
}

public enum MeasurementMapperEvidenceExporter {
  public static func export(
    _ invocations: [MeasurementMapperInvocationEvidence]
  ) throws -> [[String: Any]] {
    try invocations.map { invocation in
      guard let evaluation = invocation.evaluation else {
        throw MeasurementRunnerError.subprocessFailed(
          "successful mapper execution lacks authenticated evaluation evidence"
        )
      }
      guard invocation.mappingAttemptOrdinal > 0,
        invocation.incrementalCadence.isValid,
        invocation.globalMaxNumIterations > 0,
        invocation.randomSeed >= 0,
        invocation.refineFocalLength,
        invocation.minimumPairInlierCount > 0,
        invocation.pairGraphAttemptOrdinal > 0,
        isSHA256(invocation.pairListDigest),
        ["faiss", "exact"].contains(invocation.descriptorMatcher),
        isSHA256(invocation.matchingDatabaseDigest),
        ["accepted", "rejected", "interrupted", "failed"].contains(evaluation.status),
        evaluation.status == "rejected" || evaluation.fallbackTrigger == nil,
        evaluation.fallbackTrigger.map(allowedFallbackTriggers.contains) ?? true
      else {
        throw MeasurementRunnerError.subprocessFailed(
          "authenticated mapper execution evidence is invalid"
        )
      }
      return [
        "argv": argv(for: invocation),
        "mapping_attempt_ordinal": invocation.mappingAttemptOrdinal,
        "incremental_cadence": invocation.incrementalCadence.jsonObject,
        "global_max_num_iterations": invocation.globalMaxNumIterations,
        "random_seed": invocation.randomSeed,
        "refine_focal_length": invocation.refineFocalLength,
        "minimum_pair_inlier_count": invocation.minimumPairInlierCount,
        "pair_graph_attempt_ordinal": invocation.pairGraphAttemptOrdinal,
        "pair_list_digest": "sha256:\(invocation.pairListDigest)",
        "descriptor_matcher": invocation.descriptorMatcher,
        "matching_database_digest": "sha256:\(invocation.matchingDatabaseDigest)",
        "evaluation": [
          "status": evaluation.status,
          "fallback_trigger": evaluation.fallbackTrigger.map { $0 as Any } ?? NSNull(),
        ],
      ]
    }
  }

  private static func argv(for invocation: MeasurementMapperInvocationEvidence) -> [String] {
    let cadence = invocation.incrementalCadence
    return [
      "toolchain://resolved/bin/colmap", "mapper",
      "--Mapper.ba_global_frames_ratio", String(cadence.globalFramesRatio),
      "--Mapper.ba_global_points_ratio", String(cadence.globalPointsRatio),
      "--Mapper.ba_local_max_refinements", String(cadence.localMaxRefinements),
      "--Mapper.ba_global_max_refinements", String(cadence.globalMaxRefinements),
      "--Mapper.ba_global_max_num_iterations", String(invocation.globalMaxNumIterations),
      "--Mapper.ba_local_max_num_iterations", String(cadence.localMaxNumIterations),
      "--Mapper.ba_local_function_tolerance", String(cadence.localFunctionTolerance),
      "--Mapper.ba_global_function_tolerance", String(cadence.globalFunctionTolerance),
      "--Mapper.ba_local_num_images", String(cadence.localImageCount),
      "--Mapper.random_seed", String(invocation.randomSeed),
      "--Mapper.min_num_matches", String(invocation.minimumPairInlierCount),
      "--Mapper.ba_refine_focal_length", invocation.refineFocalLength ? "1" : "0",
    ]
  }

  private static func isSHA256(_ value: String) -> Bool {
    value.range(of: #"^[0-9a-f]{64}$"#, options: .regularExpression) != nil
  }

  private static let allowedFallbackTriggers: Set<String> = [
    "insufficientViewSupport",
    "collapsedCameraTrajectory",
    "insufficientParallax",
    "degeneratePointDistribution",
    "lowReconstructionQuality",
    "fragmentedReconstruction",
    "lowRegisteredViewCoverage",
    "sparseResidualCoverage",
    "excessiveResiduals",
  ]
}
