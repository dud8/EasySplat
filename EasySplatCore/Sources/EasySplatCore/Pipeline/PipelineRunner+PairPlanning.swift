import Foundation

extension PipelineRunner {
    enum PairAttemptMode: Sendable, Equatable {
        case policy
        case sameScheduleExact(ColmapPairPlan)
        case targetedExact(plan: ColmapPairPlan, source: ColmapPairPlan)
        case fullExact(source: ColmapPairPlan)

        var planOverride: ColmapPairPlan? {
            switch self {
            case .policy:
                nil
            case .sameScheduleExact(let plan):
                plan
            case .targetedExact(let plan, _):
                plan
            case .fullExact(let source):
                source
            }
        }

        var evidencePurpose: PairGraphAttemptPurpose {
            switch self {
            case .policy, .sameScheduleExact:
                .policy
            case .targetedExact:
                .targetedExactGraphRecovery
            case .fullExact:
                .fullExactGraphRecovery
            }
        }

        var sourcePlan: ColmapPairPlan? {
            switch self {
            case .targetedExact(_, let source), .fullExact(let source):
                source
            case .policy, .sameScheduleExact:
                nil
            }
        }
    }

    enum PairRecoveryLevel: Int, Sendable {
        case normal
        case expanded
        case maximum

        var artifactValue: PairGraphRecoveryLevel {
            switch self {
            case .normal: .normal
            case .expanded: .expanded
            case .maximum: .maximum
            }
        }

        init(_ artifactValue: PairGraphRecoveryLevel) {
            switch artifactValue {
            case .normal: self = .normal
            case .expanded: self = .expanded
            case .maximum: self = .maximum
            }
        }
    }

    struct VocabularyRetrievalRequest: Sendable, Equatable {
        let queryImageNames: [String]
        let candidateCount: Int
        let returnedNeighborCount: Int
        let minimumFrameSeparation: Int
    }

    enum PairPolicyError: Error, Equatable {
        case invalidSelectedFrameManifest
        case invalidRetrievalOutput
    }

    static func shouldEscalateTargetedExact(after error: Error?) -> Bool {
        guard let error = error as? PipelineError else { return false }
        switch error {
        case .lowQualityReconstruction,
             .geometryCoverageTooLow,
             .geometryResidualCoverageTooLow,
             .geometryRegisteredImagesMismatch,
             .geometryResidualsUnavailable,
             .geometryResidualsTooHigh,
             .outputMissing:
            return true
        case .invalidInput,
             .insufficientInputImages,
             .geometryProvenanceUnavailable,
             .videoFrameBudgetTooSmall,
             .photoSelectionExceedsBudget,
             .imageTranscodeFailed:
            return false
        }
    }

    static func nextPairRecoveryLevel(
        after current: PairRecoveryLevel,
        imageCount: Int,
        pairingPolicy: ResolvedPairingPolicy
    ) -> PairRecoveryLevel? {
        guard current != .maximum else { return nil }
        if current == .normal,
           pairingPolicy == .unorderedRetrieval,
           imageCount <= 60 {
            return nil
        }
        return PairRecoveryLevel(rawValue: current.rawValue + 1)
    }

    static func durationInSeconds(_ duration: Duration) -> TimeInterval {
        max(
            0,
            TimeInterval(duration.components.seconds)
                + TimeInterval(duration.components.attoseconds) / 1e18
        )
    }

    static func colmapPairGroups(
        imageNames: [String],
        manifest: [SelectedFrameMapping]
    ) throws -> [ColmapPairGroup] {
        guard imageNames.count == manifest.count,
              Set(imageNames).count == imageNames.count else {
            throw PairPolicyError.invalidSelectedFrameManifest
        }
        let mappingByName = Dictionary(grouping: manifest, by: \.outputFileName)
        guard mappingByName.count == manifest.count,
              Set(mappingByName.keys) == Set(imageNames) else {
            throw PairPolicyError.invalidSelectedFrameManifest
        }

        var groupOrder: [String] = []
        var framesByGroup: [String: [String]] = [:]
        var videoFlagByGroup: [String: Bool] = [:]
        var lastTimestampByVideoGroup: [String: Double] = [:]
        for imageName in imageNames {
            guard let entries = mappingByName[imageName], entries.count == 1,
                  let entry = entries.first,
                  !entry.groupId.isEmpty else {
                throw PairPolicyError.invalidSelectedFrameManifest
            }
            if let existing = videoFlagByGroup[entry.groupId], existing != entry.isVideo {
                throw PairPolicyError.invalidSelectedFrameManifest
            }
            if entry.isVideo {
                guard let timestamp = entry.timestampSeconds,
                      timestamp.isFinite,
                      timestamp >= 0,
                      lastTimestampByVideoGroup[entry.groupId]
                        .map({ timestamp > $0 }) ?? true else {
                    throw PairPolicyError.invalidSelectedFrameManifest
                }
                lastTimestampByVideoGroup[entry.groupId] = timestamp
            } else if entry.timestampSeconds != nil {
                throw PairPolicyError.invalidSelectedFrameManifest
            }
            if videoFlagByGroup[entry.groupId] == nil {
                groupOrder.append(entry.groupId)
                videoFlagByGroup[entry.groupId] = entry.isVideo
            }
            framesByGroup[entry.groupId, default: []].append(imageName)
        }
        return try groupOrder.map { groupID in
            guard let frames = framesByGroup[groupID],
                  let isVideo = videoFlagByGroup[groupID],
                  !frames.isEmpty else {
                throw PairPolicyError.invalidSelectedFrameManifest
            }
            return ColmapPairGroup(imageNames: frames, isVideo: isVideo)
        }
    }

    static func baseColmapPairPlan(
        imageNames: [String],
        groups: [ColmapPairGroup],
        resolvedPlan: ResolvedRunPlan,
        recoveryLevel: PairRecoveryLevel
    ) throws -> ColmapPairPlan {
        if usesExhaustivePairing(
            imageCount: imageNames.count,
            pairingPolicy: resolvedPlan.pairingPolicy,
            recoveryLevel: recoveryLevel
        ) {
            return try ColmapPairPlan.exhaustive(imageNames: imageNames)
        }

        switch resolvedPlan.temporalPairing {
        case .none:
            return try ColmapPairPlan.empty(imageNames: imageNames)
        case .linear, .multiscale:
            var offsets = resolvedPlan.temporalOffsets
            if recoveryLevel != .normal,
               resolvedPlan.pairingPolicy != .segmentedMixed {
                offsets = Array(Set(offsets).union(1...12)).sorted()
            }
            let temporalGroups: [ColmapPairGroup]
            if resolvedPlan.pairingPolicy == .segmentedMixed {
                temporalGroups = groups
            } else {
                temporalGroups = groups.map {
                    ColmapPairGroup(imageNames: $0.imageNames, isVideo: true)
                }
            }
            return try ColmapPairPlan.temporal(
                groups: temporalGroups,
                offsets: offsets
            )
        }
    }

    static func vocabularyRetrievalRequest(
        imageNames: [String],
        resolvedPlan: ResolvedRunPlan,
        recoveryLevel: PairRecoveryLevel
    ) -> VocabularyRetrievalRequest? {
        guard !usesExhaustivePairing(
            imageCount: imageNames.count,
            pairingPolicy: resolvedPlan.pairingPolicy,
            recoveryLevel: recoveryLevel
        ) else {
            return nil
        }

        let shouldRetrieve: Bool
        switch resolvedPlan.pairingPolicy {
        case .orderedContinuous:
            shouldRetrieve = imageNames.count >= 120
        case .orderedOrbit, .orderedWalkthrough, .orderedLargeArea, .segmentedMixed:
            shouldRetrieve = true
        case .unorderedRetrieval:
            shouldRetrieve = imageNames.count > 60
        }
        guard shouldRetrieve else { return nil }

        let candidateCount: Int
        let neighborCount: Int
        switch recoveryLevel {
        case .normal:
            candidateCount = resolvedPlan.retrievalCandidateCount
            neighborCount = resolvedPlan.retrievalNeighborCount
        case .expanded:
            switch resolvedPlan.pairingPolicy {
            case .unorderedRetrieval, .segmentedMixed:
                candidateCount = 40
                neighborCount = 16
            case .orderedContinuous, .orderedOrbit, .orderedWalkthrough, .orderedLargeArea:
                candidateCount = resolvedPlan.retrievalCandidateCount
                neighborCount = resolvedPlan.retrievalNeighborCount
            }
        case .maximum:
            candidateCount = 80
            neighborCount = 32
        }
        let stride = max(1, resolvedPlan.retrievalQueryStride)
        let queryNames = Swift.stride(from: 0, to: imageNames.count, by: stride).map {
            imageNames[$0]
        }
        let minimumSeparation: Int
        switch resolvedPlan.pairingPolicy {
        case .orderedContinuous, .orderedOrbit, .orderedWalkthrough, .orderedLargeArea:
            minimumSeparation = max(12, imageNames.count / 10)
        case .segmentedMixed, .unorderedRetrieval:
            minimumSeparation = 0
        }
        return VocabularyRetrievalRequest(
            queryImageNames: queryNames,
            candidateCount: candidateCount,
            returnedNeighborCount: neighborCount,
            minimumFrameSeparation: minimumSeparation
        )
    }

    static func validatedVocabularyRetrievalPairLines(
        _ lines: [String],
        request: VocabularyRetrievalRequest,
        imageNames: [String],
        excluding basePlan: ColmapPairPlan
    ) throws -> [String] {
        guard Set(imageNames).count == imageNames.count,
              Set(request.queryImageNames).count == request.queryImageNames.count,
              request.returnedNeighborCount > 0,
              request.minimumFrameSeparation >= 0 else {
            throw PairPolicyError.invalidRetrievalOutput
        }
        let imageIndex = Dictionary(
            uniqueKeysWithValues: imageNames.enumerated().map { ($0.element, $0.offset) }
        )
        let queryNames = Set(request.queryImageNames)
        guard queryNames.isSubset(of: Set(imageNames)) else {
            throw PairPolicyError.invalidRetrievalOutput
        }
        let excludedEdges = Set(basePlan.pairs.map {
            RetrievalEdge($0.firstImageName, $0.secondImageName)
        })
        let maximumTotal = request.queryImageNames.count * request.returnedNeighborCount
        guard lines.count <= maximumTotal else {
            throw PairPolicyError.invalidRetrievalOutput
        }

        var countsByQuery: [String: Int] = [:]
        var seenEdges: Set<RetrievalEdge> = []
        var validated: [String] = []
        for line in lines {
            let fields = line.split(whereSeparator: \.isWhitespace).map(String.init)
            guard fields.count == 2 else {
                throw PairPolicyError.invalidRetrievalOutput
            }
            let query = fields[0]
            let candidate = fields[1]
            guard queryNames.contains(query),
                  query != candidate,
                  let queryIndex = imageIndex[query],
                  let candidateIndex = imageIndex[candidate],
                  abs(queryIndex - candidateIndex) >= request.minimumFrameSeparation else {
                throw PairPolicyError.invalidRetrievalOutput
            }
            let edge = RetrievalEdge(query, candidate)
            guard !excludedEdges.contains(edge), seenEdges.insert(edge).inserted else {
                throw PairPolicyError.invalidRetrievalOutput
            }
            countsByQuery[query, default: 0] += 1
            guard countsByQuery[query, default: 0] <= request.returnedNeighborCount else {
                throw PairPolicyError.invalidRetrievalOutput
            }
            validated.append("\(query) \(candidate)")
        }
        return validated
    }

    private static func usesExhaustivePairing(
        imageCount: Int,
        pairingPolicy: ResolvedPairingPolicy,
        recoveryLevel: PairRecoveryLevel
    ) -> Bool {
        if recoveryLevel == .maximum, imageCount <= 250 {
            return true
        }
        return pairingPolicy == .unorderedRetrieval && imageCount <= 60
    }

    private struct RetrievalEdge: Hashable {
        let first: String
        let second: String

        init(_ first: String, _ second: String) {
            if first < second {
                self.first = first
                self.second = second
            } else {
                self.first = second
                self.second = first
            }
        }
    }
}
