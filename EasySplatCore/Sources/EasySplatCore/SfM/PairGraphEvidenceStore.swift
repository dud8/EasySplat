import CryptoKit
import Foundation

struct PairGraphAttemptEvidence: Codable, Sendable, Equatable {
    var artifact: PairMatchingAttemptArtifact
    var scheduledPairs: [ColmapScheduledPair]

    init(
        artifact: PairMatchingAttemptArtifact,
        scheduledPairs: [ColmapScheduledPair]
    ) {
        self.artifact = artifact
        self.scheduledPairs = scheduledPairs
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
    }
}

struct PairGraphEvidence: Codable, Sendable, Equatable {
    static let currentSchemaVersion = 6

    var schemaVersion: Int
    var selectedFramesDigest: String
    var imageNames: [String]
    var pairingPolicy: ResolvedPairingPolicy
    var attempts: [PairGraphAttemptEvidence]
    var acceptedAttemptNumber: Int
    var acceptedInspection: PersistedColmapPairGraphInspection
    var pairListDigest: String
    var matchingDurationSeconds: Double
    var fallbackReasons: [String]

    init(
        selectedFramesDigest: String,
        imageNames: [String],
        pairingPolicy: ResolvedPairingPolicy = .orderedContinuous,
        attempts: [PairGraphAttemptEvidence],
        acceptedAttemptNumber: Int,
        acceptedInspection: ColmapPairGraphInspection,
        matchingDurationSeconds: Double,
        fallbackReasons: [String]
    ) {
        schemaVersion = Self.currentSchemaVersion
        self.selectedFramesDigest = selectedFramesDigest
        self.imageNames = imageNames
        self.pairingPolicy = pairingPolicy
        self.attempts = attempts
        self.acceptedAttemptNumber = acceptedAttemptNumber
        self.acceptedInspection = PersistedColmapPairGraphInspection(acceptedInspection)
        pairListDigest = Self.digest(of: attempts.last?.scheduledPairs ?? [])
        self.matchingDurationSeconds = matchingDurationSeconds
        self.fallbackReasons = fallbackReasons
    }

    func pairGraphMeasurement() throws -> PairGraphMeasurement {
        try PairGraphEvidenceStore.validate(self)
        return PairGraphMeasurement(
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
        .measured(try pairGraphMeasurement())
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

    fileprivate static func digest(of pairs: [ColmapScheduledPair]) -> String {
        let data = pairs.isEmpty
            ? Data()
            : Data((pairs.map(\.line).joined(separator: "\n") + "\n").utf8)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

enum PairGraphEvidenceStore {
    static let maximumBytes = 64 * 1_024 * 1_024

    static func load(from url: URL, projectPaths: ProjectPaths) throws -> PairGraphEvidence {
        try validateLocation(url, projectPaths: projectPaths)
        let data = try BoundedFileReader.readRegularFile(
            at: url,
            maximumBytes: maximumBytes
        )
        guard !data.isEmpty else { throw PairGraphEvidenceStoreError.invalidEvidence }
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
        try validate(evidence)
        return evidence
    }

    static func loadVerified(
        from url: URL,
        expectedImageNames: [String],
        databaseURL: URL,
        projectPaths: ProjectPaths
    ) throws -> PairGraphEvidence {
        try Task.checkCancellation()
        let evidence = try loadBound(
            from: url,
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
        let evidence = try load(from: url, projectPaths: projectPaths)
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
        guard isSHA256(evidence.selectedFramesDigest),
              evidence.acceptedAttemptNumber == evidence.attempts.count else {
            throw PairGraphEvidenceStoreError.invalidEvidence
        }
        try validateAttemptHistory(
            imageNames: evidence.imageNames,
            pairingPolicy: evidence.pairingPolicy,
            attempts: evidence.attempts,
            matchingDurationSeconds: evidence.matchingDurationSeconds,
            fallbackReasons: evidence.fallbackReasons
        )

        guard let acceptedAttempt = evidence.attempts.last,
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
            pairingPolicy: pairingPolicy
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
        guard inspection.scheduledPairCount == artifact.scheduledPairCount,
              artifact.outcome == .completed,
              inspection.attemptedPairCount == artifact.attemptedPairCount,
              inspection.rawMatchedPairCount == artifact.rawMatchedPairCount,
              inspection.spatiallyVerifiedPairCount
                  == artifact.spatiallyVerifiedPairCount,
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
        pairingPolicy: ResolvedPairingPolicy
    ) throws {
        guard let first = attempts.first,
              first.artifact.matcher == .faiss,
              first.artifact.recoveryLevel == .normal else {
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
            guard attempt.artifact.outcome != .completed || plan.isConnected else {
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
                  level - previousLevel <= 1 else {
                throw PairGraphEvidenceStoreError.invalidEvidence
            }
            if level == previousLevel {
                if attempt.artifact.matcher == previousAttempt.artifact.matcher {
                    guard previousAttempt.artifact.outcome == .failed,
                          plan == previousPlan else {
                        throw PairGraphEvidenceStoreError.invalidEvidence
                    }
                } else {
                    guard previousAttempt.artifact.matcher == .faiss,
                          attempt.artifact.matcher == .exact,
                          plan == previousPlan,
                          permitsExactMatcherTransition(
                              after: previousAttempt.artifact,
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
                guard attempt.artifact.matcher == previousAttempt.artifact.matcher,
                      plan != previousPlan || repeatedPlanningFailure else {
                    throw PairGraphEvidenceStoreError.invalidEvidence
                }
            }
        }
    }

    static func permitsExactMatcherTransition(
        after previous: PairMatchingAttemptArtifact,
        imageCount: Int,
        pairingPolicy: ResolvedPairingPolicy
    ) -> Bool {
        guard previous.matcher == .faiss else { return false }
        if previous.outcome == .failed { return true }
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

    private static func recoveryLevelIndex(_ level: PairGraphRecoveryLevel) -> Int {
        switch level {
        case .normal: return 0
        case .expanded: return 1
        case .maximum: return 2
        }
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
        !name.isEmpty && !name.contains(where: \.isWhitespace)
    }

    private static func isSHA256(_ value: String) -> Bool {
        value.count == 64 && value.utf8.allSatisfy { byte in
            (48...57).contains(byte) || (97...102).contains(byte)
        }
    }

    private struct PairEdge: Hashable {
        let first: Int
        let second: Int
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
