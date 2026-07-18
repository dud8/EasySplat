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
    case localSiftVocabularyV1
}

public struct GeometryWorkerBudget: Codable, Sendable, Equatable {
    public var featureExtractionWorkers: Int
    public var coupledMatchingWorkers: Int
    public var vocabularyRetrievalWorkers: Int
    public var maximumConcurrentVideoSourceAnalysisTasks: Int

    public init(
        featureExtractionWorkers: Int,
        coupledMatchingWorkers: Int,
        vocabularyRetrievalWorkers: Int,
        maximumConcurrentVideoSourceAnalysisTasks: Int
    ) {
        self.featureExtractionWorkers = featureExtractionWorkers
        self.coupledMatchingWorkers = coupledMatchingWorkers
        self.vocabularyRetrievalWorkers = vocabularyRetrievalWorkers
        self.maximumConcurrentVideoSourceAnalysisTasks = maximumConcurrentVideoSourceAnalysisTasks
    }
}

public enum ResolvedRunPlanValidationError: Error, LocalizedError, Equatable {
    case emptyToolchainCapabilities
    case invalidBundleAdjustmentConfiguration
    case invalidGeometryWorkerBudget
    case invalidPairingConfiguration
    case unsupportedNormalDescriptorMatcher
    case unknownToolchainCapability(String)
    case unknownRouteIdentifier(String)

    public var errorDescription: String? {
        switch self {
        case .emptyToolchainCapabilities:
            return "Run plan does not request any tool capabilities."
        case .invalidBundleAdjustmentConfiguration:
            return "Run plan contains an invalid bundle-adjustment configuration."
        case .invalidGeometryWorkerBudget:
            return "Run plan contains an invalid geometry worker budget."
        case .invalidPairingConfiguration:
            return "Run plan contains an invalid image-pairing configuration."
        case .unsupportedNormalDescriptorMatcher:
            return "Run plan must use FAISS for normal descriptor matching."
        case .unknownToolchainCapability(let capability):
            return "Run plan requires an unsupported tool capability: \(capability)."
        case .unknownRouteIdentifier(let identifier):
            return "Run plan contains an unsupported geometry route: \(identifier)."
        }
    }
}

public struct ResolvedRunPlan: Codable, Sendable, Equatable {
    public var routeIdentifier: String
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
    public var refinementIterationLimit: Int
    public var trainerIterationLimit: Int
    public var plateauWindow: Int
    public var trainerMemoryBudgetBytes: Int64
    public var colmapMaximumFeatureCount: Int
    public var colmapMaximumMatchCount: Int
    public var geometryWorkerBudget: GeometryWorkerBudget
    public var requiredToolchainCapabilities: [String]
    public var fallbackRouteIdentifiers: [String]
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
        routeIdentifier: String,
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
        refinementIterationLimit: Int,
        trainerIterationLimit: Int,
        plateauWindow: Int,
        trainerMemoryBudgetBytes: Int64,
        colmapMaximumFeatureCount: Int = 8_192,
        colmapMaximumMatchCount: Int = 8_192,
        geometryWorkerBudget: GeometryWorkerBudget,
        requiredToolchainCapabilities: [String],
        fallbackRouteIdentifiers: [String],
        capturePath: CapturePath = .automatic,
        inputOrdering: InputOrdering = .automatic,
        photoSelection: PhotoSelection = .automatic,
        pairingPolicy: ResolvedPairingPolicy = .unorderedRetrieval,
        temporalPairing: TemporalPairing = .none,
        temporalOffsets: [Int] = [],
        retrievalEngine: RetrievalEngine = .localSiftVocabularyV1,
        retrievalCandidateCount: Int = 20,
        retrievalNeighborCount: Int = 8,
        retrievalQueryStride: Int = 1,
        normalDescriptorMatcher: DescriptorMatcher = .faiss,
        baGlobalFramesRatio: Double = 1.1,
        baGlobalPointsRatio: Double = 1.1,
        baLocalMaxRefinements: Int = 2,
        baGlobalMaxRefinements: Int = 5,
        baLocalMaxNumIterations: Int = 10,
        baLocalFunctionTolerance: Double = 0.001,
        baGlobalFunctionTolerance: Double = 0.000_001,
        baLocalImageCount: Int = 6,
        runSeed: UInt64 = 42
    ) {
        self.routeIdentifier = routeIdentifier
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
        self.refinementIterationLimit = refinementIterationLimit
        self.trainerIterationLimit = trainerIterationLimit
        self.plateauWindow = plateauWindow
        self.trainerMemoryBudgetBytes = trainerMemoryBudgetBytes
        self.colmapMaximumFeatureCount = colmapMaximumFeatureCount
        self.colmapMaximumMatchCount = colmapMaximumMatchCount
        self.geometryWorkerBudget = geometryWorkerBudget
        self.requiredToolchainCapabilities = requiredToolchainCapabilities
        self.fallbackRouteIdentifiers = fallbackRouteIdentifiers
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
        try validateGeometryWorkerBudget()
        try validatePairingConfiguration()
        try validateBundleAdjustmentConfiguration()
        _ = try validatedBackendOrder()
        _ = try validatedToolchainCapabilities()
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

    public func validatedBackendOrder() throws -> [SfmBackend] {
        let identifiers = [routeIdentifier] + fallbackRouteIdentifiers
        guard !identifiers.isEmpty else {
            throw ResolvedRunPlanValidationError.unknownRouteIdentifier("")
        }
        return try identifiers.map { identifier in
            guard let backend = SfmBackend(rawValue: identifier) else {
                throw ResolvedRunPlanValidationError.unknownRouteIdentifier(identifier)
            }
            return backend
        }
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
        guard offsetsAreValid,
              temporalPolicyIsCoherent,
              retrievalCandidateCount > 0,
              retrievalNeighborCount > 0,
              retrievalNeighborCount <= retrievalCandidateCount,
              retrievalQueryStride > 0 else {
            throw ResolvedRunPlanValidationError.invalidPairingConfiguration
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
