import Foundation

public enum ResolvedPairingPolicy: String, Codable, Sendable, Equatable {
    case unorderedRetrieval
    case segmentedMixed
    case orderedContinuous
    case orderedOrbit
    case orderedWalkthrough
    case orderedLargeArea
}

public enum TemporalPairing: String, Codable, Sendable, Equatable {
    case none
    case linear
    case multiscale
}

public enum RetrievalEngine: String, Codable, Sendable, Equatable {
    case localSiftVocabularyV2
}

public struct GeometryWorkerBudget: Codable, Sendable, Equatable {
    public var featureExtractionWorkers: Int
    public var coupledMatchingWorkers: Int
    public var vocabularyRetrievalWorkers: Int
    public var maximumConcurrentVideoSourceAnalysisTasks: Int
    /// Memory ceiling handed to the native vocabulary retriever. Sized to the
    /// host's installed RAM by the resolver; bounded by the tool's own
    /// `[64 MiB, 256 GiB]` limits (see `ColmapVocabularyRetrievalOptions`).
    public var retrievalMemoryBudgetBytes: Int64

    public init(
        featureExtractionWorkers: Int,
        coupledMatchingWorkers: Int,
        vocabularyRetrievalWorkers: Int,
        maximumConcurrentVideoSourceAnalysisTasks: Int,
        retrievalMemoryBudgetBytes: Int64 = ColmapVocabularyRetrievalOptions.defaultMemoryBudgetBytes
    ) {
        self.featureExtractionWorkers = featureExtractionWorkers
        self.coupledMatchingWorkers = coupledMatchingWorkers
        self.vocabularyRetrievalWorkers = vocabularyRetrievalWorkers
        self.maximumConcurrentVideoSourceAnalysisTasks = maximumConcurrentVideoSourceAnalysisTasks
        self.retrievalMemoryBudgetBytes = retrievalMemoryBudgetBytes
    }

    private enum CodingKeys: String, CodingKey {
        case featureExtractionWorkers
        case coupledMatchingWorkers
        case vocabularyRetrievalWorkers
        case maximumConcurrentVideoSourceAnalysisTasks
        case retrievalMemoryBudgetBytes
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        featureExtractionWorkers = try container.decode(Int.self, forKey: .featureExtractionWorkers)
        coupledMatchingWorkers = try container.decode(Int.self, forKey: .coupledMatchingWorkers)
        vocabularyRetrievalWorkers = try container.decode(
            Int.self, forKey: .vocabularyRetrievalWorkers
        )
        maximumConcurrentVideoSourceAnalysisTasks = try container.decode(
            Int.self, forKey: .maximumConcurrentVideoSourceAnalysisTasks
        )
        // Plans persisted before retrieval budgeting decode at the tool's former
        // built-in default, preserving their historical behavior exactly.
        retrievalMemoryBudgetBytes = try container.decodeIfPresent(
            Int64.self, forKey: .retrievalMemoryBudgetBytes
        ) ?? ColmapVocabularyRetrievalOptions.defaultMemoryBudgetBytes
    }
}

public enum ResolvedRunPlanValidationError: Error, LocalizedError, Equatable {
    case emptyToolchainCapabilities
    case incompatibleCameraPolicy
    case incompatibleGeometryBackendConfiguration
    case invalidBundleAdjustmentConfiguration
    case invalidGeometryWorkerBudget
    case invalidPairingConfiguration
    case randomSeedOutOfRange
    case unsupportedNormalDescriptorMatcher
    case unknownToolchainCapability(String)

    public var errorDescription: String? {
        switch self {
        case .emptyToolchainCapabilities:
            return "Run plan does not request any tool capabilities."
        case .incompatibleCameraPolicy:
            return "Run plan uses a geometry route that is incompatible with its camera policy."
        case .incompatibleGeometryBackendConfiguration:
            return "Run plan geometry backend, model, and tool capabilities do not agree."
        case .invalidBundleAdjustmentConfiguration:
            return "Run plan contains an invalid bundle-adjustment configuration."
        case .invalidGeometryWorkerBudget:
            return "Run plan contains an invalid geometry worker budget."
        case .invalidPairingConfiguration:
            return "Run plan contains an invalid image-pairing configuration."
        case .randomSeedOutOfRange:
            return "Run plan random seed must fit in a signed 32-bit integer."
        case .unsupportedNormalDescriptorMatcher:
            return "Run plan must use FAISS for normal descriptor matching."
        case .unknownToolchainCapability(let capability):
            return "Run plan requires an unsupported tool capability: \(capability)."
        }
    }
}

public struct ResolvedRunPlan: Codable, Sendable, Equatable {
    public var geometryBackend: SfmBackend
    public var modelIdentifier: String
    public var memoryTier: String
    public var chunkSize: Int
    public var geometryProcessResolution: Int
    public var analysisFrameRate: Int
    public var keyframeBudget: Int
    public var maximumImageDimension: Int
    public var colmapMaximumImageDimension: Int
    public var cameraGrouping: CameraGrouping
    public var lensProjection: LensProjection
    public var cameraInitializationRecipe: ColmapCameraInitializationRecipe
    public var refinementIterationLimit: Int
    public var trainerIterationLimit: Int
    public var plateauWindow: Int
    public var trainerMemoryBudgetBytes: Int64
    public var colmapMaximumFeatureCount: Int
    public var colmapMaximumMatchCount: Int
    public var geometryWorkerBudget: GeometryWorkerBudget
    public var requiredToolchainCapabilities: [String]
    public var capturePath: CapturePath
    public var inputOrdering: InputOrdering
    public var photoSelection: PhotoSelection
    public var pairingPolicy: ResolvedPairingPolicy
    public var temporalPairing: TemporalPairing
    public var temporalOffsets: [Int]
    public var retrievalEngine: RetrievalEngine
    public var retrievalCandidateCount: Int
    public var retrievalNeighborCount: Int
    public var retrievalQueryStride: Int
    public var requiresCrossClipRetrieval: Bool
    public var normalDescriptorMatcher: DescriptorMatcher
    public var baGlobalFramesRatio: Double
    public var baGlobalPointsRatio: Double
    public var baLocalMaxRefinements: Int
    public var baGlobalMaxRefinements: Int
    public var baLocalMaxNumIterations: Int
    public var baLocalFunctionTolerance: Double
    public var baGlobalFunctionTolerance: Double
    public var baLocalImageCount: Int
    public var runSeed: UInt64

    public init(
        geometryBackend: SfmBackend,
        modelIdentifier: String,
        memoryTier: String,
        chunkSize: Int,
        geometryProcessResolution: Int = 0,
        analysisFrameRate: Int = 3,
        keyframeBudget: Int,
        maximumImageDimension: Int,
        colmapMaximumImageDimension: Int = 1_024,
        cameraGrouping: CameraGrouping,
        lensProjection: LensProjection,
        cameraInitializationRecipe: ColmapCameraInitializationRecipe = .colmapAutomatic,
        refinementIterationLimit: Int,
        trainerIterationLimit: Int,
        plateauWindow: Int,
        trainerMemoryBudgetBytes: Int64,
        colmapMaximumFeatureCount: Int = 8_192,
        colmapMaximumMatchCount: Int = 8_192,
        geometryWorkerBudget: GeometryWorkerBudget,
        requiredToolchainCapabilities: [String],
        capturePath: CapturePath = .automatic,
        inputOrdering: InputOrdering = .automatic,
        photoSelection: PhotoSelection = .automatic,
        pairingPolicy: ResolvedPairingPolicy = .unorderedRetrieval,
        temporalPairing: TemporalPairing = .none,
        temporalOffsets: [Int] = [],
        retrievalEngine: RetrievalEngine = .localSiftVocabularyV2,
        retrievalCandidateCount: Int = 20,
        retrievalNeighborCount: Int = 8,
        retrievalQueryStride: Int = 1,
        requiresCrossClipRetrieval: Bool = false,
        normalDescriptorMatcher: DescriptorMatcher = .faiss,
        baGlobalFramesRatio: Double = 1.4,
        baGlobalPointsRatio: Double = 1.4,
        baLocalMaxRefinements: Int = 2,
        baGlobalMaxRefinements: Int = 5,
        baLocalMaxNumIterations: Int = 10,
        baLocalFunctionTolerance: Double = 0.001,
        baGlobalFunctionTolerance: Double = 0.000_001,
        baLocalImageCount: Int = 6,
        runSeed: UInt64 = 42
    ) {
        self.geometryBackend = geometryBackend
        self.modelIdentifier = modelIdentifier
        self.memoryTier = memoryTier
        self.chunkSize = chunkSize
        self.geometryProcessResolution = geometryProcessResolution
        self.analysisFrameRate = analysisFrameRate
        self.keyframeBudget = keyframeBudget
        self.maximumImageDimension = maximumImageDimension
        self.colmapMaximumImageDimension = colmapMaximumImageDimension
        self.cameraGrouping = cameraGrouping
        self.lensProjection = lensProjection
        self.cameraInitializationRecipe = cameraInitializationRecipe
        self.refinementIterationLimit = refinementIterationLimit
        self.trainerIterationLimit = trainerIterationLimit
        self.plateauWindow = plateauWindow
        self.trainerMemoryBudgetBytes = trainerMemoryBudgetBytes
        self.colmapMaximumFeatureCount = colmapMaximumFeatureCount
        self.colmapMaximumMatchCount = colmapMaximumMatchCount
        self.geometryWorkerBudget = geometryWorkerBudget
        self.requiredToolchainCapabilities = requiredToolchainCapabilities
        self.capturePath = capturePath
        self.inputOrdering = inputOrdering
        self.photoSelection = photoSelection
        self.pairingPolicy = pairingPolicy
        self.temporalPairing = temporalPairing
        self.temporalOffsets = temporalOffsets
        self.retrievalEngine = retrievalEngine
        self.retrievalCandidateCount = retrievalCandidateCount
        self.retrievalNeighborCount = retrievalNeighborCount
        self.retrievalQueryStride = retrievalQueryStride
        self.requiresCrossClipRetrieval = requiresCrossClipRetrieval
        self.normalDescriptorMatcher = normalDescriptorMatcher
        self.baGlobalFramesRatio = baGlobalFramesRatio
        self.baGlobalPointsRatio = baGlobalPointsRatio
        self.baLocalMaxRefinements = baLocalMaxRefinements
        self.baGlobalMaxRefinements = baGlobalMaxRefinements
        self.baLocalMaxNumIterations = baLocalMaxNumIterations
        self.baLocalFunctionTolerance = baLocalFunctionTolerance
        self.baGlobalFunctionTolerance = baGlobalFunctionTolerance
        self.baLocalImageCount = baLocalImageCount
        self.runSeed = runSeed
    }

    public func validate() throws {
        _ = try validatedToolchainCapabilities()
        try validateGeometryBackendConfiguration()
        try validateCameraPolicy()
        try validateGeometryWorkerBudget()
        try validatePairingConfiguration()
        try validateBundleAdjustmentConfiguration()
        guard runSeed <= UInt64(Int32.max) else {
            throw ResolvedRunPlanValidationError.randomSeedOutOfRange
        }
    }

    public func toolchainCapabilityRequest() throws -> ToolchainCapabilityRequest {
        try validate()
        return ToolchainCapabilityRequest(
            capabilities: try validatedToolchainCapabilities()
        )
    }

    private func validatedToolchainCapabilities() throws -> Set<ToolchainCapability> {
        var capabilities = Set<ToolchainCapability>()
        for rawValue in requiredToolchainCapabilities {
            guard let capability = ToolchainCapability(rawValue: rawValue) else {
                throw ResolvedRunPlanValidationError.unknownToolchainCapability(rawValue)
            }
            capabilities.insert(capability)
        }
        guard !capabilities.isEmpty else {
            throw ResolvedRunPlanValidationError.emptyToolchainCapabilities
        }
        return capabilities
    }

    public var incrementalMappingCadence: IncrementalMappingCadenceArtifact {
        IncrementalMappingCadenceArtifact(
            localMaxRefinements: baLocalMaxRefinements,
            globalFramesRatio: baGlobalFramesRatio,
            globalPointsRatio: baGlobalPointsRatio,
            globalMaxRefinements: baGlobalMaxRefinements,
            localMaxNumIterations: baLocalMaxNumIterations,
            localFunctionTolerance: baLocalFunctionTolerance,
            globalFunctionTolerance: baGlobalFunctionTolerance,
            localImageCount: baLocalImageCount
        )
    }

    private func validatePairingConfiguration() throws {
        guard normalDescriptorMatcher == .faiss else {
            throw ResolvedRunPlanValidationError.unsupportedNormalDescriptorMatcher
        }
        let offsetsAreValid = temporalOffsets.allSatisfy { $0 > 0 }
            && temporalOffsets == temporalOffsets.sorted()
            && Set(temporalOffsets).count == temporalOffsets.count
        let temporalPolicyIsCoherent = temporalPairing == .none
            ? temporalOffsets.isEmpty
            : !temporalOffsets.isEmpty
        let crossClipRetrievalIsCoherent: Bool
        if requiresCrossClipRetrieval {
            switch pairingPolicy {
            case .orderedContinuous,
                 .orderedOrbit,
                 .orderedWalkthrough,
                 .orderedLargeArea:
                crossClipRetrievalIsCoherent = inputOrdering == .continuous
                    && temporalPairing != .none
            case .segmentedMixed:
                crossClipRetrievalIsCoherent = temporalPairing != .none
            case .unorderedRetrieval:
                crossClipRetrievalIsCoherent = false
            }
        } else {
            crossClipRetrievalIsCoherent = true
        }
        guard offsetsAreValid,
              temporalPolicyIsCoherent,
              crossClipRetrievalIsCoherent,
              retrievalCandidateCount > 0,
              retrievalNeighborCount > 0,
              retrievalNeighborCount <= retrievalCandidateCount,
              retrievalQueryStride > 0 else {
            throw ResolvedRunPlanValidationError.invalidPairingConfiguration
        }
    }

    private func validateCameraPolicy() throws {
        guard cameraInitializationRecipe == ColmapCameraInitializationRecipe.resolve(
            lensProjection: lensProjection,
            cameraGrouping: cameraGrouping
        ) else {
            throw ResolvedRunPlanValidationError.incompatibleCameraPolicy
        }
        guard cameraGrouping == .mixedCamerasOrLenses
                || lensProjection == .fisheye
                || requiresCrossClipRetrieval else {
            return
        }
        if geometryBackend == .da3 {
            throw ResolvedRunPlanValidationError.incompatibleCameraPolicy
        }
    }

    private func validateGeometryBackendConfiguration() throws {
        let expectedCapabilities: [String]
        switch geometryBackend {
        case .colmap:
            guard modelIdentifier == "none" else {
                throw ResolvedRunPlanValidationError.incompatibleGeometryBackendConfiguration
            }
            expectedCapabilities = [
                ToolchainCapability.colmap.rawValue,
                ToolchainCapability.core.rawValue,
                ToolchainCapability.msplat.rawValue,
            ]
        case .da3:
            let modelCapability: ToolchainCapability
            switch (memoryTier, modelIdentifier) {
            case ("standard", "DA3-BASE"), ("performance", "DA3-BASE"):
                modelCapability = .da3Base
            case ("constrained", "DA3-SMALL"):
                modelCapability = .da3Small
            default:
                throw ResolvedRunPlanValidationError.incompatibleGeometryBackendConfiguration
            }
            expectedCapabilities = [
                ToolchainCapability.colmap.rawValue,
                ToolchainCapability.da3Runtime.rawValue,
                ToolchainCapability.core.rawValue,
                ToolchainCapability.msplat.rawValue,
                modelCapability.rawValue,
            ].sorted()
        }
        guard requiredToolchainCapabilities == expectedCapabilities else {
            throw ResolvedRunPlanValidationError.incompatibleGeometryBackendConfiguration
        }
    }

    private func validateGeometryWorkerBudget() throws {
        let counts = [
            geometryWorkerBudget.featureExtractionWorkers,
            geometryWorkerBudget.coupledMatchingWorkers,
            geometryWorkerBudget.vocabularyRetrievalWorkers,
            geometryWorkerBudget.maximumConcurrentVideoSourceAnalysisTasks,
        ]
        guard counts.allSatisfy({ (1...64).contains($0) }) else {
            throw ResolvedRunPlanValidationError.invalidGeometryWorkerBudget
        }
        let retrievalBudgetBounds = ClosedRange(
            uncheckedBounds: (
                lower: ColmapVocabularyRetrievalOptions.minimumMemoryBudgetBytes,
                upper: ColmapVocabularyRetrievalOptions.maximumMemoryBudgetBytes
            )
        )
        guard retrievalBudgetBounds.contains(geometryWorkerBudget.retrievalMemoryBudgetBytes) else {
            throw ResolvedRunPlanValidationError.invalidGeometryWorkerBudget
        }
    }

    private func validateBundleAdjustmentConfiguration() throws {
        guard baGlobalFramesRatio.isFinite,
              baGlobalFramesRatio > 1,
              baGlobalPointsRatio.isFinite,
              baGlobalPointsRatio > 1,
              baLocalMaxRefinements > 0,
              baGlobalMaxRefinements > 0,
              baLocalMaxNumIterations > 0,
              baLocalFunctionTolerance.isFinite,
              baLocalFunctionTolerance > 0,
              baGlobalFunctionTolerance.isFinite,
              baGlobalFunctionTolerance > 0,
              baLocalImageCount > 0 else {
            throw ResolvedRunPlanValidationError.invalidBundleAdjustmentConfiguration
        }
    }
}
