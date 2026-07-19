import CryptoKit
import Foundation

struct PairGraphPlanBinding: Codable, Sendable, Equatable {
    var geometryBackend: SfmBackend
    var modelIdentifier: String
    var pairingPolicy: ResolvedPairingPolicy
    var temporalPairing: TemporalPairing
    var temporalOffsets: [Int]
    var retrievalEngine: RetrievalEngine
    var retrievalCandidateCount: Int
    var retrievalNeighborCount: Int
    var retrievalQueryStride: Int
    var requiresCrossClipRetrieval: Bool
    var normalDescriptorMatcher: DescriptorMatcher
    var cameraInitializationRecipe: ColmapCameraInitializationRecipe
    var runSeed: UInt64

    var isStructurallyValid: Bool {
        let offsetsAreCanonical = temporalOffsets.allSatisfy { $0 > 0 }
            && temporalOffsets == temporalOffsets.sorted()
            && Set(temporalOffsets).count == temporalOffsets.count
        let temporalPolicyIsCoherent = (temporalPairing == .none)
            == temporalOffsets.isEmpty
        let backendIsCoherent = switch geometryBackend {
        case .colmap:
            modelIdentifier == "none"
        case .da3:
            modelIdentifier == "DA3-BASE" || modelIdentifier == "DA3-SMALL"
        }
        let supportsCrossClipRetrieval: Bool
        switch pairingPolicy {
        case .orderedContinuous, .orderedOrbit, .orderedWalkthrough,
             .orderedLargeArea, .segmentedMixed:
            supportsCrossClipRetrieval = true
        case .unorderedRetrieval:
            supportsCrossClipRetrieval = false
        }
        return backendIsCoherent
            && offsetsAreCanonical
            && temporalPolicyIsCoherent
            && retrievalCandidateCount > 0
            && retrievalNeighborCount > 0
            && retrievalNeighborCount <= retrievalCandidateCount
            && retrievalQueryStride > 0
            && normalDescriptorMatcher == .faiss
            && (cameraInitializationRecipe == .colmapAutomatic
                || cameraInitializationRecipe
                    == .sharedOpenCVFisheyeEquidistantDiagonal150V1)
            && runSeed <= UInt64(Int32.max)
            && (!requiresCrossClipRetrieval
                || (supportsCrossClipRetrieval && temporalPairing != .none))
    }

    init(_ plan: ResolvedRunPlan) {
        geometryBackend = plan.geometryBackend
        modelIdentifier = plan.modelIdentifier
        pairingPolicy = plan.pairingPolicy
        temporalPairing = plan.temporalPairing
        temporalOffsets = plan.temporalOffsets
        retrievalEngine = plan.retrievalEngine
        retrievalCandidateCount = plan.retrievalCandidateCount
        retrievalNeighborCount = plan.retrievalNeighborCount
        retrievalQueryStride = plan.retrievalQueryStride
        requiresCrossClipRetrieval = plan.requiresCrossClipRetrieval
        normalDescriptorMatcher = plan.normalDescriptorMatcher
        cameraInitializationRecipe = plan.cameraInitializationRecipe
        runSeed = plan.runSeed
    }

#if DEBUG
    static func testingDefault(
        pairingPolicy: ResolvedPairingPolicy
    ) -> PairGraphPlanBinding {
        PairGraphPlanBinding(
            geometryBackend: .colmap,
            modelIdentifier: "none",
            pairingPolicy: pairingPolicy,
            temporalPairing: .none,
            temporalOffsets: [],
            retrievalEngine: .localSiftVocabularyV2,
            retrievalCandidateCount: 20,
            retrievalNeighborCount: 8,
            retrievalQueryStride: 1,
            normalDescriptorMatcher: .faiss,
            cameraInitializationRecipe: .colmapAutomatic,
            runSeed: 42
        )
    }

    private init(
        geometryBackend: SfmBackend = .colmap,
        modelIdentifier: String = "none",
        pairingPolicy: ResolvedPairingPolicy,
        temporalPairing: TemporalPairing,
        temporalOffsets: [Int],
        retrievalEngine: RetrievalEngine,
        retrievalCandidateCount: Int,
        retrievalNeighborCount: Int,
        retrievalQueryStride: Int,
        requiresCrossClipRetrieval: Bool = false,
        normalDescriptorMatcher: DescriptorMatcher,
        cameraInitializationRecipe: ColmapCameraInitializationRecipe,
        runSeed: UInt64
    ) {
        self.geometryBackend = geometryBackend
        self.modelIdentifier = modelIdentifier
        self.pairingPolicy = pairingPolicy
        self.temporalPairing = temporalPairing
        self.temporalOffsets = temporalOffsets
        self.retrievalEngine = retrievalEngine
        self.retrievalCandidateCount = retrievalCandidateCount
        self.retrievalNeighborCount = retrievalNeighborCount
        self.retrievalQueryStride = retrievalQueryStride
        self.requiresCrossClipRetrieval = requiresCrossClipRetrieval
        self.normalDescriptorMatcher = normalDescriptorMatcher
        self.cameraInitializationRecipe = cameraInitializationRecipe
        self.runSeed = runSeed
    }
#endif
}

enum PairGraphRetrievalCandidatePolicy: String, Codable, Sendable, Equatable {
    case crossGroupV1
}

enum PairGraphRetrievalQueryStatus: String, Codable, Sendable, Equatable {
    case ranked
    case noRankedNeighbors
}

struct PairGraphRetrievalQueryOutcome: Codable, Sendable, Equatable {
    var queryImageName: String
    var status: PairGraphRetrievalQueryStatus
    var rankedNeighborImageNames: [String]
}

struct PairGraphRetrievalAttemptEvidence: Codable, Sendable, Equatable {
    var engine: RetrievalEngine
    var queryImageNames: [String]
    var queryStride: Int
    var candidateCount: Int
    var returnedNeighborCount: Int
    var minimumFrameSeparation: Int
    var candidatePolicy: PairGraphRetrievalCandidatePolicy?
    var imageGroupListDigest: String?
    var imageGroupLines: [String]?
    var queryOutcomes: [PairGraphRetrievalQueryOutcome]
    var directedPairLines: [String]
    var outputDigest: String

    init(
        engine: RetrievalEngine,
        queryImageNames: [String],
        queryStride: Int,
        candidateCount: Int,
        returnedNeighborCount: Int,
        minimumFrameSeparation: Int,
        candidatePolicy: PairGraphRetrievalCandidatePolicy? = nil,
        imageGroupListDigest: String? = nil,
        imageGroupLines: [String]? = nil,
        queryOutcomes: [PairGraphRetrievalQueryOutcome],
        directedPairLines: [String]
    ) {
        self.engine = engine
        self.queryImageNames = queryImageNames
        self.queryStride = queryStride
        self.candidateCount = candidateCount
        self.returnedNeighborCount = returnedNeighborCount
        self.minimumFrameSeparation = minimumFrameSeparation
        self.candidatePolicy = candidatePolicy
        self.imageGroupListDigest = imageGroupListDigest
        self.imageGroupLines = imageGroupLines
        self.queryOutcomes = queryOutcomes
        self.directedPairLines = directedPairLines
        outputDigest = ""
        outputDigest = PairGraphEvidenceStore.retrievalOutputDigest(self)
    }
}

struct PairGraphAttemptEvidence: Codable, Sendable, Equatable {
    var artifact: PairMatchingAttemptArtifact
    var scheduledPairs: [ColmapScheduledPair]
    var retrieval: PairGraphRetrievalAttemptEvidence?
    var retrievalWasExecuted: Bool

    init(
        artifact: PairMatchingAttemptArtifact,
        scheduledPairs: [ColmapScheduledPair],
        retrieval: PairGraphRetrievalAttemptEvidence? = nil,
        retrievalWasExecuted: Bool? = nil
    ) {
        self.artifact = artifact
        self.scheduledPairs = scheduledPairs
        self.retrieval = retrieval
        self.retrievalWasExecuted = retrievalWasExecuted ?? (retrieval != nil)
    }
}

struct PersistedColmapPairGraphInspection: Codable, Sendable, Equatable {
    var scheduledPairCount: Int
    var attemptedPairCount: Int
    var rawMatchedPairCount: Int
    var spatiallyVerifiedPairCount: Int
    var localPairCount: Int
    var retrievalPairCount: Int
    var loopRevisitPairCount: Int
    var connectedComponentCount: Int
    var isolatedViewCount: Int
    var descriptorlessViewCount: Int
    var componentViewCounts: [Int]
    var articulationViewCount: Int
    var biconnectedBlockCount: Int
    var largestBiconnectedBlockViewCount: Int
    var secondLargestBiconnectedBlockViewCount: Int
    var degreeP10: Int
    var degreeMedian: Int
    var degreeP90: Int
    var featureDatabaseDigest: String
    var matchingDatabaseDigest: String
    var attemptedPairs: [ColmapScheduledPair]
    var rawMatchedPairs: [ColmapScheduledPair]
    var spatiallyVerifiedPairs: [ColmapScheduledPair]

    init(_ inspection: ColmapPairGraphInspection) {
        scheduledPairCount = inspection.scheduledPairCount
        attemptedPairCount = inspection.attemptedPairCount
        rawMatchedPairCount = inspection.rawMatchedPairCount
        spatiallyVerifiedPairCount = inspection.spatiallyVerifiedPairCount
        localPairCount = inspection.localPairCount
        retrievalPairCount = inspection.retrievalPairCount
        loopRevisitPairCount = inspection.loopRevisitPairCount
        connectedComponentCount = inspection.connectedComponentCount
        isolatedViewCount = inspection.isolatedViewCount
        descriptorlessViewCount = inspection.descriptorlessViewCount
        componentViewCounts = inspection.verifiedGraph.components
            .map(\.count)
            .sorted(by: >)
        articulationViewCount = inspection.articulationViewCount
        biconnectedBlockCount = inspection.biconnectedBlockCount
        largestBiconnectedBlockViewCount = inspection.largestBiconnectedBlockViewCount
        secondLargestBiconnectedBlockViewCount = inspection.secondLargestBiconnectedBlockViewCount
        degreeP10 = inspection.degreeP10
        degreeMedian = inspection.degreeMedian
        degreeP90 = inspection.degreeP90
        featureDatabaseDigest = inspection.featureDatabaseDigest
        matchingDatabaseDigest = inspection.matchingDatabaseDigest
        attemptedPairs = inspection.attemptedPairs
        rawMatchedPairs = inspection.rawMatchedPairs
        spatiallyVerifiedPairs = inspection.verifiedGraph.verifiedPairs
    }
}

struct PairGraphEvidence: Codable, Sendable, Equatable {
    static let currentSchemaVersion = 20

    var schemaVersion: Int
    var selectedFramesDigest: String
    var imageNames: [String]
    var pairingPolicy: ResolvedPairingPolicy
    var planBinding: PairGraphPlanBinding
    var attempts: [PairGraphAttemptEvidence]
    var acceptedAttemptNumber: Int
    var acceptedInspection: PersistedColmapPairGraphInspection
    var retrievalWasScheduled: Bool
    var usedLocalVocabularyRetrieval: Bool
    var pairListDigest: String
    var matchingDurationSeconds: Double
    var fallbackReasons: [String]

    init(
        selectedFramesDigest: String,
        imageNames: [String],
        pairingPolicy: ResolvedPairingPolicy = .orderedContinuous,
        planBinding: PairGraphPlanBinding,
        attempts: [PairGraphAttemptEvidence],
        acceptedAttemptNumber: Int,
        acceptedInspection: ColmapPairGraphInspection,
        retrievalWasScheduled: Bool = false,
        usedLocalVocabularyRetrieval: Bool = false,
        matchingDurationSeconds: Double,
        fallbackReasons: [String]
    ) {
        schemaVersion = Self.currentSchemaVersion
        self.selectedFramesDigest = selectedFramesDigest
        self.imageNames = imageNames
        self.pairingPolicy = pairingPolicy
        self.planBinding = planBinding
        self.attempts = attempts
        self.acceptedAttemptNumber = acceptedAttemptNumber
        self.acceptedInspection = PersistedColmapPairGraphInspection(acceptedInspection)
        self.retrievalWasScheduled = retrievalWasScheduled
        self.usedLocalVocabularyRetrieval = usedLocalVocabularyRetrieval
        pairListDigest = Self.digest(of: attempts.last?.scheduledPairs ?? [])
        self.matchingDurationSeconds = matchingDurationSeconds
        self.fallbackReasons = fallbackReasons
    }

#if DEBUG
    init(
        selectedFramesDigest: String,
        imageNames: [String],
        pairingPolicy: ResolvedPairingPolicy = .orderedContinuous,
        attempts: [PairGraphAttemptEvidence],
        acceptedAttemptNumber: Int,
        acceptedInspection: ColmapPairGraphInspection,
        retrievalWasScheduled: Bool = false,
        usedLocalVocabularyRetrieval: Bool = false,
        matchingDurationSeconds: Double,
        fallbackReasons: [String]
    ) {
        self.init(
            selectedFramesDigest: selectedFramesDigest,
            imageNames: imageNames,
            pairingPolicy: pairingPolicy,
            planBinding: .testingDefault(pairingPolicy: pairingPolicy),
            attempts: attempts,
            acceptedAttemptNumber: acceptedAttemptNumber,
            acceptedInspection: acceptedInspection,
            retrievalWasScheduled: retrievalWasScheduled,
            usedLocalVocabularyRetrieval: usedLocalVocabularyRetrieval,
            matchingDurationSeconds: matchingDurationSeconds,
            fallbackReasons: fallbackReasons
        )
    }
#endif

    func pairGraphMeasurement() throws -> PairGraphMeasurement {
        try PairGraphEvidenceStore.validate(self)
        return uncheckedPairGraphMeasurement()
    }

    fileprivate func uncheckedPairGraphMeasurement() -> PairGraphMeasurement {
        PairGraphMeasurement(
            pairingPolicy: pairingPolicy,
            scheduledPairCount: acceptedInspection.scheduledPairCount,
            attemptedPairCount: acceptedInspection.attemptedPairCount,
            rawMatchedPairCount: acceptedInspection.rawMatchedPairCount,
            spatiallyVerifiedPairCount: acceptedInspection.spatiallyVerifiedPairCount,
            localPairCount: acceptedInspection.localPairCount,
            retrievalPairCount: acceptedInspection.retrievalPairCount,
            loopRevisitPairCount: acceptedInspection.loopRevisitPairCount,
            connectedComponentCount: acceptedInspection.connectedComponentCount,
            isolatedViewCount: acceptedInspection.isolatedViewCount,
            descriptorlessViewCount: acceptedInspection.descriptorlessViewCount,
            componentViewCounts: acceptedInspection.componentViewCounts,
            articulationViewCount: acceptedInspection.articulationViewCount,
            biconnectedBlockCount: acceptedInspection.biconnectedBlockCount,
            largestBiconnectedBlockViewCount: acceptedInspection.largestBiconnectedBlockViewCount,
            secondLargestBiconnectedBlockViewCount: acceptedInspection.secondLargestBiconnectedBlockViewCount,
            degreeP10: acceptedInspection.degreeP10,
            degreeMedian: acceptedInspection.degreeMedian,
            degreeP90: acceptedInspection.degreeP90,
            matcherAttempts: attempts.map(\.artifact),
            pairListDigest: pairListDigest,
            featureDatabaseDigest: acceptedInspection.featureDatabaseDigest,
            matchingDatabaseDigest: acceptedInspection.matchingDatabaseDigest,
            matchingDurationSeconds: matchingDurationSeconds
        )
    }

    func pairGraphArtifact() throws -> PairGraphArtifact {
        .measured(
            try pairGraphMeasurement(),
            requiresCrossClipRetrieval: planBinding.requiresCrossClipRetrieval,
            retrievalWasScheduled: retrievalWasScheduled,
            usedLocalVocabularyRetrieval: usedLocalVocabularyRetrieval
        )
    }

    func mapperWorkerInvocationContext() throws -> ColmapMapperWorkerInvocationContext {
        try PairGraphEvidenceStore.validate(self)
        guard let acceptedAttempt = attempts.last else {
            throw PairGraphEvidenceStoreError.invalidEvidence
        }
        return ColmapMapperWorkerInvocationContext(
            pairGraphAttemptOrdinal: acceptedAttemptNumber,
            pairListDigest: pairListDigest,
            descriptorMatcher: acceptedAttempt.artifact.matcher,
            matchingDatabaseDigest: acceptedInspection.matchingDatabaseDigest
        )
    }

    func restoredPairPlan() throws -> ColmapPairPlan {
        try PairGraphEvidenceStore.validate(self)
        guard let acceptedAttempt = attempts.last else {
            throw PairGraphEvidenceStoreError.invalidEvidence
        }
        return try ColmapPairPlan.persisted(
            imageNames: imageNames,
            scheduledPairs: acceptedAttempt.scheduledPairs
        )
    }

    static func digest(of pairs: [ColmapScheduledPair]) -> String {
        let data = pairs.isEmpty
            ? Data()
            : Data((pairs.map(\.line).joined(separator: "\n") + "\n").utf8)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

enum PairGraphEvidenceStore {
    static let maximumBytes = 64 * 1_024 * 1_024

    static func load(from url: URL, projectPaths: ProjectPaths) throws -> PairGraphEvidence {
        try load(data: readEvidenceData(from: url, projectPaths: projectPaths))
    }

    static func load(data: Data) throws -> PairGraphEvidence {
        let evidence = try decodeUnchecked(data: data)
        try validate(evidence)
        return evidence
    }

    private static func decodeUnchecked(data: Data) throws -> PairGraphEvidence {
        guard !data.isEmpty, data.count <= maximumBytes else {
            throw PairGraphEvidenceStoreError.invalidEvidence
        }
        let envelope: SchemaEnvelope
        do {
            envelope = try JSONDecoder().decode(SchemaEnvelope.self, from: data)
        } catch {
            throw PairGraphEvidenceStoreError.invalidEvidence
        }
        guard envelope.schemaVersion == PairGraphEvidence.currentSchemaVersion else {
            throw PairGraphEvidenceStoreError.invalidSchema(envelope.schemaVersion)
        }
        let evidence: PairGraphEvidence
        do {
            evidence = try JSONDecoder().decode(PairGraphEvidence.self, from: data)
        } catch {
            throw PairGraphEvidenceStoreError.invalidEvidence
        }
        return evidence
    }

    static func loadVerifiedDa3Refinement(
        from url: URL,
        expectedImageNames: [String],
        expectedPlanBinding: PairGraphPlanBinding,
        expectedPairPlan: ColmapPairPlan,
        databaseURL: URL,
        projectPaths: ProjectPaths
    ) throws -> PairGraphEvidence {
        try Task.checkCancellation()
        let evidence = try decodeUnchecked(
            data: readEvidenceData(from: url, projectPaths: projectPaths)
        )
        let selectedDigest = try GeometryArtifactStore.selectedFramesDigest(
            orderedImageNames: expectedImageNames,
            projectPaths: projectPaths
        )
        guard evidence.imageNames == expectedImageNames,
              evidence.selectedFramesDigest == selectedDigest else {
            throw PairGraphEvidenceStoreError.invalidEvidence
        }
        try validateDa3Refinement(
            evidence,
            expectedPlanBinding: expectedPlanBinding,
            expectedPairPlan: expectedPairPlan
        )
        let acceptedAttempt = try requiredAcceptedAttempt(evidence)
        let liveInspection = try ColmapPairGraphInspector(
            databaseURL: databaseURL
        ).inspect(
            schedule: ColmapPairSchedule(
                imageNames: evidence.imageNames,
                pairs: acceptedAttempt.scheduledPairs
            ),
            completion: .succeeded
        )
        guard PersistedColmapPairGraphInspection(liveInspection)
                == evidence.acceptedInspection else {
            throw PairGraphEvidenceStoreError.invalidEvidence
        }
        try Task.checkCancellation()
        return evidence
    }

    static func saveDa3Refinement(
        _ evidence: PairGraphEvidence,
        expectedPlanBinding: PairGraphPlanBinding,
        expectedPairPlan: ColmapPairPlan,
        to url: URL,
        projectPaths: ProjectPaths
    ) throws {
        try validateLocation(url, projectPaths: projectPaths)
        try validateDa3Refinement(
            evidence,
            expectedPlanBinding: expectedPlanBinding,
            expectedPairPlan: expectedPairPlan
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(evidence)
        guard !data.isEmpty, data.count <= maximumBytes else {
            throw PairGraphEvidenceStoreError.invalidEvidence
        }
        try data.write(to: url, options: [.atomic])
    }

    static func validateDa3Refinement(
        _ evidence: PairGraphEvidence,
        expectedPlanBinding: PairGraphPlanBinding,
        expectedPairPlan: ColmapPairPlan
    ) throws {
        guard evidence.schemaVersion == PairGraphEvidence.currentSchemaVersion,
              isSHA256(evidence.selectedFramesDigest),
              evidence.planBinding == expectedPlanBinding,
              evidence.planBinding.geometryBackend == .da3,
              evidence.planBinding.pairingPolicy == evidence.pairingPolicy,
              evidence.planBinding.isStructurallyValid,
              expectedPairPlan.imageNames == evidence.imageNames,
              !evidence.retrievalWasScheduled,
              !evidence.usedLocalVocabularyRetrieval,
              evidence.attempts.allSatisfy({ attempt in
                  attempt.retrieval == nil
                      && !attempt.retrievalWasExecuted
                      && attempt.scheduledPairs == expectedPairPlan.pairs
              }),
              evidence.acceptedAttemptNumber == evidence.attempts.count,
              evidence.pairListDigest == expectedPairPlan.sha256 else {
            throw PairGraphEvidenceStoreError.invalidEvidence
        }
        try validateAttemptHistory(
            imageNames: evidence.imageNames,
            pairingPolicy: evidence.pairingPolicy,
            attempts: evidence.attempts,
            matchingDurationSeconds: evidence.matchingDurationSeconds,
            fallbackReasons: evidence.fallbackReasons
        )
        let acceptedAttempt = try requiredAcceptedAttempt(evidence)
        guard acceptedAttempt.artifact.attemptNumber
                == evidence.acceptedAttemptNumber,
              acceptedAttempt.artifact.outcome == .completed,
              PairGraphEvidence.digest(of: acceptedAttempt.scheduledPairs)
                == evidence.pairListDigest else {
            throw PairGraphEvidenceStoreError.invalidEvidence
        }
        try validate(
            evidence.acceptedInspection,
            against: acceptedAttempt,
            imageCount: evidence.imageNames.count,
            pairingPolicy: evidence.pairingPolicy
        )
    }

    static func validateDa3WorkerExecution(
        _ evidence: PairGraphEvidence,
        expectedPlanBinding: PairGraphPlanBinding,
        expectedPairPlan: ColmapPairPlan,
        workerExecution: GeometryWorkerExecutionArtifact
    ) throws {
        try validateDa3Refinement(
            evidence,
            expectedPlanBinding: expectedPlanBinding,
            expectedPairPlan: expectedPairPlan
        )
        let invocations = workerExecution.matchingInvocations
        guard invocations.count == evidence.attempts.count,
              workerExecution.vocabularyRetrievalInvocations.isEmpty,
              workerExecution.rejectedVocabularyRetrievalInvocations.isEmpty else {
            throw PairGraphEvidenceStoreError.invalidEvidence
        }
        for (index, pair) in zip(evidence.attempts, invocations).enumerated() {
            let attempt = pair.0
            let invocation = pair.1
            let outcomeMatchesInvocation = switch attempt.artifact.outcome {
            case .completed:
                invocation.succeeded
            case .failed:
                !invocation.succeeded
            case .rejected:
                false
            }
            guard invocation.command == .matchesImporter,
                  let binding = invocation.pairExecution,
                  binding.attemptOrdinal == attempt.artifact.attemptNumber,
                  binding.descriptorMatcher == attempt.artifact.matcher,
                  binding.scheduledPairCount == attempt.artifact.scheduledPairCount,
                  binding.pairListDigest == evidence.pairListDigest,
                  binding.exactRecoveryReason
                    == attempt.artifact.exactRecoveryReason,
                  binding.retrievalRequestDigest == nil,
                  binding.retrievalOutputDigest == nil,
                  outcomeMatchesInvocation else {
                throw PairGraphEvidenceStoreError.invalidEvidence
            }
            if attempt.artifact.matcher == .exact {
                guard index > 0,
                      !invocations[index - 1].succeeded else {
                    throw PairGraphEvidenceStoreError.invalidEvidence
                }
            }
        }
    }

    static func da3PairGraphArtifact(
        _ evidence: PairGraphEvidence,
        expectedPlanBinding: PairGraphPlanBinding,
        expectedPairPlan: ColmapPairPlan
    ) throws -> PairGraphArtifact {
        try validateDa3Refinement(
            evidence,
            expectedPlanBinding: expectedPlanBinding,
            expectedPairPlan: expectedPairPlan
        )
        return .measured(
            evidence.uncheckedPairGraphMeasurement(),
            requiresCrossClipRetrieval: false,
            retrievalWasScheduled: false,
            usedLocalVocabularyRetrieval: false
        )
    }

    private static func requiredAcceptedAttempt(
        _ evidence: PairGraphEvidence
    ) throws -> PairGraphAttemptEvidence {
        guard let accepted = evidence.attempts.last else {
            throw PairGraphEvidenceStoreError.invalidEvidence
        }
        return accepted
    }

    static func loadVerified(
        from url: URL,
        expectedImageNames: [String],
        databaseURL: URL,
        projectPaths: ProjectPaths
    ) throws -> PairGraphEvidence {
        try Task.checkCancellation()
        return try loadVerified(
            data: readEvidenceData(from: url, projectPaths: projectPaths),
            expectedImageNames: expectedImageNames,
            databaseURL: databaseURL,
            projectPaths: projectPaths
        )
    }

    static func loadVerified(
        data: Data,
        expectedImageNames: [String],
        databaseURL: URL,
        projectPaths: ProjectPaths
    ) throws -> PairGraphEvidence {
        try Task.checkCancellation()
        let evidence = try loadBound(
            data: data,
            expectedImageNames: expectedImageNames,
            projectPaths: projectPaths
        )
        guard let acceptedAttempt = evidence.attempts.last else {
            throw PairGraphEvidenceStoreError.invalidEvidence
        }
        let liveInspection = try ColmapPairGraphInspector(
            databaseURL: databaseURL
        ).inspect(
            schedule: ColmapPairSchedule(
                imageNames: evidence.imageNames,
                pairs: acceptedAttempt.scheduledPairs
            ),
            completion: .succeeded
        )
        guard PersistedColmapPairGraphInspection(liveInspection)
                == evidence.acceptedInspection else {
            throw PairGraphEvidenceStoreError.invalidEvidence
        }
        try Task.checkCancellation()
        return evidence
    }

    static func loadBound(
        from url: URL,
        expectedImageNames: [String],
        projectPaths: ProjectPaths
    ) throws -> PairGraphEvidence {
        try loadBound(
            data: readEvidenceData(from: url, projectPaths: projectPaths),
            expectedImageNames: expectedImageNames,
            projectPaths: projectPaths
        )
    }

    static func loadBound(
        data: Data,
        expectedImageNames: [String],
        projectPaths: ProjectPaths
    ) throws -> PairGraphEvidence {
        let evidence = try load(data: data)
        let selectedDigest = try GeometryArtifactStore.selectedFramesDigest(
            orderedImageNames: expectedImageNames,
            projectPaths: projectPaths
        )
        guard evidence.imageNames == expectedImageNames,
              evidence.selectedFramesDigest == selectedDigest else {
            throw PairGraphEvidenceStoreError.invalidEvidence
        }
        return evidence
    }

    private static func readEvidenceData(
        from url: URL,
        projectPaths: ProjectPaths
    ) throws -> Data {
        try validateLocation(url, projectPaths: projectPaths)
        return try BoundedFileReader.readRegularFile(
            at: url,
            maximumBytes: maximumBytes
        )
    }

    static func save(
        _ evidence: PairGraphEvidence,
        to url: URL,
        projectPaths: ProjectPaths
    ) throws {
        try validateLocation(url, projectPaths: projectPaths)
        try validate(evidence)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(evidence)
        guard !data.isEmpty, data.count <= maximumBytes else {
            throw PairGraphEvidenceStoreError.invalidEvidence
        }
        try data.write(to: url, options: [.atomic])
    }

    static func validate(_ evidence: PairGraphEvidence) throws {
        guard evidence.schemaVersion == PairGraphEvidence.currentSchemaVersion else {
            throw PairGraphEvidenceStoreError.invalidSchema(evidence.schemaVersion)
        }
        let acceptedAttempt = evidence.attempts.last
        guard isSHA256(evidence.selectedFramesDigest),
              evidence.planBinding.geometryBackend == .colmap,
              evidence.planBinding.pairingPolicy == evidence.pairingPolicy,
              evidence.planBinding.isStructurallyValid,
              evidence.planBinding.normalDescriptorMatcher == .faiss,
              evidence.planBinding.retrievalCandidateCount > 0,
              evidence.planBinding.retrievalNeighborCount > 0,
              evidence.planBinding.retrievalNeighborCount
                <= evidence.planBinding.retrievalCandidateCount,
              evidence.planBinding.retrievalQueryStride > 0,
              evidence.planBinding.temporalOffsets.allSatisfy({ $0 > 0 }),
              evidence.planBinding.temporalOffsets
                == evidence.planBinding.temporalOffsets.sorted(),
              Set(evidence.planBinding.temporalOffsets).count
                == evidence.planBinding.temporalOffsets.count,
              (evidence.planBinding.temporalPairing == .none)
                == evidence.planBinding.temporalOffsets.isEmpty,
              !evidence.planBinding.requiresCrossClipRetrieval
                || ((isOrdered(evidence.pairingPolicy)
                    || evidence.pairingPolicy == .segmentedMixed)
                    && evidence.planBinding.temporalPairing != .none),
              evidence.acceptedAttemptNumber == evidence.attempts.count,
              evidence.retrievalWasScheduled
                == PairGraphRetrievalScheduling.isRequired(
                    pairingPolicy: evidence.pairingPolicy,
                    selectedFrameCount: evidence.imageNames.count,
                    requiresCrossClipRetrieval:
                        evidence.planBinding.requiresCrossClipRetrieval
                ),
              evidence.attempts.allSatisfy({ attempt in
                  (attempt.retrieval != nil) == retrievalIsRequired(
                      pairingPolicy: evidence.pairingPolicy,
                      imageCount: evidence.imageNames.count,
                      recoveryLevel: attempt.artifact.recoveryLevel,
                      requiresCrossClipRetrieval:
                        evidence.planBinding.requiresCrossClipRetrieval
                  )
              }),
              evidence.usedLocalVocabularyRetrieval
                == (acceptedAttempt?.retrieval != nil),
              !evidence.usedLocalVocabularyRetrieval
                || evidence.retrievalWasScheduled else {
            throw PairGraphEvidenceStoreError.invalidEvidence
        }
        try validateAttemptHistory(
            imageNames: evidence.imageNames,
            pairingPolicy: evidence.pairingPolicy,
            attempts: evidence.attempts,
            matchingDurationSeconds: evidence.matchingDurationSeconds,
            fallbackReasons: evidence.fallbackReasons
        )

        guard let acceptedAttempt,
              acceptedAttempt.artifact.attemptNumber == evidence.acceptedAttemptNumber,
              acceptedAttempt.artifact.outcome == .completed,
              PairGraphEvidence.digest(of: acceptedAttempt.scheduledPairs)
                  == evidence.pairListDigest else {
            throw PairGraphEvidenceStoreError.invalidEvidence
        }
        try validate(
            evidence.acceptedInspection,
            against: acceptedAttempt,
            imageCount: evidence.imageNames.count,
            pairingPolicy: evidence.pairingPolicy
        )

    }

    static func validateWorkerExecution(
        _ evidence: PairGraphEvidence,
        workerExecution: GeometryWorkerExecutionArtifact
    ) throws {
        try validate(evidence)
        let matcherInvocations = workerExecution.matchingInvocations
        guard matcherInvocations.count == evidence.attempts.count else {
            throw PairGraphEvidenceStoreError.invalidEvidence
        }
        for (attempt, invocation) in zip(evidence.attempts, matcherInvocations) {
            guard invocation.command == .matchesImporter,
                  let binding = invocation.pairExecution,
                  binding.attemptOrdinal == attempt.artifact.attemptNumber,
                  binding.descriptorMatcher == attempt.artifact.matcher,
                  binding.scheduledPairCount
                    == attempt.artifact.scheduledPairCount,
                  binding.pairListDigest == PairGraphEvidence.digest(
                    of: attempt.scheduledPairs
                  ),
                  binding.exactRecoveryReason
                    == attempt.artifact.exactRecoveryReason else {
                throw PairGraphEvidenceStoreError.invalidEvidence
            }
            let requestDigest = attempt.retrieval.map(retrievalRequestDigest)
            let outputDigest = attempt.retrieval.map(retrievalOutputDigest)
            guard binding.retrievalRequestDigest == requestDigest,
                  binding.retrievalOutputDigest == outputDigest,
                  attempt.artifact.outcome == .failed || invocation.succeeded else {
                throw PairGraphEvidenceStoreError.invalidEvidence
            }
        }
        for index in evidence.attempts.indices where
            evidence.attempts[index].artifact.matcher == .exact {
            guard index > 0,
                  let reason = evidence.attempts[index]
                    .artifact.exactRecoveryReason else {
                throw PairGraphEvidenceStoreError.invalidEvidence
            }
            let predecessor = matcherInvocations[index - 1]
            switch reason {
            case .faissCrash, .faissUnsupportedOperation:
                guard !predecessor.succeeded else {
                    throw PairGraphEvidenceStoreError.invalidEvidence
                }
            case .faissGeometryRejectedAfterRetries:
                guard predecessor.succeeded else {
                    throw PairGraphEvidenceStoreError.invalidEvidence
                }
            }
        }

        var expectedRetrievals: [(Int, DescriptorMatcher, String, String)] = []
        for attempt in evidence.attempts {
            guard attempt.retrievalWasExecuted,
                  let retrieval = attempt.retrieval else { continue }
            let requestDigest = retrievalRequestDigest(retrieval)
            let outputDigest = retrievalOutputDigest(retrieval)
            expectedRetrievals.append((
                attempt.artifact.attemptNumber,
                attempt.artifact.matcher,
                requestDigest,
                outputDigest
            ))
        }
        guard workerExecution.vocabularyRetrievalInvocations.count
                == expectedRetrievals.count else {
            throw PairGraphEvidenceStoreError.invalidEvidence
        }
        for (expected, invocation) in zip(
            expectedRetrievals,
            workerExecution.vocabularyRetrievalInvocations
        ) {
            guard invocation.command == .localVocabularyRetriever,
                  invocation.succeeded,
                  let binding = invocation.pairExecution,
                  binding.attemptOrdinal == expected.0,
                  binding.descriptorMatcher == expected.1,
                  binding.scheduledPairCount == nil,
                  binding.pairListDigest == nil,
                  binding.exactRecoveryReason == nil,
                  binding.retrievalRequestDigest == expected.2,
                  binding.retrievalOutputDigest == expected.3 else {
                throw PairGraphEvidenceStoreError.invalidEvidence
            }
        }
    }

    static func matchingSeedSidecarContents(
        evidence: PairGraphEvidence,
        workerExecution: GeometryWorkerExecutionArtifact,
        resolvedPlan: ResolvedRunPlan,
        groups: [ColmapPairGroup]
    ) throws -> [String: Data] {
        try workerExecution.validate(
            expectedBudget: workerExecution.resolvedBudget
        )
        try validateSchedule(
            evidence,
            resolvedPlan: resolvedPlan,
            groups: groups
        )
        try validateWorkerExecution(
            evidence,
            workerExecution: workerExecution
        )

        var sidecars = [String: Data]()
        var attemptsByNumber = [Int: PairGraphAttemptEvidence]()
        for attempt in evidence.attempts {
            guard attemptsByNumber.updateValue(
                attempt,
                forKey: attempt.artifact.attemptNumber
            ) == nil else {
                throw PairGraphEvidenceStoreError.invalidEvidence
            }
            let plan = try ColmapPairPlan.persisted(
                imageNames: evidence.imageNames,
                scheduledPairs: attempt.scheduledPairs
            )
            sidecars["match_pairs_attempt_\(attempt.artifact.attemptNumber).txt"] =
                plan.serializedData
        }

        var retrievalByRecoveryLevel = [
            String: (
                retrieval: PairGraphRetrievalAttemptEvidence,
                basePlan: ColmapPairPlan
            )
        ]()
        func recordRetrieval(
            _ retrieval: PairGraphRetrievalAttemptEvidence,
            basePlan: ColmapPairPlan,
            recoveryLevel: PairGraphRecoveryLevel
        ) throws {
            let key = recoveryLevel.rawValue
            if let existing = retrievalByRecoveryLevel[key] {
                guard existing.retrieval == retrieval,
                      existing.basePlan == basePlan else {
                    throw PairGraphEvidenceStoreError.invalidEvidence
                }
                return
            }
            retrievalByRecoveryLevel[key] = (retrieval, basePlan)
        }
        let expectedPlanBinding = PairGraphPlanBinding(resolvedPlan)
        for rejected in workerExecution.rejectedVocabularyRetrievalInvocations {
            guard rejected.planBinding == expectedPlanBinding,
                  rejected.pairingPolicy == evidence.pairingPolicy,
                  rejected.imageNames == evidence.imageNames,
                  rejected.groups == groups,
                  let attemptNumber = rejected.invocation
                    .pairExecution?.attemptOrdinal,
                  attemptsByNumber[attemptNumber] != nil else {
                throw PairGraphEvidenceStoreError.invalidEvidence
            }
            let basePlan = try PipelineRunner.baseColmapPairPlan(
                imageNames: evidence.imageNames,
                groups: rejected.groups,
                resolvedPlan: resolvedPlan,
                recoveryLevel: PipelineRunner.PairRecoveryLevel(
                    rejected.recoveryLevel
                )
            )
            try recordRetrieval(
                rejected.retrieval,
                basePlan: basePlan,
                recoveryLevel: rejected.recoveryLevel
            )
        }
        for attempt in evidence.attempts where attempt.retrievalWasExecuted {
            guard let retrieval = attempt.retrieval else {
                throw PairGraphEvidenceStoreError.invalidEvidence
            }
            let basePlan = try PipelineRunner.baseColmapPairPlan(
                imageNames: evidence.imageNames,
                groups: groups,
                resolvedPlan: resolvedPlan,
                recoveryLevel: PipelineRunner.PairRecoveryLevel(
                    attempt.artifact.recoveryLevel
                )
            )
            try recordRetrieval(
                retrieval,
                basePlan: basePlan,
                recoveryLevel: attempt.artifact.recoveryLevel
            )
        }

        for recoveryLevel in retrievalByRecoveryLevel.keys.sorted() {
            guard let closure = retrievalByRecoveryLevel[recoveryLevel],
                  !closure.retrieval.queryImageNames.isEmpty else {
                throw PairGraphEvidenceStoreError.invalidEvidence
            }
            sidecars["retrieval_queries_\(recoveryLevel).txt"] = Data(
                (closure.retrieval.queryImageNames.joined(separator: "\n") + "\n").utf8
            )
            let groupContract = try PipelineRunner
                .vocabularyRetrievalImageGroupContract(
                    imageNames: evidence.imageNames,
                    groups: groups,
                    requiresCrossClipRetrieval:
                        resolvedPlan.requiresCrossClipRetrieval
                )
            if let groupContract {
                guard closure.retrieval.candidatePolicy == groupContract.policy,
                      closure.retrieval.imageGroupListDigest
                        == groupContract.digest,
                      closure.retrieval.imageGroupLines
                        == groupContract.canonicalLines else {
                    throw PairGraphEvidenceStoreError.invalidEvidence
                }
                sidecars["retrieval_image_groups_\(recoveryLevel).txt"] =
                    groupContract.serializedData
            } else if closure.retrieval.candidatePolicy != nil
                        || closure.retrieval.imageGroupListDigest != nil
                        || closure.retrieval.imageGroupLines != nil {
                throw PairGraphEvidenceStoreError.invalidEvidence
            }
            sidecars["retrieval_pairs_\(recoveryLevel).txt"] = Data(
                (retrievalContractLines(closure.retrieval)
                    .joined(separator: "\n") + "\n").utf8
            )
            if !closure.basePlan.pairs.isEmpty {
                sidecars["retrieval_exclusions_\(recoveryLevel).txt"] =
                    closure.basePlan.serializedData
            }
        }
        guard sidecars.values.allSatisfy({ !$0.isEmpty }) else {
            throw PairGraphEvidenceStoreError.invalidEvidence
        }
        return sidecars
    }

    static func retrievalRequestDigest(
        _ retrieval: PairGraphRetrievalAttemptEvidence
    ) -> String {
        retrievalRequestDigest(
            engine: retrieval.engine,
            queryImageNames: retrieval.queryImageNames,
            queryStride: retrieval.queryStride,
            candidateCount: retrieval.candidateCount,
            returnedNeighborCount: retrieval.returnedNeighborCount,
            minimumFrameSeparation: retrieval.minimumFrameSeparation,
            candidatePolicy: retrieval.candidatePolicy,
            imageGroupListDigest: retrieval.imageGroupListDigest
        )
    }

    static func retrievalRequestDigest(
        engine: RetrievalEngine,
        queryImageNames: [String],
        queryStride: Int,
        candidateCount: Int,
        returnedNeighborCount: Int,
        minimumFrameSeparation: Int,
        candidatePolicy: PairGraphRetrievalCandidatePolicy? = nil,
        imageGroupListDigest: String? = nil
    ) -> String {
        var fields = [
            engine.rawValue,
            String(queryStride),
            String(candidateCount),
            String(returnedNeighborCount),
            String(minimumFrameSeparation),
        ]
        switch (candidatePolicy, imageGroupListDigest) {
        case let (policy?, digest?):
            fields.append(policy.rawValue)
            fields.append(digest)
        case (nil, nil):
            break
        case (_?, nil):
            fields.append("invalidMissingImageGroupDigest")
        case (nil, _?):
            fields.append("invalidMissingCandidatePolicy")
        }
        return canonicalStringDigest(fields + queryImageNames)
    }

    static func imageGroupListDigest(
        policy: PairGraphRetrievalCandidatePolicy,
        canonicalLines: [String]
    ) -> String {
        canonicalStringDigest([policy.rawValue] + canonicalLines)
    }

    static func retrievalOutputDigest(
        _ retrieval: PairGraphRetrievalAttemptEvidence
    ) -> String {
        retrievalOutputDigest(lines: retrievalContractLines(retrieval))
    }

    static func retrievalOutputDigest(lines: [String]) -> String {
        canonicalStringDigest(lines)
    }

    static func retrievalContractLines(
        _ retrieval: PairGraphRetrievalAttemptEvidence
    ) -> [String] {
        var headerFields = [
            retrieval.candidatePolicy == nil
                && retrieval.imageGroupListDigest == nil
                ? "EASYSPLAT_RETRIEVAL_OUTCOMES_V2"
                : "EASYSPLAT_RETRIEVAL_OUTCOMES_V3",
            retrieval.engine.rawValue,
            String(retrieval.queryStride),
            String(retrieval.candidateCount),
            String(retrieval.returnedNeighborCount),
            String(retrieval.minimumFrameSeparation),
        ]
        if let candidatePolicy = retrieval.candidatePolicy,
           let imageGroupListDigest = retrieval.imageGroupListDigest {
            headerFields.append(candidatePolicy.rawValue)
            headerFields.append(imageGroupListDigest)
        }
        headerFields.append(String(retrieval.queryImageNames.count))
        headerFields.append(retrievalRequestDigest(retrieval))
        let header = headerFields.joined(separator: " ")
        let outcomes = retrieval.queryOutcomes.map { outcome in
            ([
                "Q",
                outcome.status.rawValue,
                outcome.queryImageName,
                String(outcome.rankedNeighborImageNames.count),
            ] + outcome.rankedNeighborImageNames).joined(separator: " ")
        }
        return [header]
            + outcomes
            + retrieval.directedPairLines.map { "P \($0)" }
    }

    private static func canonicalStringDigest(_ fields: [String]) -> String {
        var data = Data()
        for field in fields {
            data.append(Data("\(field.utf8.count):".utf8))
            data.append(Data(field.utf8))
        }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func validateSchedule(
        _ evidence: PairGraphEvidence,
        resolvedPlan: ResolvedRunPlan,
        groups: [ColmapPairGroup]
    ) throws {
        try validate(evidence)
        guard evidence.planBinding == PairGraphPlanBinding(resolvedPlan),
              resolvedPlan.geometryBackend == .colmap,
              resolvedPlan.normalDescriptorMatcher == .faiss else {
            throw PairGraphEvidenceStoreError.invalidEvidence
        }
        for (index, attempt) in evidence.attempts.enumerated() {
            try Task.checkCancellation()
            if attempt.artifact.matcher == .exact {
                guard index > 0,
                      DescriptorMatcherRecoveryPolicy.permitsExactRecovery(
                          scheduledPairCount: attempt.scheduledPairs.count
                      ) else {
                    throw PairGraphEvidenceStoreError.invalidEvidence
                }
                let predecessor = evidence.attempts[index - 1]
                guard attempt.artifact.recoveryLevel
                        == predecessor.artifact.recoveryLevel,
                      attempt.scheduledPairs == predecessor.scheduledPairs,
                      attempt.retrieval == predecessor.retrieval else {
                    throw PairGraphEvidenceStoreError.invalidEvidence
                }
                continue
            } else if attempt.artifact.matcher != resolvedPlan.normalDescriptorMatcher {
                throw PairGraphEvidenceStoreError.invalidEvidence
            }
            let recoveryLevel = PipelineRunner.PairRecoveryLevel(
                attempt.artifact.recoveryLevel
            )
            var expected = try PipelineRunner.baseColmapPairPlan(
                imageNames: evidence.imageNames,
                groups: groups,
                resolvedPlan: resolvedPlan,
                recoveryLevel: recoveryLevel
            )
            let expectedRequest = try PipelineRunner.vocabularyRetrievalRequest(
                imageNames: evidence.imageNames,
                groups: groups,
                resolvedPlan: resolvedPlan,
                recoveryLevel: recoveryLevel
            )
            if let expectedRequest {
                guard let retrieval = attempt.retrieval,
                      retrieval.engine == resolvedPlan.retrievalEngine,
                      retrieval.queryImageNames == expectedRequest.queryImageNames,
                      retrieval.queryStride == resolvedPlan.retrievalQueryStride,
                      retrieval.candidateCount == expectedRequest.candidateCount,
                      retrieval.returnedNeighborCount == expectedRequest.returnedNeighborCount,
                      retrieval.minimumFrameSeparation == expectedRequest.minimumFrameSeparation else {
                    throw PairGraphEvidenceStoreError.invalidEvidence
                }
                let lines: [String]
                do {
                    lines = try PipelineRunner.validatedVocabularyRetrievalEvidence(
                        retrieval,
                        request: expectedRequest,
                        imageNames: evidence.imageNames,
                        excluding: expected
                    )
                } catch {
                    throw PairGraphEvidenceStoreError.invalidEvidence
                }
                expected = try expected.addingRetrievalPairLines(
                    lines,
                    pairingPolicy: resolvedPlan.pairingPolicy,
                    groups: groups,
                    requiresCrossClipRetrieval: resolvedPlan.requiresCrossClipRetrieval
                )
            } else if attempt.retrieval != nil {
                throw PairGraphEvidenceStoreError.invalidEvidence
            }
            guard expected.pairs == attempt.scheduledPairs else {
                throw PairGraphEvidenceStoreError.invalidEvidence
            }
        }
    }

    static func validateAttemptHistory(
        imageNames: [String],
        pairingPolicy: ResolvedPairingPolicy,
        attempts: [PairGraphAttemptEvidence],
        matchingDurationSeconds: Double,
        fallbackReasons: [String]
    ) throws {
        try Task.checkCancellation()
        guard !imageNames.isEmpty,
              Set(imageNames).count == imageNames.count,
              imageNames.allSatisfy({ validImageName($0) }),
              !attempts.isEmpty,
              matchingDurationSeconds.isFinite,
              matchingDurationSeconds >= 0,
              Set(fallbackReasons).count == fallbackReasons.count,
              fallbackReasons.allSatisfy({ reason in
                  let trimmed = reason.trimmingCharacters(in: .whitespacesAndNewlines)
                  return !trimmed.isEmpty && trimmed == reason && reason.utf8.count <= 512
              }) else {
            throw PairGraphEvidenceStoreError.invalidEvidence
        }

        let imageIndexByName = Dictionary(
            uniqueKeysWithValues: imageNames.enumerated().map {
                ($0.element, $0.offset)
            }
        )
        for (index, attempt) in attempts.enumerated() {
            try Task.checkCancellation()
            try validate(
                attempt,
                expectedNumber: index + 1,
                imageIndexByName: imageIndexByName
            )
        }
        try validateRecoverySequence(
            attempts,
            imageNames: imageNames,
            pairingPolicy: pairingPolicy,
            fallbackReasons: fallbackReasons
        )

        let measuredDuration = attempts.reduce(0.0) {
            $0 + $1.artifact.durationSeconds
        }
        guard measuredDuration.isFinite else {
            throw PairGraphEvidenceStoreError.invalidEvidence
        }
        let durationScale = max(
            1,
            abs(measuredDuration),
            abs(matchingDurationSeconds)
        )
        guard abs(measuredDuration - matchingDurationSeconds)
                <= durationScale * 1e-12 else {
            throw PairGraphEvidenceStoreError.invalidEvidence
        }
        try Task.checkCancellation()
    }

    private static func validate(
        _ attempt: PairGraphAttemptEvidence,
        expectedNumber: Int,
        imageIndexByName: [String: Int]
    ) throws {
        let artifact = attempt.artifact
        guard artifact.attemptNumber == expectedNumber,
              (artifact.matcher == .exact)
                == (artifact.exactRecoveryReason != nil),
              artifact.scheduledPairCount == attempt.scheduledPairs.count,
              artifact.attemptedPairCount >= 0,
              artifact.attemptedPairCount <= artifact.scheduledPairCount,
              artifact.rawMatchedPairCount >= 0,
              artifact.rawMatchedPairCount <= artifact.attemptedPairCount,
              artifact.spatiallyVerifiedPairCount >= 0,
              artifact.spatiallyVerifiedPairCount <= artifact.rawMatchedPairCount,
              artifact.durationSeconds.isFinite,
              artifact.durationSeconds >= 0 else {
            throw PairGraphEvidenceStoreError.invalidEvidence
        }

        var priorEdge: (first: Int, second: Int)?
        var edges: Set<PairEdge> = []
        for pair in attempt.scheduledPairs {
            try Task.checkCancellation()
            guard let firstIndex = imageIndexByName[pair.firstImageName],
                  let secondIndex = imageIndexByName[pair.secondImageName],
                  firstIndex < secondIndex else {
                throw PairGraphEvidenceStoreError.invalidEvidence
            }
            let edge = PairEdge(first: firstIndex, second: secondIndex)
            guard edges.insert(edge).inserted else {
                throw PairGraphEvidenceStoreError.invalidEvidence
            }
            if let priorEdge {
                guard priorEdge.first < edge.first
                        || (priorEdge.first == edge.first && priorEdge.second < edge.second) else {
                    throw PairGraphEvidenceStoreError.invalidEvidence
                }
            }
            priorEdge = (edge.first, edge.second)
        }
        if let retrieval = attempt.retrieval {
            let imageNames = imageIndexByName.sorted { lhs, rhs in
                lhs.value < rhs.value
            }.map(\.key)
            try validateRetrievalEvidence(retrieval, imageNames: imageNames)
        } else if attempt.retrievalWasExecuted {
            throw PairGraphEvidenceStoreError.invalidEvidence
        }
    }

    static func validateRetrievalEvidence(
        _ retrieval: PairGraphRetrievalAttemptEvidence,
        imageNames: [String]
    ) throws {
        try validateRetrievalContractEvidence(
            retrieval,
            imageNames: imageNames
        )
    }

    static func validateRetrievalContractEvidence(
        _ retrieval: PairGraphRetrievalAttemptEvidence,
        imageNames: [String]
    ) throws {
        let imageNameSet = Set(imageNames)
        let groupIndexByImageName = try validatedImageGroupIndices(
            retrieval,
            imageNames: imageNames
        )
        let outcomeEdges = Set(retrieval.queryOutcomes.flatMap { outcome in
            outcome.rankedNeighborImageNames.map {
                RetrievalEdge(outcome.queryImageName, $0)
            }
        })
        guard imageNameSet.count == imageNames.count,
              imageNames.allSatisfy(validImageName),
              retrieval.queryStride > 0,
              retrieval.candidateCount > 0,
              retrieval.returnedNeighborCount > 0,
              retrieval.returnedNeighborCount <= retrieval.candidateCount,
              retrieval.minimumFrameSeparation >= 0,
              !retrieval.queryImageNames.isEmpty,
              Set(retrieval.queryImageNames).count == retrieval.queryImageNames.count,
              retrieval.queryImageNames.allSatisfy(imageNameSet.contains),
              retrieval.queryOutcomes.count == retrieval.queryImageNames.count,
              retrieval.queryOutcomes.map(\.queryImageName)
                == retrieval.queryImageNames,
              retrieval.queryOutcomes.allSatisfy({ outcome in
                  let neighbors = outcome.rankedNeighborImageNames
                  return outcome.queryImageName != "."
                      && outcome.queryImageName != ".."
                      && !outcome.queryImageName.contains("/")
                      && !outcome.queryImageName.contains("\\")
                      && !outcome.queryImageName.utf8.contains(0)
                      && neighbors.count == Set(neighbors).count
                      && neighbors.allSatisfy({ neighbor in
                          imageNameSet.contains(neighbor)
                              && neighbor != outcome.queryImageName
                              && groupIndexByImageName.map { groups in
                                  groups[outcome.queryImageName]
                                      != groups[neighbor]
                              } != false
                      })
                      && neighbors == neighbors.sorted(by: canonicalUTF8Less)
                      && ((outcome.status == .ranked && !neighbors.isEmpty)
                          || (outcome.status == .noRankedNeighbors
                              && neighbors.isEmpty))
              }),
              Set(retrieval.directedPairLines).count == retrieval.directedPairLines.count,
              retrieval.directedPairLines
                == retrieval.directedPairLines.sorted(by: canonicalUTF8Less),
              retrieval.directedPairLines.allSatisfy({ line in
                  let fields = line.split(whereSeparator: \.isWhitespace)
                  guard fields.count == 2 else { return false }
                  let first = String(fields[0])
                  let second = String(fields[1])
                  return imageNameSet.contains(first)
                      && imageNameSet.contains(second)
                      && first != second
                      && outcomeEdges.contains(RetrievalEdge(first, second))
              }),
              isSHA256(retrieval.outputDigest),
              retrieval.outputDigest == retrievalOutputDigest(retrieval) else {
            throw PairGraphEvidenceStoreError.invalidEvidence
        }
    }

    private static func validatedImageGroupIndices(
        _ retrieval: PairGraphRetrievalAttemptEvidence,
        imageNames: [String]
    ) throws -> [String: Int]? {
        switch (
            retrieval.candidatePolicy,
            retrieval.imageGroupListDigest,
            retrieval.imageGroupLines
        ) {
        case (nil, nil, nil):
            return nil
        case let (.crossGroupV1?, digest?, lines?):
            guard isSHA256(digest),
                  lines.count == imageNames.count,
                  lines == lines.sorted(by: canonicalUTF8Less) else {
                throw PairGraphEvidenceStoreError.invalidEvidence
            }
            var groups: [String: Int] = [:]
            for line in lines {
                let fields = line.split(
                    separator: "\t",
                    omittingEmptySubsequences: false
                )
                guard fields.count == 2 else {
                    throw PairGraphEvidenceStoreError.invalidEvidence
                }
                let imageName = String(fields[0])
                let rawGroupIndex = String(fields[1])
                guard validImageName(imageName),
                      let groupIndex = Int(rawGroupIndex),
                      groupIndex >= 0,
                      String(groupIndex) == rawGroupIndex,
                      groups.updateValue(groupIndex, forKey: imageName) == nil else {
                    throw PairGraphEvidenceStoreError.invalidEvidence
                }
            }
            let groupIndices = Set(groups.values)
            guard Set(groups.keys) == Set(imageNames),
                  groupIndices.count >= 2,
                  groupIndices == Set(0..<groupIndices.count),
                  digest == imageGroupListDigest(
                    policy: .crossGroupV1,
                    canonicalLines: lines
                  ) else {
                throw PairGraphEvidenceStoreError.invalidEvidence
            }
            return groups
        default:
            throw PairGraphEvidenceStoreError.invalidEvidence
        }
    }

    private static func validate(
        _ inspection: PersistedColmapPairGraphInspection,
        against attempt: PairGraphAttemptEvidence,
        imageCount: Int,
        pairingPolicy: ResolvedPairingPolicy
    ) throws {
        let artifact = attempt.artifact
        let localCount = attempt.scheduledPairs.count { $0.role == .local }
        let retrievalCount = attempt.scheduledPairs.count { $0.role == .retrieval }
        let loopCount = attempt.scheduledPairs.count { $0.role == .loopRevisit }
        let descriptorlessViewCount = inspection.descriptorlessViewCount
        guard descriptorlessViewCount >= 0,
              descriptorlessViewCount < imageCount else {
            throw PairGraphEvidenceStoreError.invalidEvidence
        }
        guard let dominantViewCount = PairGraphConnectivityPolicy.dominantViewCount(
            totalViewCount: imageCount,
            componentViewCounts: inspection.componentViewCounts,
            connectedComponentCount: inspection.connectedComponentCount,
            isolatedViewCount: inspection.isolatedViewCount,
            descriptorlessViewCount: descriptorlessViewCount
        ) else {
            throw PairGraphEvidenceStoreError.invalidEvidence
        }
        let hasMinorVerifiedComponent = inspection.componentViewCounts
            .dropFirst()
            .contains { $0 > 1 }
        if hasMinorVerifiedComponent {
            guard isOrdered(pairingPolicy),
                  attempt.artifact.recoveryLevel != .normal else {
                throw PairGraphEvidenceStoreError.invalidEvidence
            }
        }
        let hasSingleBiconnectedBlock = inspection.biconnectedBlockCount == 1
        let scheduledPairs = attempt.scheduledPairs
        let scheduledPairSet = Set(scheduledPairs)
        let attemptedPairSet = Set(inspection.attemptedPairs)
        let rawMatchedPairSet = Set(inspection.rawMatchedPairs)
        let verifiedPairSet = Set(inspection.spatiallyVerifiedPairs)
        func isCanonicalSubset(_ pairs: [ColmapScheduledPair]) -> Bool {
            Set(pairs).count == pairs.count
                && Set(pairs).isSubset(of: scheduledPairSet)
                && pairs == scheduledPairs.filter(Set(pairs).contains)
        }
        guard inspection.scheduledPairCount == artifact.scheduledPairCount,
              artifact.outcome == .completed,
              inspection.attemptedPairCount == artifact.attemptedPairCount,
              inspection.rawMatchedPairCount == artifact.rawMatchedPairCount,
              inspection.spatiallyVerifiedPairCount
                  == artifact.spatiallyVerifiedPairCount,
              inspection.attemptedPairs.count == inspection.attemptedPairCount,
              inspection.rawMatchedPairs.count == inspection.rawMatchedPairCount,
              inspection.spatiallyVerifiedPairs.count
                  == inspection.spatiallyVerifiedPairCount,
              isCanonicalSubset(inspection.attemptedPairs),
              isCanonicalSubset(inspection.rawMatchedPairs),
              isCanonicalSubset(inspection.spatiallyVerifiedPairs),
              rawMatchedPairSet.isSubset(of: attemptedPairSet),
              verifiedPairSet.isSubset(of: rawMatchedPairSet),
              inspection.localPairCount == localCount,
              inspection.retrievalPairCount == retrievalCount,
              inspection.loopRevisitPairCount == loopCount,
              localCount + retrievalCount + loopCount == artifact.scheduledPairCount,
              inspection.attemptedPairCount >= 0,
              inspection.attemptedPairCount <= inspection.scheduledPairCount,
              inspection.rawMatchedPairCount >= 0,
              inspection.rawMatchedPairCount <= inspection.attemptedPairCount,
              inspection.spatiallyVerifiedPairCount >= 0,
              inspection.spatiallyVerifiedPairCount <= inspection.rawMatchedPairCount,
              dominantViewCount >= 2,
              inspection.articulationViewCount >= 0,
              inspection.articulationViewCount <= dominantViewCount - 2,
              inspection.biconnectedBlockCount >= 1,
              inspection.biconnectedBlockCount
                <= min(inspection.spatiallyVerifiedPairCount, dominantViewCount - 1),
              inspection.articulationViewCount < inspection.biconnectedBlockCount,
              inspection.largestBiconnectedBlockViewCount >= 2,
              inspection.largestBiconnectedBlockViewCount <= dominantViewCount,
              inspection.secondLargestBiconnectedBlockViewCount >= 0,
              inspection.secondLargestBiconnectedBlockViewCount
                <= inspection.largestBiconnectedBlockViewCount,
              hasSingleBiconnectedBlock
                ? inspection.articulationViewCount == 0
                    && inspection.largestBiconnectedBlockViewCount == dominantViewCount
                    && inspection.secondLargestBiconnectedBlockViewCount == 0
                : inspection.articulationViewCount > 0
                    && inspection.largestBiconnectedBlockViewCount < dominantViewCount
                    && inspection.secondLargestBiconnectedBlockViewCount >= 2,
              inspection.degreeP10 >= 0,
              inspection.degreeP10 <= inspection.degreeMedian,
              inspection.degreeMedian <= inspection.degreeP90,
              inspection.degreeP90 < imageCount else {
            throw PairGraphEvidenceStoreError.invalidEvidence
        }

        guard isSHA256(inspection.featureDatabaseDigest),
              isSHA256(inspection.matchingDatabaseDigest) else {
            throw PairGraphEvidenceStoreError.invalidEvidence
        }

        let verifiedEdges = inspection.spatiallyVerifiedPairCount
        guard verifiedEdges >= dominantViewCount - 1,
              inspection.degreeP90 <= min(dominantViewCount - 1, verifiedEdges) else {
            throw PairGraphEvidenceStoreError.invalidEvidence
        }
    }

    private static func validateRecoverySequence(
        _ attempts: [PairGraphAttemptEvidence],
        imageNames: [String],
        pairingPolicy: ResolvedPairingPolicy,
        fallbackReasons: [String]
    ) throws {
        guard let first = attempts.first,
              first.artifact.matcher == .faiss,
              recoveryLevelIndex(first.artifact.recoveryLevel)
                <= min(2, fallbackReasons.count) else {
            throw PairGraphEvidenceStoreError.invalidEvidence
        }
        var previousAttempt: PairGraphAttemptEvidence?
        var previousPlan: ColmapPairPlan?
        for attempt in attempts {
            try Task.checkCancellation()
            let plan = try ColmapPairPlan.persisted(
                imageNames: imageNames,
                scheduledPairs: attempt.scheduledPairs
            )
            if attempt.artifact.outcome != .failed {
                guard plan.isConnected,
                      attempt.artifact.attemptedPairCount
                        == attempt.artifact.scheduledPairCount else {
                    throw PairGraphEvidenceStoreError.invalidEvidence
                }
            }
            if attempt.artifact.matcher == .exact,
               !DescriptorMatcherRecoveryPolicy.permitsExactRecovery(
                   scheduledPairCount: attempt.artifact.scheduledPairCount
               ) {
                throw PairGraphEvidenceStoreError.invalidEvidence
            }
            defer {
                previousAttempt = attempt
                previousPlan = plan
            }
            guard let previousAttempt, let previousPlan else {
                continue
            }
            let previousLevel = recoveryLevelIndex(
                previousAttempt.artifact.recoveryLevel
            )
            let level = recoveryLevelIndex(attempt.artifact.recoveryLevel)
            guard level >= previousLevel,
                  level - previousLevel
                    <= min(2, max(1, fallbackReasons.count)) else {
                throw PairGraphEvidenceStoreError.invalidEvidence
            }
            if level == previousLevel {
                if attempt.artifact.matcher == previousAttempt.artifact.matcher {
                    guard attempt.artifact.matcher == .faiss,
                          previousAttempt.artifact.outcome != .completed,
                          plan == previousPlan else {
                        throw PairGraphEvidenceStoreError.invalidEvidence
                    }
                } else {
                    guard previousAttempt.artifact.matcher == .faiss,
                          attempt.artifact.matcher == .exact,
                          plan == previousPlan,
                          permitsExactMatcherTransition(
                              after: previousAttempt.artifact,
                              reason: attempt.artifact.exactRecoveryReason,
                              imageCount: imageNames.count,
                              pairingPolicy: pairingPolicy
                          ) else {
                        throw PairGraphEvidenceStoreError.invalidEvidence
                    }
                }
            } else {
                let repeatedPlanningFailure = plan == previousPlan
                    && attempt.artifact.outcome == .failed
                    && attempt.artifact.attemptedPairCount == 0
                    && attempt.artifact.rawMatchedPairCount == 0
                    && attempt.artifact.spatiallyVerifiedPairCount == 0
                guard attempt.artifact.matcher == .faiss,
                      previousAttempt.artifact.matcher == .faiss,
                      plan != previousPlan || repeatedPlanningFailure else {
                    throw PairGraphEvidenceStoreError.invalidEvidence
                }
            }
        }
    }

    static func permitsExactMatcherTransition(
        after previous: PairMatchingAttemptArtifact,
        reason: DescriptorMatcherRecoveryReason?,
        imageCount: Int,
        pairingPolicy: ResolvedPairingPolicy
    ) -> Bool {
        guard previous.matcher == .faiss,
              previous.exactRecoveryReason == nil,
              let reason,
              DescriptorMatcherRecoveryPolicy.permitsExactRecovery(
                  scheduledPairCount: previous.scheduledPairCount
              ) else { return false }

        switch reason {
        case .faissCrash, .faissUnsupportedOperation:
            return previous.outcome == .failed
        case .faissGeometryRejectedAfterRetries:
            guard previous.outcome == .rejected else { return false }
            if previous.recoveryLevel == .maximum { return true }
            guard previous.recoveryLevel == .normal,
                  pairingPolicy == .unorderedRetrieval,
                  imageCount >= 2,
                  imageCount <= 60 else {
                return false
            }
            let product = imageCount.multipliedReportingOverflow(by: imageCount - 1)
            guard !product.overflow else { return false }
            return previous.scheduledPairCount == product.partialValue / 2
        }
    }

    private static func recoveryLevelIndex(_ level: PairGraphRecoveryLevel) -> Int {
        switch level {
        case .normal: return 0
        case .expanded: return 1
        case .maximum: return 2
        }
    }

    static func retrievalIsRequired(
        pairingPolicy: ResolvedPairingPolicy,
        imageCount: Int,
        recoveryLevel: PairGraphRecoveryLevel,
        requiresCrossClipRetrieval: Bool = false
    ) -> Bool {
        if recoveryLevel == .maximum, imageCount <= 250 {
            return false
        }
        if pairingPolicy == .unorderedRetrieval, imageCount <= 60 {
            return false
        }
        return PairGraphRetrievalScheduling.isRequired(
            pairingPolicy: pairingPolicy,
            selectedFrameCount: imageCount,
            requiresCrossClipRetrieval: requiresCrossClipRetrieval
        )
    }

    private static func isOrdered(_ policy: ResolvedPairingPolicy) -> Bool {
        switch policy {
        case .orderedContinuous,
             .orderedOrbit,
             .orderedWalkthrough,
             .orderedLargeArea:
            return true
        case .unorderedRetrieval, .segmentedMixed:
            return false
        }
    }

    private static func validateLocation(_ url: URL, projectPaths: ProjectPaths) throws {
        let expected: URL
        do {
            expected = try projectPaths.validateReservedProjectPath(
                url,
                relativePath: "SfM/pair_graph_evidence.json"
            )
        } catch {
            throw PairGraphEvidenceStoreError.invalidLocation
        }
        let parentValues = try expected.deletingLastPathComponent().resourceValues(
            forKeys: [.isDirectoryKey, .isSymbolicLinkKey]
        )
        guard parentValues.isDirectory == true,
              parentValues.isSymbolicLink != true else {
            throw PairGraphEvidenceStoreError.invalidLocation
        }
    }

    private static func validImageName(_ name: String) -> Bool {
        !name.isEmpty
            && name != "."
            && name != ".."
            && !name.contains("/")
            && !name.contains("\\")
            && !name.contains(where: \.isWhitespace)
            && !name.utf8.contains(0)
    }

    private static func isSHA256(_ value: String) -> Bool {
        value.count == 64 && value.utf8.allSatisfy { byte in
            (48...57).contains(byte) || (97...102).contains(byte)
        }
    }

    static func canonicalUTF8Less(_ lhs: String, _ rhs: String) -> Bool {
        lhs.utf8.lexicographicallyPrecedes(rhs.utf8)
    }

    private struct PairEdge: Hashable {
        let first: Int
        let second: Int
    }

    private struct RetrievalEdge: Hashable {
        let first: String
        let second: String

        init(_ lhs: String, _ rhs: String) {
            if canonicalUTF8Less(lhs, rhs) {
                first = lhs
                second = rhs
            } else {
                first = rhs
                second = lhs
            }
        }
    }

    private struct SchemaEnvelope: Decodable {
        let schemaVersion: Int
    }
}

enum PairGraphEvidenceStoreError: Error, LocalizedError, Equatable {
    case invalidLocation
    case invalidSchema(Int)
    case invalidEvidence

    var errorDescription: String? {
        switch self {
        case .invalidLocation:
            return "Pair-graph evidence must stay at its canonical project path."
        case .invalidSchema(let schema):
            return "Unsupported pair-graph evidence schema \(schema)."
        case .invalidEvidence:
            return "Pair-graph evidence is incomplete or inconsistent."
        }
    }
}
