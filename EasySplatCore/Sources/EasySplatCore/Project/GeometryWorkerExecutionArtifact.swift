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

public struct ColmapWorkerInvocationEvidence: Codable, Sendable, Equatable {
    private enum CodingKeys: String, CodingKey, CaseIterable {
        case command
        case mappingAttemptOrdinal
        case threadPolicy
        case argvWorkerCount
        case explicitThreadEnvironment
        case removedThreadEnvironmentKeysSHA256
        case effectiveSanitizedThreadEnvironment
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

/// The accepted geometry contract that worker evidence must prove before publication.
/// This context is derived from the persisted mapping, pair graph, and normalized input;
/// callers cannot substitute backend labels or loosely related booleans.
public struct GeometryWorkerExecutionPublicationContext: Sendable, Equatable {
    public let acceptedMappingAttemptOrdinal: Int
    public let refinementKind: MappingRefinementKind
    public let acceptedRefinementInvocationCount: Int
    public let pairGraphStatus: PairGraphMeasurementStatus
    public let requiresVocabularyRetrieval: Bool
    public let expectedVideoSourceCount: Int

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
        pairGraphStatus = pairGraph.status
        requiresVocabularyRetrieval = pairGraph.usedLocalVocabularyRetrieval
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
    public static let currentSchemaVersion = 3
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
    public var resolvedBudget: GeometryWorkerBudget
    public var featureExtractionInvocations: [ColmapWorkerInvocationEvidence]
    public var matchingInvocations: [ColmapWorkerInvocationEvidence]
    public var vocabularyRetrievalInvocations: [ColmapWorkerInvocationEvidence]
    public var mappingAndRefinementInvocations: [ColmapWorkerInvocationEvidence]
    public var videoSourceAnalysis: VideoSourceAnalysisExecutionEvidence

    public init(
        resolvedBudget: GeometryWorkerBudget,
        featureExtractionInvocations: [ColmapWorkerInvocationEvidence],
        matchingInvocations: [ColmapWorkerInvocationEvidence],
        vocabularyRetrievalInvocations: [ColmapWorkerInvocationEvidence],
        mappingAndRefinementInvocations: [ColmapWorkerInvocationEvidence],
        videoSourceAnalysis: VideoSourceAnalysisExecutionEvidence
    ) {
        schemaVersion = Self.currentSchemaVersion
        self.resolvedBudget = resolvedBudget
        self.featureExtractionInvocations = featureExtractionInvocations
        self.matchingInvocations = matchingInvocations
        self.vocabularyRetrievalInvocations = vocabularyRetrievalInvocations
        self.mappingAndRefinementInvocations = mappingAndRefinementInvocations
        self.videoSourceAnalysis = videoSourceAnalysis
    }

    public func validate(expectedBudget: GeometryWorkerBudget) throws {
        guard schemaVersion == Self.currentSchemaVersion else {
            throw GeometryWorkerExecutionArtifactError.invalidSchema(schemaVersion)
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
        try validateVideoSourceAnalysis(expectedBudget: expectedBudget)
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
            guard featureExtractionInvocations.contains(where: \.succeeded),
                  matchingInvocations.contains(where: \.succeeded) else {
                throw GeometryWorkerExecutionArtifactError.incompleteStage
            }
        }
        let hasSuccessfulVocabularyRetrieval = vocabularyRetrievalInvocations.contains {
            $0.command == .localVocabularyRetriever && $0.succeeded
        }
        guard hasSuccessfulVocabularyRetrieval == context.requiresVocabularyRetrieval else {
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
        let artifact = try load(from: url, projectPaths: projectPaths)
        guard artifact.resolvedBudget == expectedBudget else {
            throw GeometryWorkerExecutionArtifactError.workerBudgetMismatch
        }
        return artifact
    }

    public static func load(
        from url: URL,
        projectPaths: ProjectPaths
    ) throws -> GeometryWorkerExecutionArtifact {
        try validateLocation(url, projectPaths: projectPaths, allowMissingLeaf: false)
        let data = try BoundedFileReader.readRegularFile(at: url, maximumBytes: maximumBytes)
        guard !data.isEmpty,
              let artifact = try? JSONDecoder().decode(
                  GeometryWorkerExecutionArtifact.self,
                  from: data
              ) else {
            throw GeometryWorkerExecutionArtifactError.invalidSchema(-1)
        }
        try artifact.validate(expectedBudget: artifact.resolvedBudget)
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
