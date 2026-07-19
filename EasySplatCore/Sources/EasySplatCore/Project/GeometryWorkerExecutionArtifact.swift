import CryptoKit
import Foundation

public enum GeometryWorkerThreadPolicy: String, Codable, Sendable, Equatable {
    case bounded
    case nativeAuto
}

public enum ColmapWorkerCommandIdentity: String, Codable, Sendable, Equatable, Hashable {
    case featureExtractor
    case featureImporter
    case matchesImporter
    case localVocabularyRetriever
    case mapper
    case pointTriangulator
    case bundleAdjuster
    case modelAnalyzer
    case modelConverter
}

public struct ColmapPairWorkerExecutionEvidence: Codable, Sendable, Equatable {
    public var attemptOrdinal: Int
    public var descriptorMatcher: DescriptorMatcher
    public var scheduledPairCount: Int?
    public var pairListDigest: String?
    public var exactRecoveryReason: DescriptorMatcherRecoveryReason?
    public var retrievalRequestDigest: String?
    public var retrievalOutputDigest: String?

    public init(
        attemptOrdinal: Int,
        descriptorMatcher: DescriptorMatcher,
        scheduledPairCount: Int? = nil,
        pairListDigest: String? = nil,
        exactRecoveryReason: DescriptorMatcherRecoveryReason? = nil,
        retrievalRequestDigest: String? = nil,
        retrievalOutputDigest: String? = nil
    ) {
        self.attemptOrdinal = attemptOrdinal
        self.descriptorMatcher = descriptorMatcher
        self.scheduledPairCount = scheduledPairCount
        self.pairListDigest = pairListDigest
        self.exactRecoveryReason = exactRecoveryReason
        self.retrievalRequestDigest = retrievalRequestDigest
        self.retrievalOutputDigest = retrievalOutputDigest
    }
}

public struct ColmapModelConversionWorkerEvidence: Codable, Sendable, Equatable {
    public var executableComponentPath: String
    public var executableSHA256: String
    public var candidateProjectRelativePath: String
    public var inputProjectRelativePath: String
    public var outputProjectRelativePath: String
    public var sourceModelDigest: String
    public var convertedModelDigest: String?
    public var candidateIdentitySHA256: String

    public init(
        executableComponentPath: String,
        executableSHA256: String,
        candidateProjectRelativePath: String,
        inputProjectRelativePath: String,
        outputProjectRelativePath: String,
        sourceModelDigest: String,
        convertedModelDigest: String?,
        candidateIdentitySHA256: String
    ) {
        self.executableComponentPath = executableComponentPath
        self.executableSHA256 = executableSHA256
        self.candidateProjectRelativePath = candidateProjectRelativePath
        self.inputProjectRelativePath = inputProjectRelativePath
        self.outputProjectRelativePath = outputProjectRelativePath
        self.sourceModelDigest = sourceModelDigest
        self.convertedModelDigest = convertedModelDigest
        self.candidateIdentitySHA256 = candidateIdentitySHA256
    }
}

public enum ColmapMapperEvaluationStatus: String, Codable, Sendable, Equatable {
    case accepted
    case rejected
    case interrupted
    case failed
}

public struct ColmapMapperEvaluationEvidence: Codable, Sendable, Equatable {
    private enum CodingKeys: String, CodingKey, CaseIterable {
        case status
        case fallbackTrigger
    }

    private struct DynamicCodingKey: CodingKey {
        let stringValue: String
        let intValue: Int? = nil

        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { return nil }
    }

    public var status: ColmapMapperEvaluationStatus
    public var fallbackTrigger: MappingCadenceFallbackTrigger?

    public init(
        status: ColmapMapperEvaluationStatus,
        fallbackTrigger: MappingCadenceFallbackTrigger?
    ) {
        self.status = status
        self.fallbackTrigger = fallbackTrigger
    }

    public init(from decoder: Decoder) throws {
        let untyped = try decoder.container(keyedBy: DynamicCodingKey.self)
        guard Set(untyped.allKeys.map(\.stringValue))
                == Set(CodingKeys.allCases.map(\.rawValue)) else {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(
                    codingPath: decoder.codingPath,
                    debugDescription: "Mapper evaluation keys do not match the current schema."
                )
            )
        }
        let container = try decoder.container(keyedBy: CodingKeys.self)
        status = try container.decode(ColmapMapperEvaluationStatus.self, forKey: .status)
        fallbackTrigger = try container.decodeIfPresent(
            MappingCadenceFallbackTrigger.self,
            forKey: .fallbackTrigger
        )
        guard isValid else {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(
                    codingPath: decoder.codingPath,
                    debugDescription: "Mapper evaluation is internally inconsistent."
                )
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(status, forKey: .status)
        if let fallbackTrigger {
            try container.encode(fallbackTrigger, forKey: .fallbackTrigger)
        } else {
            try container.encodeNil(forKey: .fallbackTrigger)
        }
    }

    var isValid: Bool {
        switch status {
        case .accepted, .interrupted, .failed:
            return fallbackTrigger == nil
        case .rejected:
            return true
        }
    }
}

public struct ColmapMapperWorkerExecutionEvidence: Codable, Sendable, Equatable {
    private enum CodingKeys: String, CodingKey, CaseIterable {
        case incrementalCadence
        case globalMaxNumIterations
        case randomSeed
        case refineFocalLength
        case minimumPairInlierCount
        case pairGraphAttemptOrdinal
        case pairListDigest
        case descriptorMatcher
        case matchingDatabaseDigest
        case evaluation
    }

    private struct DynamicCodingKey: CodingKey {
        let stringValue: String
        let intValue: Int? = nil

        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { return nil }
    }

    public var incrementalCadence: IncrementalMappingCadenceArtifact
    public var globalMaxNumIterations: Int
    public var randomSeed: Int32
    public var refineFocalLength: Bool
    public var minimumPairInlierCount: Int
    public var pairGraphAttemptOrdinal: Int
    public var pairListDigest: String
    public var descriptorMatcher: DescriptorMatcher
    public var matchingDatabaseDigest: String
    public var evaluation: ColmapMapperEvaluationEvidence?

    public init(
        incrementalCadence: IncrementalMappingCadenceArtifact,
        globalMaxNumIterations: Int,
        randomSeed: Int32,
        refineFocalLength: Bool,
        minimumPairInlierCount: Int,
        pairGraphAttemptOrdinal: Int,
        pairListDigest: String,
        descriptorMatcher: DescriptorMatcher,
        matchingDatabaseDigest: String,
        evaluation: ColmapMapperEvaluationEvidence?
    ) {
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

    public init(from decoder: Decoder) throws {
        let untyped = try decoder.container(keyedBy: DynamicCodingKey.self)
        guard Set(untyped.allKeys.map(\.stringValue))
                == Set(CodingKeys.allCases.map(\.rawValue)) else {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(
                    codingPath: decoder.codingPath,
                    debugDescription: "Mapper execution keys do not match the current schema."
                )
            )
        }
        let container = try decoder.container(keyedBy: CodingKeys.self)
        incrementalCadence = try container.decode(
            IncrementalMappingCadenceArtifact.self,
            forKey: .incrementalCadence
        )
        globalMaxNumIterations = try container.decode(
            Int.self,
            forKey: .globalMaxNumIterations
        )
        randomSeed = try container.decode(Int32.self, forKey: .randomSeed)
        refineFocalLength = try container.decode(Bool.self, forKey: .refineFocalLength)
        minimumPairInlierCount = try container.decode(
            Int.self,
            forKey: .minimumPairInlierCount
        )
        pairGraphAttemptOrdinal = try container.decode(
            Int.self,
            forKey: .pairGraphAttemptOrdinal
        )
        pairListDigest = try container.decode(String.self, forKey: .pairListDigest)
        descriptorMatcher = try container.decode(
            DescriptorMatcher.self,
            forKey: .descriptorMatcher
        )
        matchingDatabaseDigest = try container.decode(
            String.self,
            forKey: .matchingDatabaseDigest
        )
        evaluation = try container.decodeIfPresent(
            ColmapMapperEvaluationEvidence.self,
            forKey: .evaluation
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(incrementalCadence, forKey: .incrementalCadence)
        try container.encode(globalMaxNumIterations, forKey: .globalMaxNumIterations)
        try container.encode(randomSeed, forKey: .randomSeed)
        try container.encode(refineFocalLength, forKey: .refineFocalLength)
        try container.encode(minimumPairInlierCount, forKey: .minimumPairInlierCount)
        try container.encode(pairGraphAttemptOrdinal, forKey: .pairGraphAttemptOrdinal)
        try container.encode(pairListDigest, forKey: .pairListDigest)
        try container.encode(descriptorMatcher, forKey: .descriptorMatcher)
        try container.encode(matchingDatabaseDigest, forKey: .matchingDatabaseDigest)
        if let evaluation {
            try container.encode(evaluation, forKey: .evaluation)
        } else {
            try container.encodeNil(forKey: .evaluation)
        }
    }
}

public struct ColmapWorkerInvocationEvidence: Codable, Sendable, Equatable {
    private enum CodingKeys: String, CodingKey, CaseIterable {
        case command
        case mappingAttemptOrdinal
        case threadPolicy
        case argvWorkerCount
        case explicitThreadEnvironment
        case removedThreadEnvironmentKeysSHA256
        case effectiveSanitizedThreadEnvironment
        case pairExecution
        case mapperExecution
        case modelConversion
        case exitStatus
        case succeeded
    }

    private struct DynamicCodingKey: CodingKey {
        let stringValue: String
        let intValue: Int? = nil

        init?(stringValue: String) {
            self.stringValue = stringValue
        }

        init?(intValue: Int) {
            return nil
        }
    }

    public var command: ColmapWorkerCommandIdentity
    public var mappingAttemptOrdinal: Int?
    public var threadPolicy: GeometryWorkerThreadPolicy
    public var argvWorkerCount: Int?
    public var explicitThreadEnvironment: [String: String]
    public var removedThreadEnvironmentKeysSHA256: String
    public var effectiveSanitizedThreadEnvironment: [String: String]
    public var pairExecution: ColmapPairWorkerExecutionEvidence?
    public var mapperExecution: ColmapMapperWorkerExecutionEvidence?
    public var modelConversion: ColmapModelConversionWorkerEvidence?
    public var exitStatus: Int32
    public var succeeded: Bool

    public init(
        command: ColmapWorkerCommandIdentity,
        mappingAttemptOrdinal: Int?,
        threadPolicy: GeometryWorkerThreadPolicy,
        argvWorkerCount: Int?,
        explicitThreadEnvironment: [String: String],
        removedThreadEnvironmentKeysSHA256: String,
        effectiveSanitizedThreadEnvironment: [String: String],
        pairExecution: ColmapPairWorkerExecutionEvidence? = nil,
        mapperExecution: ColmapMapperWorkerExecutionEvidence? = nil,
        modelConversion: ColmapModelConversionWorkerEvidence? = nil,
        exitStatus: Int32,
        succeeded: Bool
    ) {
        self.command = command
        self.mappingAttemptOrdinal = mappingAttemptOrdinal
        self.threadPolicy = threadPolicy
        self.argvWorkerCount = argvWorkerCount
        self.explicitThreadEnvironment = explicitThreadEnvironment
        self.removedThreadEnvironmentKeysSHA256 = removedThreadEnvironmentKeysSHA256
        self.effectiveSanitizedThreadEnvironment = effectiveSanitizedThreadEnvironment
        self.pairExecution = pairExecution
        self.mapperExecution = mapperExecution
        self.modelConversion = modelConversion
        self.exitStatus = exitStatus
        self.succeeded = succeeded
    }

    public init(from decoder: Decoder) throws {
        let untypedContainer = try decoder.container(keyedBy: DynamicCodingKey.self)
        let expectedKeys = Set(CodingKeys.allCases.map(\.rawValue))
        let actualKeys = Set(untypedContainer.allKeys.map(\.stringValue))
        guard actualKeys == expectedKeys else {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(
                    codingPath: decoder.codingPath,
                    debugDescription: "Worker invocation keys do not match the current schema."
                )
            )
        }

        let container = try decoder.container(keyedBy: CodingKeys.self)
        command = try container.decode(ColmapWorkerCommandIdentity.self, forKey: .command)
        mappingAttemptOrdinal = try container.decodeIfPresent(
            Int.self,
            forKey: .mappingAttemptOrdinal
        )
        threadPolicy = try container.decode(
            GeometryWorkerThreadPolicy.self,
            forKey: .threadPolicy
        )
        argvWorkerCount = try container.decodeIfPresent(Int.self, forKey: .argvWorkerCount)
        explicitThreadEnvironment = try container.decode(
            [String: String].self,
            forKey: .explicitThreadEnvironment
        )
        removedThreadEnvironmentKeysSHA256 = try container.decode(
            String.self,
            forKey: .removedThreadEnvironmentKeysSHA256
        )
        effectiveSanitizedThreadEnvironment = try container.decode(
            [String: String].self,
            forKey: .effectiveSanitizedThreadEnvironment
        )
        pairExecution = try container.decodeIfPresent(
            ColmapPairWorkerExecutionEvidence.self,
            forKey: .pairExecution
        )
        mapperExecution = try container.decodeIfPresent(
            ColmapMapperWorkerExecutionEvidence.self,
            forKey: .mapperExecution
        )
        modelConversion = try container.decodeIfPresent(
            ColmapModelConversionWorkerEvidence.self,
            forKey: .modelConversion
        )
        exitStatus = try container.decode(Int32.self, forKey: .exitStatus)
        succeeded = try container.decode(Bool.self, forKey: .succeeded)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(command, forKey: .command)
        if let mappingAttemptOrdinal {
            try container.encode(mappingAttemptOrdinal, forKey: .mappingAttemptOrdinal)
        } else {
            try container.encodeNil(forKey: .mappingAttemptOrdinal)
        }
        try container.encode(threadPolicy, forKey: .threadPolicy)
        if let argvWorkerCount {
            try container.encode(argvWorkerCount, forKey: .argvWorkerCount)
        } else {
            try container.encodeNil(forKey: .argvWorkerCount)
        }
        try container.encode(explicitThreadEnvironment, forKey: .explicitThreadEnvironment)
        try container.encode(
            removedThreadEnvironmentKeysSHA256,
            forKey: .removedThreadEnvironmentKeysSHA256
        )
        try container.encode(
            effectiveSanitizedThreadEnvironment,
            forKey: .effectiveSanitizedThreadEnvironment
        )
        if let pairExecution {
            try container.encode(pairExecution, forKey: .pairExecution)
        } else {
            try container.encodeNil(forKey: .pairExecution)
        }
        if let mapperExecution {
            try container.encode(mapperExecution, forKey: .mapperExecution)
        } else {
            try container.encodeNil(forKey: .mapperExecution)
        }
        if let modelConversion {
            try container.encode(modelConversion, forKey: .modelConversion)
        } else {
            try container.encodeNil(forKey: .modelConversion)
        }
        try container.encode(exitStatus, forKey: .exitStatus)
        try container.encode(succeeded, forKey: .succeeded)
    }
}

public struct VideoSourceAnalysisExecutionEvidence: Codable, Sendable, Equatable {
    public var videoSourceCount: Int
    public var startedAnalysisTaskCount: Int
    public var peakInFlightAnalysisTaskCount: Int

    public init(
        videoSourceCount: Int,
        startedAnalysisTaskCount: Int,
        peakInFlightAnalysisTaskCount: Int
    ) {
        self.videoSourceCount = videoSourceCount
        self.startedAnalysisTaskCount = startedAnalysisTaskCount
        self.peakInFlightAnalysisTaskCount = peakInFlightAnalysisTaskCount
    }
}

struct RejectedVocabularyRetrievalExecutionEvidence: Codable, Sendable, Equatable {
    var retrievalAttemptOrdinal: Int
    var pairingPolicy: ResolvedPairingPolicy
    var planBinding: PairGraphPlanBinding
    var recoveryLevel: PairGraphRecoveryLevel
    var imageNames: [String]
    var groups: [ColmapPairGroup]
    var invocation: ColmapWorkerInvocationEvidence
    var retrieval: PairGraphRetrievalAttemptEvidence
    var durationSeconds: Double
}

/// The accepted geometry contract that worker evidence must prove before publication.
/// This context is derived from the persisted mapping, pair graph, and normalized input;
/// callers cannot substitute backend labels or loosely related booleans.
public struct GeometryWorkerExecutionPublicationContext: Sendable, Equatable {
    public let acceptedMappingAttemptOrdinal: Int
    public let refinementKind: MappingRefinementKind
    public let acceptedRefinementInvocationCount: Int
    public let plannedIncrementalCadence: IncrementalMappingCadenceArtifact?
    public let acceptedIncrementalCadence: IncrementalMappingCadenceArtifact?
    public let cadenceFallbackTrigger: MappingCadenceFallbackTrigger?
    public let pairGraphStatus: PairGraphMeasurementStatus
    public let acceptedPairGraphAttemptNumber: Int?
    public let pairGraphMatcherAttempts: [PairMatchingAttemptArtifact]
    public let acceptedPairListDigest: String?
    public let acceptedDescriptorMatcher: DescriptorMatcher?
    public let acceptedMatchingDatabaseDigest: String?
    public let retrievalWasScheduled: Bool
    public let usedLocalVocabularyRetrieval: Bool
    public let expectedVideoSourceCount: Int
    public let canonicalModelPublication: CanonicalModelPublicationArtifact

    public init(
        mapping: MappingArtifact,
        pairGraph: PairGraphArtifact,
        input: InputSpec
    ) {
        self.init(
            mapping: mapping,
            pairGraph: pairGraph,
            expectedVideoSourceCount: input.videoFiles.count
        )
    }

    init(
        mapping: MappingArtifact,
        pairGraph: PairGraphArtifact,
        expectedVideoSourceCount: Int
    ) {
        acceptedMappingAttemptOrdinal = mapping.acceptedMappingAttemptOrdinal
        refinementKind = mapping.acceptedRefinementKind
        acceptedRefinementInvocationCount = mapping.acceptedRefinementInvocationCount
        plannedIncrementalCadence = mapping.plannedIncrementalCadence
        acceptedIncrementalCadence = mapping.incrementalCadence
        cadenceFallbackTrigger = mapping.cadenceFallbackTrigger
        pairGraphStatus = pairGraph.status
        acceptedPairGraphAttemptNumber = pairGraph.measurement?
            .matcherAttempts.last?.attemptNumber
        pairGraphMatcherAttempts = pairGraph.measurement?.matcherAttempts ?? []
        acceptedPairListDigest = pairGraph.measurement?.pairListDigest
        acceptedDescriptorMatcher = pairGraph.measurement?.matcherAttempts.last?.matcher
        acceptedMatchingDatabaseDigest = pairGraph.measurement?.matchingDatabaseDigest
        retrievalWasScheduled = pairGraph.retrievalWasScheduled
        usedLocalVocabularyRetrieval = pairGraph.usedLocalVocabularyRetrieval
        canonicalModelPublication = mapping.canonicalModelPublication
        self.expectedVideoSourceCount = expectedVideoSourceCount
    }
}

public enum GeometryWorkerExecutionArtifactError: Error, LocalizedError, Equatable {
    case invalidCommandForStage
    case incompleteStage
    case invalidExitStatus
    case invalidInvocationCount
    case invalidMappingAttemptOrdinal
    case invalidLocation
    case invalidRuntimeClosure
    case invalidSanitizerDigest
    case invalidSchema(Int)
    case invalidThreadEnvironment
    case invalidThreadPolicy
    case invalidVideoSourceAnalysis
    case workerBudgetMismatch

    public var errorDescription: String? {
        switch self {
        case .invalidCommandForStage:
            return "Worker evidence assigned a COLMAP command to the wrong stage."
        case .incompleteStage:
            return "Worker evidence does not prove every process required by the published geometry."
        case .invalidExitStatus:
            return "Worker evidence contains an invalid process exit status."
        case .invalidInvocationCount:
            return "Worker evidence contains too many process invocations."
        case .invalidMappingAttemptOrdinal:
            return "Worker evidence contains an invalid mapping-attempt ordinal."
        case .invalidLocation:
            return "Worker evidence must stay at its canonical project path."
        case .invalidRuntimeClosure:
            return "Worker evidence does not bind the required COLMAP runtime closure."
        case .invalidSanitizerDigest:
            return "Worker evidence does not identify the current environment sanitizer."
        case .invalidSchema(let schema):
            return "Unsupported worker-evidence schema: \(schema)."
        case .invalidThreadEnvironment:
            return "Worker evidence contains an invalid thread environment."
        case .invalidThreadPolicy:
            return "Worker evidence contains an invalid thread policy."
        case .invalidVideoSourceAnalysis:
            return "Worker evidence contains invalid video-source analysis measurements."
        case .workerBudgetMismatch:
            return "Worker evidence does not match the resolved run budget."
        }
    }
}

public struct GeometryWorkerExecutionArtifact: Codable, Sendable, Equatable {
    public static let currentSchemaVersion = 13
    public static let maximumInvocationsPerStage = 4_096
    public static let canonicalRemovedThreadEnvironmentKeys = [
        "BLIS_NUM_THREADS",
        "GOMP_CPU_AFFINITY",
        "GOMP_SPINCOUNT",
        "GOMP_STACKSIZE",
        "GOTO_NUM_THREADS",
        "KMP_AFFINITY",
        "KMP_ALL_THREADS",
        "KMP_BLOCKTIME",
        "KMP_DETERMINISTIC_REDUCTION",
        "KMP_DEVICE_THREAD_LIMIT",
        "KMP_HW_SUBSET",
        "KMP_LIBRARY",
        "KMP_PLACE_THREADS",
        "KMP_SETTINGS",
        "KMP_STACKSIZE",
        "KMP_TEAMS_THREAD_LIMIT",
        "MKL_DOMAIN_NUM_THREADS",
        "MKL_DYNAMIC",
        "MKL_NUM_THREADS",
        "OMP_DYNAMIC",
        "OMP_MAX_ACTIVE_LEVELS",
        "OMP_NESTED",
        "OMP_NUM_THREADS",
        "OMP_PLACES",
        "OMP_PROC_BIND",
        "OMP_SCHEDULE",
        "OMP_STACKSIZE",
        "OMP_THREAD_LIMIT",
        "OMP_WAIT_POLICY",
        "OPENBLAS_NUM_THREADS",
        "VECLIB_MAXIMUM_THREADS",
    ]
    public static let canonicalRemovedThreadEnvironmentKeysSHA256: String = {
        let canonicalJSON = "[\""
            + canonicalRemovedThreadEnvironmentKeys.joined(separator: "\",\"")
            + "\"]"
        let digest = SHA256.hash(data: Data(canonicalJSON.utf8))
        return "sha256:" + digest.map { String(format: "%02x", $0) }.joined()
    }()

    public var schemaVersion: Int
    public var colmapRuntimeClosure: ColmapRuntimeClosureEvidence
    public var resolvedBudget: GeometryWorkerBudget
    public var featureExtractionInvocations: [ColmapWorkerInvocationEvidence]
    public var matchingInvocations: [ColmapWorkerInvocationEvidence]
    public var vocabularyRetrievalInvocations: [ColmapWorkerInvocationEvidence]
    var rejectedVocabularyRetrievalInvocations: [
        RejectedVocabularyRetrievalExecutionEvidence
    ]
    public var mappingAndRefinementInvocations: [ColmapWorkerInvocationEvidence]
    public var videoSourceAnalysis: VideoSourceAnalysisExecutionEvidence

    public init(
        colmapRuntimeClosure: ColmapRuntimeClosureEvidence,
        resolvedBudget: GeometryWorkerBudget,
        featureExtractionInvocations: [ColmapWorkerInvocationEvidence],
        matchingInvocations: [ColmapWorkerInvocationEvidence],
        vocabularyRetrievalInvocations: [ColmapWorkerInvocationEvidence],
        mappingAndRefinementInvocations: [ColmapWorkerInvocationEvidence],
        videoSourceAnalysis: VideoSourceAnalysisExecutionEvidence
    ) {
        schemaVersion = Self.currentSchemaVersion
        self.colmapRuntimeClosure = colmapRuntimeClosure
        self.resolvedBudget = resolvedBudget
        self.featureExtractionInvocations = featureExtractionInvocations
        self.matchingInvocations = matchingInvocations
        self.vocabularyRetrievalInvocations = vocabularyRetrievalInvocations
        rejectedVocabularyRetrievalInvocations = []
        self.mappingAndRefinementInvocations = mappingAndRefinementInvocations
        self.videoSourceAnalysis = videoSourceAnalysis
    }

    public func validate(expectedBudget: GeometryWorkerBudget) throws {
        guard schemaVersion == Self.currentSchemaVersion else {
            throw GeometryWorkerExecutionArtifactError.invalidSchema(schemaVersion)
        }
        guard colmapRuntimeClosure.isValid else {
            throw GeometryWorkerExecutionArtifactError.invalidRuntimeClosure
        }
        guard resolvedBudget == expectedBudget,
              [
                  expectedBudget.featureExtractionWorkers,
                  expectedBudget.coupledMatchingWorkers,
                  expectedBudget.vocabularyRetrievalWorkers,
                  expectedBudget.maximumConcurrentVideoSourceAnalysisTasks,
              ].allSatisfy({ (1...64).contains($0) }) else {
            throw GeometryWorkerExecutionArtifactError.workerBudgetMismatch
        }
        try Self.validateInvocations(
            featureExtractionInvocations,
            allowedCommands: [.featureExtractor, .featureImporter],
            expectedPolicy: .bounded,
            expectedWorkerCount: expectedBudget.featureExtractionWorkers,
            expectsMappingAttemptOrdinal: false
        )
        try Self.validateInvocations(
            matchingInvocations,
            allowedCommands: [.matchesImporter],
            expectedPolicy: .bounded,
            expectedWorkerCount: expectedBudget.coupledMatchingWorkers,
            expectsMappingAttemptOrdinal: false
        )
        try Self.validateInvocations(
            vocabularyRetrievalInvocations,
            allowedCommands: [.localVocabularyRetriever],
            expectedPolicy: .bounded,
            expectedWorkerCount: expectedBudget.vocabularyRetrievalWorkers,
            expectsMappingAttemptOrdinal: false
        )
        try Self.validateRejectedVocabularyRetrievalHistory(
            rejectedVocabularyRetrievalInvocations,
            expectedWorkerCount: expectedBudget.vocabularyRetrievalWorkers,
            acceptedInvocations: vocabularyRetrievalInvocations
        )
        try Self.validateInvocations(
            mappingAndRefinementInvocations,
            allowedCommands: [
                .mapper,
                .pointTriangulator,
                .bundleAdjuster,
                .modelAnalyzer,
                .modelConverter,
            ],
            expectedPolicy: .nativeAuto,
            expectedWorkerCount: nil,
            expectsMappingAttemptOrdinal: true
        )
        try Self.validatePairExecutionBindings(self)
        try Self.validateMapperExecutionBindings(self)
        try Self.validateModelConversionBindings(self)
        try validateVideoSourceAnalysis(expectedBudget: expectedBudget)
    }

    private static func validatePairExecutionBindings(
        _ artifact: GeometryWorkerExecutionArtifact
    ) throws {
        for invocation in artifact.featureExtractionInvocations
            + artifact.mappingAndRefinementInvocations {
            guard invocation.pairExecution == nil else {
                throw GeometryWorkerExecutionArtifactError.invalidCommandForStage
            }
        }
        for invocation in artifact.matchingInvocations {
            guard let binding = invocation.pairExecution else { continue }
            guard
                  binding.attemptOrdinal > 0,
                  binding.scheduledPairCount.map({ $0 > 0 }) == true,
                  binding.pairListDigest.map(Self.isSHA256) == true,
                  (binding.descriptorMatcher == .exact)
                    == (binding.exactRecoveryReason != nil),
                  (binding.retrievalRequestDigest == nil)
                    == (binding.retrievalOutputDigest == nil),
                  binding.retrievalRequestDigest.map(Self.isSHA256) ?? true,
                  binding.retrievalOutputDigest.map(Self.isSHA256) ?? true else {
                throw GeometryWorkerExecutionArtifactError.incompleteStage
            }
        }
        for invocation in artifact.vocabularyRetrievalInvocations {
            guard let binding = invocation.pairExecution else { continue }
            guard
                  binding.attemptOrdinal > 0,
                  binding.scheduledPairCount == nil,
                  binding.pairListDigest == nil,
                  binding.exactRecoveryReason == nil,
                  binding.retrievalRequestDigest.map(Self.isSHA256) == true,
                  (!invocation.succeeded
                    || binding.retrievalOutputDigest.map(Self.isSHA256) == true) else {
                throw GeometryWorkerExecutionArtifactError.incompleteStage
            }
        }
    }

    private static func validateMapperExecutionBindings(
        _ artifact: GeometryWorkerExecutionArtifact
    ) throws {
        let invocations = artifact.featureExtractionInvocations
            + artifact.matchingInvocations
            + artifact.vocabularyRetrievalInvocations
            + artifact.mappingAndRefinementInvocations
        for invocation in invocations {
            guard invocation.command == .mapper else {
                guard invocation.mapperExecution == nil else {
                    throw GeometryWorkerExecutionArtifactError.invalidCommandForStage
                }
                continue
            }
            guard let mapper = invocation.mapperExecution else {
                throw GeometryWorkerExecutionArtifactError.incompleteStage
            }
            guard IncrementalMappingCadencePolicy.isRecognized(
                mapper.incrementalCadence
            ), mapper.incrementalCadence.isValid else {
                throw GeometryWorkerExecutionArtifactError.incompleteStage
            }
            guard mapper.globalMaxNumIterations > 0,
                  mapper.randomSeed >= 0,
                  mapper.refineFocalLength,
                  mapper.minimumPairInlierCount
                    == ColmapMappingPolicy.minimumPairInlierCount else {
                throw GeometryWorkerExecutionArtifactError.incompleteStage
            }
            guard mapper.pairGraphAttemptOrdinal > 0,
                  isSHA256(mapper.pairListDigest),
                  isSHA256(mapper.matchingDatabaseDigest) else {
                throw GeometryWorkerExecutionArtifactError.incompleteStage
            }
            guard mapper.evaluation.map(\.isValid) ?? true,
                  invocation.succeeded || mapper.evaluation == nil else {
                throw GeometryWorkerExecutionArtifactError.incompleteStage
            }
        }
    }

    static func validateRejectedVocabularyRetrievalHistory(
        _ entries: [RejectedVocabularyRetrievalExecutionEvidence],
        expectedWorkerCount: Int?,
        acceptedInvocations: [ColmapWorkerInvocationEvidence] = []
    ) throws {
        guard entries.count <= 3 else {
            throw GeometryWorkerExecutionArtifactError.invalidInvocationCount
        }
        if let expectedWorkerCount {
            try validateInvocations(
                entries.map(\.invocation),
                allowedCommands: [.localVocabularyRetriever],
                expectedPolicy: .bounded,
                expectedWorkerCount: expectedWorkerCount,
                expectsMappingAttemptOrdinal: false
            )
        }

        let acceptedDigestPairs = Set(acceptedInvocations.compactMap {
            retrievalDigestPair(for: $0)
        })
        var priorRecoveryIndex = -1
        var priorPairAttemptOrdinal = 0
        var boundPairingPolicy: ResolvedPairingPolicy?
        var boundPlanBinding: PairGraphPlanBinding?
        var boundImageNames: [String]?
        var boundGroups: [ColmapPairGroup]?
        for (index, entry) in entries.enumerated() {
            let levelIndex = recoveryIndex(entry.recoveryLevel)
            let expectedQueryNames = try? PipelineRunner.vocabularyRetrievalQueryImageNames(
                imageNames: entry.imageNames,
                groups: entry.groups,
                queryStride: entry.retrieval.queryStride,
                requiresCrossClipRetrieval: entry.planBinding.requiresCrossClipRetrieval
            )
            guard entry.retrievalAttemptOrdinal == index + 1,
                  levelIndex > priorRecoveryIndex,
                  entry.durationSeconds.isFinite,
                  entry.durationSeconds >= 0,
                  boundPairingPolicy.map({ $0 == entry.pairingPolicy }) ?? true,
                  boundPlanBinding.map({ $0 == entry.planBinding }) ?? true,
                  entry.planBinding.pairingPolicy == entry.pairingPolicy,
                  entry.planBinding.isStructurallyValid,
                  boundImageNames.map({ $0 == entry.imageNames }) ?? true,
                  boundGroups.map({ $0 == entry.groups }) ?? true,
                  PairGraphEvidenceStore.retrievalIsRequired(
                    pairingPolicy: entry.pairingPolicy,
                    imageCount: entry.imageNames.count,
                    recoveryLevel: entry.recoveryLevel,
                    requiresCrossClipRetrieval:
                        entry.planBinding.requiresCrossClipRetrieval
                  ),
                  expectedQueryNames == entry.retrieval.queryImageNames,
                  rejectedRetrievalMatchesPlan(entry),
                  entry.invocation.command == .localVocabularyRetriever,
                  entry.invocation.succeeded,
                  entry.invocation.exitStatus == 0,
                  entry.invocation.modelConversion == nil,
                  let binding = entry.invocation.pairExecution,
                  binding.attemptOrdinal > 0,
                  binding.attemptOrdinal >= priorPairAttemptOrdinal,
                  binding.descriptorMatcher == .faiss,
                  binding.pairListDigest == nil,
                  binding.retrievalRequestDigest
                    == PairGraphEvidenceStore.retrievalRequestDigest(entry.retrieval),
                  binding.retrievalOutputDigest == entry.retrieval.outputDigest,
                  let digestPair = retrievalDigestPair(for: entry.invocation),
                  !acceptedDigestPairs.contains(digestPair) else {
                throw GeometryWorkerExecutionArtifactError.incompleteStage
            }
            do {
                try PairGraphEvidenceStore.validateRetrievalContractEvidence(
                    entry.retrieval,
                    imageNames: entry.imageNames
                )
            } catch {
                throw GeometryWorkerExecutionArtifactError.incompleteStage
            }
            boundPairingPolicy = entry.pairingPolicy
            boundPlanBinding = entry.planBinding
            boundImageNames = entry.imageNames
            boundGroups = entry.groups
            priorRecoveryIndex = levelIndex
            priorPairAttemptOrdinal = binding.attemptOrdinal
        }
    }

    private struct RetrievalDigestPair: Hashable {
        let request: String
        let output: String
    }

    private static func retrievalDigestPair(
        for invocation: ColmapWorkerInvocationEvidence
    ) -> RetrievalDigestPair? {
        guard invocation.succeeded,
              let binding = invocation.pairExecution,
              let request = binding.retrievalRequestDigest,
              let output = binding.retrievalOutputDigest else {
            return nil
        }
        return RetrievalDigestPair(request: request, output: output)
    }

    private static func recoveryIndex(_ level: PairGraphRecoveryLevel) -> Int {
        switch level {
        case .normal: 0
        case .expanded: 1
        case .maximum: 2
        }
    }

    private static func rejectedRetrievalMatchesPlan(
        _ entry: RejectedVocabularyRetrievalExecutionEvidence
    ) -> Bool {
        let expectedCandidateCount: Int
        let expectedNeighborCount: Int
        switch entry.recoveryLevel {
        case .normal:
            expectedCandidateCount = entry.planBinding.retrievalCandidateCount
            expectedNeighborCount = entry.planBinding.retrievalNeighborCount
        case .expanded:
            switch entry.pairingPolicy {
            case .segmentedMixed, .unorderedRetrieval:
                expectedCandidateCount = 40
                expectedNeighborCount = 16
            case .orderedContinuous, .orderedOrbit, .orderedWalkthrough,
                 .orderedLargeArea:
                expectedCandidateCount = entry.planBinding.retrievalCandidateCount
                expectedNeighborCount = entry.planBinding.retrievalNeighborCount
            }
        case .maximum:
            expectedCandidateCount = 80
            expectedNeighborCount = 32
        }
        let expectedMinimumSeparation: Int
        switch (entry.planBinding.requiresCrossClipRetrieval, entry.pairingPolicy) {
        case (true, _):
            expectedMinimumSeparation = 0
        case (false, .orderedContinuous), (false, .orderedOrbit),
             (false, .orderedWalkthrough), (false, .orderedLargeArea):
            expectedMinimumSeparation = max(12, entry.imageNames.count / 10)
        case (false, .segmentedMixed), (false, .unorderedRetrieval):
            expectedMinimumSeparation = 0
        }
        guard entry.retrieval.engine == entry.planBinding.retrievalEngine
            && entry.retrieval.queryStride == entry.planBinding.retrievalQueryStride
            && entry.retrieval.candidateCount == expectedCandidateCount
            && entry.retrieval.returnedNeighborCount == expectedNeighborCount
            && entry.retrieval.minimumFrameSeparation == expectedMinimumSeparation else {
            return false
        }
        do {
            let recoveryLevel = PipelineRunner.PairRecoveryLevel(
                entry.recoveryLevel
            )
            let basePlan = try PipelineRunner.baseColmapPairPlan(
                imageNames: entry.imageNames,
                groups: entry.groups,
                planBinding: entry.planBinding,
                recoveryLevel: recoveryLevel
            )
            let request = PipelineRunner.VocabularyRetrievalRequest(
                queryImageNames: entry.retrieval.queryImageNames,
                candidateCount: expectedCandidateCount,
                returnedNeighborCount: expectedNeighborCount,
                minimumFrameSeparation: expectedMinimumSeparation,
                imageGroupContract: try PipelineRunner
                    .vocabularyRetrievalImageGroupContract(
                        imageNames: entry.imageNames,
                        groups: entry.groups,
                        requiresCrossClipRetrieval:
                            entry.planBinding.requiresCrossClipRetrieval
                    )
            )
            let pairLines = try PipelineRunner.validatedVocabularyRetrievalEvidence(
                entry.retrieval,
                request: request,
                imageNames: entry.imageNames,
                excluding: basePlan
            )
            let mergedPlan = try basePlan.addingRetrievalPairLines(
                pairLines,
                pairingPolicy: entry.pairingPolicy,
                groups: entry.groups,
                requiresCrossClipRetrieval:
                    entry.planBinding.requiresCrossClipRetrieval
            )
            return !mergedPlan.isConnected
        } catch {
            return false
        }
    }

    private static func validateModelConversionBindings(
        _ artifact: GeometryWorkerExecutionArtifact
    ) throws {
        let invocations = artifact.featureExtractionInvocations
            + artifact.matchingInvocations
            + artifact.vocabularyRetrievalInvocations
            + artifact.mappingAndRefinementInvocations
        for invocation in invocations {
            guard invocation.command == .modelConverter else {
                guard invocation.modelConversion == nil else {
                    throw GeometryWorkerExecutionArtifactError.invalidCommandForStage
                }
                continue
            }
            guard let conversion = invocation.modelConversion,
                  conversion.executableComponentPath == "bin/colmap",
                  isSHA256(conversion.executableSHA256),
                  conversion.executableSHA256
                    == artifact.colmapRuntimeClosure.sha256(for: "bin/colmap"),
                  isProjectRelativePath(conversion.candidateProjectRelativePath),
                  isProjectRelativePath(conversion.inputProjectRelativePath),
                  isProjectRelativePath(conversion.outputProjectRelativePath),
                  conversion.inputProjectRelativePath
                    != conversion.outputProjectRelativePath,
                  isSHA256(conversion.sourceModelDigest),
                  isSHA256(conversion.candidateIdentitySHA256),
                  invocation.succeeded
                    == (conversion.convertedModelDigest.map(isSHA256) == true) else {
                throw GeometryWorkerExecutionArtifactError.incompleteStage
            }
        }
    }

    private static func isProjectRelativePath(_ value: String) -> Bool {
        guard !value.isEmpty,
              value.utf8.count <= 4_096,
              !value.hasPrefix("/"),
              !value.contains("\\"),
              value.unicodeScalars.allSatisfy({
                  !CharacterSet.controlCharacters.contains($0)
              }) else {
            return false
        }
        return value.split(separator: "/", omittingEmptySubsequences: false)
            .allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    }

    private static func isSHA256(_ value: String) -> Bool {
        value.count == 64 && value.unicodeScalars.allSatisfy {
            ($0.value >= 48 && $0.value <= 57) || ($0.value >= 97 && $0.value <= 102)
        }
    }

    public func validateForPublishedGeometry(
        expectedBudget: GeometryWorkerBudget,
        context: GeometryWorkerExecutionPublicationContext
    ) throws {
        try validate(expectedBudget: expectedBudget)

        guard videoSourceAnalysis.videoSourceCount == context.expectedVideoSourceCount else {
            throw GeometryWorkerExecutionArtifactError.invalidVideoSourceAnalysis
        }
        guard context.acceptedMappingAttemptOrdinal > 0,
              context.acceptedMappingAttemptOrdinal
                == mappingAndRefinementInvocations.compactMap(\.mappingAttemptOrdinal).max() else {
            throw GeometryWorkerExecutionArtifactError.incompleteStage
        }

        let acceptedInvocations = mappingAndRefinementInvocations.filter {
            $0.mappingAttemptOrdinal == context.acceptedMappingAttemptOrdinal
        }
        let acceptedCommands = Set(acceptedInvocations.map(\.command))
        func successfulCount(_ command: ColmapWorkerCommandIdentity) -> Int {
            acceptedInvocations.count { $0.command == command && $0.succeeded }
        }
        let converterInvocations = acceptedInvocations.filter {
            $0.command == .modelConverter
        }
        switch context.canonicalModelPublication.kind {
        case .convertedFromBinary:
            guard let conversion = context.canonicalModelPublication.conversion,
                  conversion.invocationOrdinal > 0,
                  conversion.invocationOrdinal <= converterInvocations.count,
                  converterInvocations[conversion.invocationOrdinal - 1].succeeded,
                  converterInvocations[conversion.invocationOrdinal - 1]
                    .modelConversion == conversion.workerEvidence else {
                throw GeometryWorkerExecutionArtifactError.incompleteStage
            }
        case .directText, .resumedCanonicalText:
            guard context.canonicalModelPublication.conversion == nil else {
                throw GeometryWorkerExecutionArtifactError.incompleteStage
            }
        }

        try Self.validatePublishedMapperHistory(
            mappingAndRefinementInvocations,
            matchingInvocations: matchingInvocations,
            context: context
        )

        switch context.refinementKind {
        case .incrementalGlobal:
            let mapperInvocations = acceptedInvocations.filter { $0.command == .mapper }
            guard acceptedCommands.isSubset(of: [.mapper, .modelAnalyzer, .modelConverter]),
                  mapperInvocations.count == 1,
                  mapperInvocations[0].succeeded,
                  successfulCount(.modelAnalyzer) >= 1,
                  context.acceptedRefinementInvocationCount >= 0 else {
                throw GeometryWorkerExecutionArtifactError.incompleteStage
            }
        case .seededBundleAdjustment:
            let triangulationInvocations = acceptedInvocations.filter {
                $0.command == .pointTriangulator
            }
            let adjustmentInvocations = acceptedInvocations.filter {
                $0.command == .bundleAdjuster
            }
            guard acceptedCommands.isSubset(
                of: [.pointTriangulator, .bundleAdjuster, .modelAnalyzer, .modelConverter]
            ),
                  context.acceptedRefinementInvocationCount == 1,
                  featureExtractionInvocations.contains(where: \.succeeded),
                  matchingInvocations.contains(where: \.succeeded),
                  triangulationInvocations.count == 1,
                  triangulationInvocations[0].succeeded,
                  adjustmentInvocations.count == 1,
                  adjustmentInvocations[0].succeeded,
                  successfulCount(.modelAnalyzer) >= 1 else {
                throw GeometryWorkerExecutionArtifactError.incompleteStage
            }
        }

        if context.pairGraphStatus == .measured {
            guard let acceptedPairGraphAttemptNumber =
                    context.acceptedPairGraphAttemptNumber,
                  context.pairGraphMatcherAttempts.count
                    == matchingInvocations.count,
                  !context.pairGraphMatcherAttempts.isEmpty,
                  let acceptedMatcherInvocation = matchingInvocations.last(where: {
                      $0.succeeded
                          && $0.pairExecution?.attemptOrdinal
                            == acceptedPairGraphAttemptNumber
                  }),
                  featureExtractionInvocations.contains(where: \.succeeded) else {
                throw GeometryWorkerExecutionArtifactError.incompleteStage
            }
            for (attempt, invocation) in zip(
                context.pairGraphMatcherAttempts,
                matchingInvocations
            ) {
                guard let binding = invocation.pairExecution,
                      binding.attemptOrdinal == attempt.attemptNumber,
                      binding.descriptorMatcher == attempt.matcher,
                      binding.scheduledPairCount == attempt.scheduledPairCount,
                      binding.exactRecoveryReason == attempt.exactRecoveryReason,
                      attempt.outcome == .failed || invocation.succeeded else {
                    throw GeometryWorkerExecutionArtifactError.incompleteStage
                }
            }
            for index in context.pairGraphMatcherAttempts.indices where
                context.pairGraphMatcherAttempts[index].matcher == .exact {
                guard index > 0,
                      let reason = context.pairGraphMatcherAttempts[index]
                        .exactRecoveryReason else {
                    throw GeometryWorkerExecutionArtifactError.incompleteStage
                }
                switch reason {
                case .faissCrash, .faissUnsupportedOperation:
                    guard !matchingInvocations[index - 1].succeeded else {
                        throw GeometryWorkerExecutionArtifactError.incompleteStage
                    }
                case .faissGeometryRejectedAfterRetries:
                    guard matchingInvocations[index - 1].succeeded else {
                        throw GeometryWorkerExecutionArtifactError.incompleteStage
                    }
                }
            }
            guard acceptedMatcherInvocation.pairExecution?.pairListDigest
                    == context.acceptedPairListDigest else {
                throw GeometryWorkerExecutionArtifactError.incompleteStage
            }
            if context.retrievalWasScheduled {
                guard let binding = acceptedMatcherInvocation.pairExecution,
                      (binding.retrievalRequestDigest == nil)
                        == (binding.retrievalOutputDigest == nil) else {
                    throw GeometryWorkerExecutionArtifactError.incompleteStage
                }
                let acceptedAttemptUsesVocabularyReceipt =
                    binding.retrievalRequestDigest != nil
                guard context.usedLocalVocabularyRetrieval
                        == acceptedAttemptUsesVocabularyReceipt else {
                    throw GeometryWorkerExecutionArtifactError.incompleteStage
                }
                if let requestDigest = binding.retrievalRequestDigest,
                   let outputDigest = binding.retrievalOutputDigest {
                    guard vocabularyRetrievalInvocations.contains(where: { invocation in
                        invocation.succeeded
                            && invocation.pairExecution?.retrievalRequestDigest
                                == requestDigest
                            && invocation.pairExecution?.retrievalOutputDigest
                                == outputDigest
                    }) else {
                        throw GeometryWorkerExecutionArtifactError.incompleteStage
                    }
                }
            } else {
                guard !context.usedLocalVocabularyRetrieval,
                      vocabularyRetrievalInvocations.isEmpty else {
                    throw GeometryWorkerExecutionArtifactError.incompleteStage
                }
            }
        } else {
            guard context.acceptedPairGraphAttemptNumber == nil else {
                throw GeometryWorkerExecutionArtifactError.incompleteStage
            }
        }
        if context.pairGraphStatus == .notEvaluated {
            guard !context.retrievalWasScheduled,
                  !context.usedLocalVocabularyRetrieval,
                  vocabularyRetrievalInvocations.isEmpty,
                  context.pairGraphMatcherAttempts.isEmpty,
                  context.acceptedPairListDigest == nil else {
                throw GeometryWorkerExecutionArtifactError.incompleteStage
            }
            try Self.validateUnmeasuredMatchingHistory(matchingInvocations)
        }
        guard !context.usedLocalVocabularyRetrieval
                || context.retrievalWasScheduled else {
            throw GeometryWorkerExecutionArtifactError.incompleteStage
        }

        let requiredStages = [
            featureExtractionInvocations,
            matchingInvocations,
            mappingAndRefinementInvocations,
        ]
        guard requiredStages.allSatisfy({ invocations in
            invocations.isEmpty || invocations.contains(where: \.succeeded)
        }) else {
            throw GeometryWorkerExecutionArtifactError.incompleteStage
        }
    }

    private static func validatePublishedMapperHistory(
        _ mappingInvocations: [ColmapWorkerInvocationEvidence],
        matchingInvocations: [ColmapWorkerInvocationEvidence],
        context: GeometryWorkerExecutionPublicationContext
    ) throws {
        let mapperInvocations = mappingInvocations.filter { $0.command == .mapper }
        switch context.refinementKind {
        case .seededBundleAdjustment:
            guard context.plannedIncrementalCadence == nil,
                  context.acceptedIncrementalCadence == nil,
                  context.cadenceFallbackTrigger == nil,
                  !mapperInvocations.contains(where: {
                      $0.mapperExecution?.evaluation?.status == .accepted
                  }) else {
                throw GeometryWorkerExecutionArtifactError.incompleteStage
            }
            return
        case .incrementalGlobal:
            break
        }

        guard let plannedCadence = context.plannedIncrementalCadence,
              let acceptedCadence = context.acceptedIncrementalCadence,
              IncrementalMappingCadencePolicy.validates(
                planned: plannedCadence,
                accepted: acceptedCadence,
                trigger: context.cadenceFallbackTrigger
              ),
              !mapperInvocations.isEmpty else {
            throw GeometryWorkerExecutionArtifactError.incompleteStage
        }

        for invocation in mapperInvocations where invocation.succeeded {
            guard invocation.mapperExecution?.evaluation != nil else {
                throw GeometryWorkerExecutionArtifactError.incompleteStage
            }
        }
        let acceptedMappers = mapperInvocations.filter {
            $0.succeeded
                && $0.mapperExecution?.evaluation?.status == .accepted
        }
        guard acceptedMappers.count == 1,
              let acceptedMapper = acceptedMappers.first,
              acceptedMapper == mapperInvocations.last,
              acceptedMapper.mappingAttemptOrdinal
                == context.acceptedMappingAttemptOrdinal,
              let acceptedExecution = acceptedMapper.mapperExecution,
              acceptedExecution.incrementalCadence == acceptedCadence,
              acceptedExecution.evaluation?.fallbackTrigger == nil,
              acceptedExecution.pairGraphAttemptOrdinal
                == context.acceptedPairGraphAttemptNumber,
              acceptedExecution.pairListDigest == context.acceptedPairListDigest,
              acceptedExecution.descriptorMatcher
                == context.acceptedDescriptorMatcher,
              acceptedExecution.matchingDatabaseDigest
                == context.acceptedMatchingDatabaseDigest,
              matchingInvocations.contains(where: { invocation in
                  invocation.succeeded
                      && invocation.pairExecution?.attemptOrdinal
                        == acceptedExecution.pairGraphAttemptOrdinal
                      && invocation.pairExecution?.descriptorMatcher
                        == acceptedExecution.descriptorMatcher
                      && invocation.pairExecution?.pairListDigest
                        == acceptedExecution.pairListDigest
              }) else {
            throw GeometryWorkerExecutionArtifactError.incompleteStage
        }

        let executions = try mapperInvocations.map { invocation in
            guard let execution = invocation.mapperExecution else {
                throw GeometryWorkerExecutionArtifactError.incompleteStage
            }
            return execution
        }
        let transitions = executions.indices.dropFirst().filter { index in
            executions[index - 1].incrementalCadence
                != executions[index].incrementalCadence
        }
        if plannedCadence == acceptedCadence {
            guard transitions.isEmpty,
                  context.cadenceFallbackTrigger == nil else {
                throw GeometryWorkerExecutionArtifactError.incompleteStage
            }
            return
        }

        guard transitions.count == 1,
              let transitionIndex = transitions.first,
              let trigger = context.cadenceFallbackTrigger,
              executions[transitionIndex - 1].incrementalCadence == plannedCadence,
              executions[transitionIndex].incrementalCadence == acceptedCadence,
              mapperInvocations[transitionIndex - 1].succeeded,
              executions[transitionIndex - 1].evaluation?.status == .rejected,
              executions[transitionIndex - 1].evaluation?.fallbackTrigger == trigger,
              executions[transitionIndex - 1].pairGraphAttemptOrdinal
                == executions[transitionIndex].pairGraphAttemptOrdinal,
              executions[transitionIndex - 1].pairListDigest
                == executions[transitionIndex].pairListDigest,
              executions[transitionIndex - 1].descriptorMatcher
                == executions[transitionIndex].descriptorMatcher,
              executions[transitionIndex - 1].matchingDatabaseDigest
                == executions[transitionIndex].matchingDatabaseDigest else {
            throw GeometryWorkerExecutionArtifactError.incompleteStage
        }
    }

    private static func validateUnmeasuredMatchingHistory(
        _ invocations: [ColmapWorkerInvocationEvidence]
    ) throws {
        guard (1...2).contains(invocations.count),
              let first = invocations.first,
              let firstBinding = first.pairExecution,
              firstBinding.attemptOrdinal == 1,
              firstBinding.descriptorMatcher == .faiss,
              firstBinding.exactRecoveryReason == nil,
              let scheduledPairCount = firstBinding.scheduledPairCount,
              scheduledPairCount > 0,
              let pairListDigest = firstBinding.pairListDigest else {
            throw GeometryWorkerExecutionArtifactError.incompleteStage
        }
        if invocations.count == 1 {
            guard first.succeeded else {
                throw GeometryWorkerExecutionArtifactError.incompleteStage
            }
            return
        }
        let exact = invocations[1]
        guard !first.succeeded,
              exact.succeeded,
              let exactBinding = exact.pairExecution,
              exactBinding.attemptOrdinal == 2,
              exactBinding.descriptorMatcher == .exact,
              exactBinding.scheduledPairCount == scheduledPairCount,
              exactBinding.pairListDigest == pairListDigest,
              DescriptorMatcherRecoveryPolicy.permitsExactRecovery(
                scheduledPairCount: scheduledPairCount
              ),
              exactBinding.exactRecoveryReason == .faissCrash
                || exactBinding.exactRecoveryReason == .faissUnsupportedOperation else {
            throw GeometryWorkerExecutionArtifactError.incompleteStage
        }
    }

    private static func validateInvocations(
        _ invocations: [ColmapWorkerInvocationEvidence],
        allowedCommands: Set<ColmapWorkerCommandIdentity>,
        expectedPolicy: GeometryWorkerThreadPolicy,
        expectedWorkerCount: Int?,
        expectsMappingAttemptOrdinal: Bool
    ) throws {
        guard invocations.count <= maximumInvocationsPerStage else {
            throw GeometryWorkerExecutionArtifactError.invalidInvocationCount
        }
        var previousMappingAttemptOrdinal = 0
        for invocation in invocations {
            guard allowedCommands.contains(invocation.command) else {
                throw GeometryWorkerExecutionArtifactError.invalidCommandForStage
            }
            guard invocation.exitStatus >= 0,
                  invocation.succeeded == (invocation.exitStatus == 0) else {
                throw GeometryWorkerExecutionArtifactError.invalidExitStatus
            }
            guard invocation.removedThreadEnvironmentKeysSHA256
                    == canonicalRemovedThreadEnvironmentKeysSHA256 else {
                throw GeometryWorkerExecutionArtifactError.invalidSanitizerDigest
            }
            guard invocation.threadPolicy == expectedPolicy else {
                throw GeometryWorkerExecutionArtifactError.invalidThreadPolicy
            }
            if expectsMappingAttemptOrdinal {
                guard let ordinal = invocation.mappingAttemptOrdinal,
                      ordinal > 0,
                      ordinal <= GeometryRecoveryState.maximumMappingAttemptCount,
                      ordinal >= previousMappingAttemptOrdinal else {
                    throw GeometryWorkerExecutionArtifactError.invalidMappingAttemptOrdinal
                }
                previousMappingAttemptOrdinal = ordinal
            } else if invocation.mappingAttemptOrdinal != nil {
                throw GeometryWorkerExecutionArtifactError.invalidMappingAttemptOrdinal
            }
            switch expectedPolicy {
            case .bounded:
                guard let expectedWorkerCount,
                      invocation.argvWorkerCount == expectedWorkerCount else {
                    throw GeometryWorkerExecutionArtifactError.workerBudgetMismatch
                }
                let expectedEnvironment = [
                    "OMP_NUM_THREADS": "\(expectedWorkerCount)",
                    "OPENBLAS_NUM_THREADS": "\(expectedWorkerCount)",
                    "MKL_NUM_THREADS": "\(expectedWorkerCount)",
                ]
                guard invocation.explicitThreadEnvironment == expectedEnvironment,
                      invocation.effectiveSanitizedThreadEnvironment == expectedEnvironment else {
                    throw GeometryWorkerExecutionArtifactError.invalidThreadEnvironment
                }
            case .nativeAuto:
                guard invocation.argvWorkerCount == nil else {
                    throw GeometryWorkerExecutionArtifactError.invalidThreadPolicy
                }
                guard invocation.explicitThreadEnvironment.isEmpty,
                      invocation.effectiveSanitizedThreadEnvironment.isEmpty else {
                    throw GeometryWorkerExecutionArtifactError.invalidThreadEnvironment
                }
            }
        }
    }

    private func validateVideoSourceAnalysis(expectedBudget: GeometryWorkerBudget) throws {
        let video = videoSourceAnalysis
        guard video.videoSourceCount >= 0,
              video.startedAnalysisTaskCount >= 0,
              video.peakInFlightAnalysisTaskCount >= 0 else {
            throw GeometryWorkerExecutionArtifactError.invalidVideoSourceAnalysis
        }
        if video.videoSourceCount == 0 {
            guard video.startedAnalysisTaskCount == 0,
                  video.peakInFlightAnalysisTaskCount == 0 else {
                throw GeometryWorkerExecutionArtifactError.invalidVideoSourceAnalysis
            }
            return
        }
        let maximumStartedTaskCount = video.videoSourceCount.multipliedReportingOverflow(by: 2)
        guard !maximumStartedTaskCount.overflow,
              video.startedAnalysisTaskCount >= video.videoSourceCount,
              video.startedAnalysisTaskCount <= maximumStartedTaskCount.partialValue,
              video.peakInFlightAnalysisTaskCount >= 1,
              video.peakInFlightAnalysisTaskCount
                <= min(
                    video.videoSourceCount,
                    expectedBudget.maximumConcurrentVideoSourceAnalysisTasks
                ) else {
            throw GeometryWorkerExecutionArtifactError.invalidVideoSourceAnalysis
        }
    }
}

public enum GeometryWorkerExecutionArtifactStore {
    public static let maximumBytes = 2 * 1_024 * 1_024

    public static func canonicalURL(for paths: ProjectPaths) -> URL {
        paths.workerExecutionURL
    }

    @discardableResult
    public static func save(
        _ artifact: GeometryWorkerExecutionArtifact,
        to url: URL,
        expectedBudget: GeometryWorkerBudget,
        projectPaths: ProjectPaths
    ) throws -> String {
        try validateLocation(url, projectPaths: projectPaths, allowMissingLeaf: true)
        try artifact.validate(expectedBudget: expectedBudget)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(artifact)
        guard !data.isEmpty, data.count <= maximumBytes else {
            throw GeometryWorkerExecutionArtifactError.invalidInvocationCount
        }
        try data.write(to: url, options: [.atomic])
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    public static func load(
        from url: URL,
        expectedBudget: GeometryWorkerBudget,
        projectPaths: ProjectPaths
    ) throws -> GeometryWorkerExecutionArtifact {
        try validateLocation(url, projectPaths: projectPaths, allowMissingLeaf: false)
        let data = try BoundedFileReader.readRegularFile(at: url, maximumBytes: maximumBytes)
        return try load(data: data, expectedBudget: expectedBudget)
    }

    public static func load(
        data: Data,
        expectedBudget: GeometryWorkerBudget
    ) throws -> GeometryWorkerExecutionArtifact {
        let artifact = try decode(data: data)
        try artifact.validate(expectedBudget: expectedBudget)
        return artifact
    }

    public static func load(
        from url: URL,
        projectPaths: ProjectPaths
    ) throws -> GeometryWorkerExecutionArtifact {
        try validateLocation(url, projectPaths: projectPaths, allowMissingLeaf: false)
        let data = try BoundedFileReader.readRegularFile(at: url, maximumBytes: maximumBytes)
        let artifact = try decode(data: data)
        try artifact.validate(expectedBudget: artifact.resolvedBudget)
        return artifact
    }

    private static func decode(data: Data) throws -> GeometryWorkerExecutionArtifact {
        guard !data.isEmpty,
              data.count <= maximumBytes,
              let artifact = try? JSONDecoder().decode(
                  GeometryWorkerExecutionArtifact.self,
                  from: data
              ) else {
            throw GeometryWorkerExecutionArtifactError.invalidSchema(-1)
        }
        return artifact
    }

    private static func validateLocation(
        _ url: URL,
        projectPaths: ProjectPaths,
        allowMissingLeaf: Bool
    ) throws {
        let expected: URL
        do {
            expected = try projectPaths.validateReservedProjectPath(
                url,
                relativePath: "SfM/worker_execution.json"
            )
        } catch {
            throw GeometryWorkerExecutionArtifactError.invalidLocation
        }
        let parent = expected.deletingLastPathComponent()
        guard let values = try? parent.resourceValues(
            forKeys: [.isDirectoryKey, .isSymbolicLinkKey]
        ),
              values.isDirectory == true,
              values.isSymbolicLink != true else {
            throw GeometryWorkerExecutionArtifactError.invalidLocation
        }
        if FileManager.default.fileExists(atPath: expected.path) {
            guard let leaf = try? expected.resourceValues(
                forKeys: [.isRegularFileKey, .isSymbolicLinkKey]
            ),
                  leaf.isRegularFile == true,
                  leaf.isSymbolicLink != true else {
                throw GeometryWorkerExecutionArtifactError.invalidLocation
            }
        } else if !allowMissingLeaf {
            throw GeometryWorkerExecutionArtifactError.invalidLocation
        }
    }
}
