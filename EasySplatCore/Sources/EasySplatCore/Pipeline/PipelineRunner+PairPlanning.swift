import Foundation

extension PipelineRunner {
    enum PairAttemptMode: Sendable, Equatable {
        case policy
        case restoredPolicy(ColmapPairPlan)
        case sameScheduleExact(
            ColmapPairPlan,
            DescriptorMatcherRecoveryReason
        )

        var planOverride: ColmapPairPlan? {
            switch self {
            case .policy:
                nil
            case .restoredPolicy(let plan), .sameScheduleExact(let plan, _):
                plan
            }
        }

        var exactRecoveryReason: DescriptorMatcherRecoveryReason? {
            switch self {
            case .policy, .restoredPolicy:
                nil
            case .sameScheduleExact(_, let reason):
                reason
            }
        }

        var isPolicyRecovery: Bool {
            switch self {
            case .policy, .restoredPolicy:
                true
            case .sameScheduleExact:
                false
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
        let imageGroupContract: VocabularyRetrievalImageGroupContract?

        init(
            queryImageNames: [String],
            candidateCount: Int,
            returnedNeighborCount: Int,
            minimumFrameSeparation: Int,
            imageGroupContract: VocabularyRetrievalImageGroupContract? = nil
        ) {
            self.queryImageNames = queryImageNames
            self.candidateCount = candidateCount
            self.returnedNeighborCount = returnedNeighborCount
            self.minimumFrameSeparation = minimumFrameSeparation
            self.imageGroupContract = imageGroupContract
        }
    }

    struct VocabularyRetrievalImageGroupContract: Sendable, Equatable {
        let policy: PairGraphRetrievalCandidatePolicy
        let digest: String
        let canonicalLines: [String]
        let groupIndexByImageName: [String: Int]

        var serializedData: Data {
            Data((canonicalLines.joined(separator: "\n") + "\n").utf8)
        }

        func groupIndex(for imageName: String) -> Int? {
            groupIndexByImageName[imageName]
        }
    }

    enum PairPolicyError: Error, Equatable {
        case invalidSelectedFrameManifest
        case invalidRetrievalOutput
    }

    static func dominantComponentContinuationLine(
        componentViewCounts: [Int],
        selectedViewCount: Int
    ) -> String {
        let dominantViewCount = componentViewCounts.first ?? 0
        let excludedViewCount = selectedViewCount - dominantViewCount
        let secondGroupViewCount = componentViewCounts.dropFirst().first ?? 0
        var line = "Matching could not connect every photo. Continuing with the largest connected group: \(dominantViewCount) of \(selectedViewCount) photos. \(excludedViewCount) photo\(excludedViewCount == 1 ? " stays" : "s stay") out of the splat."
        if secondGroupViewCount > 1 {
            line += " The largest separate group has \(secondGroupViewCount) photos."
        }
        return line
    }

    static func allowsMinorVerifiedComponents(
        pairingPolicy: ResolvedPairingPolicy,
        recoveryLevel: PairRecoveryLevel
    ) -> Bool {
        guard recoveryLevel != .normal else { return false }
        switch pairingPolicy {
        case .orderedContinuous,
             .orderedOrbit,
             .orderedWalkthrough,
             .orderedLargeArea:
            return true
        case .unorderedRetrieval, .segmentedMixed:
            return false
        }
    }

    static func permitsAcceptedComponentShape(
        _ componentViewCounts: [Int],
        pairingPolicy: ResolvedPairingPolicy,
        recoveryLevel: PairRecoveryLevel
    ) -> Bool {
        let hasMinorVerifiedComponent = componentViewCounts.dropFirst().contains { $0 > 1 }
        return !hasMinorVerifiedComponent || allowsMinorVerifiedComponents(
            pairingPolicy: pairingPolicy,
            recoveryLevel: recoveryLevel
        )
    }

    static func shouldRecoverPairGraph(after error: Error?) -> Bool {
        guard let error = error as? PipelineError else { return false }
        switch error {
        case .geometryConditioningRejected(let failure):
            switch failure {
            case .insufficientViewSupport,
                 .collapsedCameraTrajectory,
                 .insufficientParallax,
                 .degeneratePointDistribution:
                return true
            case .insufficientDistinctTrackViews,
                 .rayPairWorkLimitExceeded:
                return false
            }
        case .lowQualityReconstruction,
             .fragmentedReconstruction,
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
             .geometryCameraModelMismatch,
             .videoFrameBudgetTooSmall,
             .photoSelectionExceedsBudget,
             .incompatibleSharedCameraDimensions,
             .imageTranscodeFailed:
            return false
        }
    }

    static func mappingCadenceFallbackTrigger(
        after error: Error?
    ) -> MappingCadenceFallbackTrigger? {
        guard let error = error as? PipelineError else { return nil }
        switch error {
        case .geometryConditioningRejected(let failure):
            switch failure {
            case .insufficientViewSupport:
                return .insufficientViewSupport
            case .collapsedCameraTrajectory:
                return .collapsedCameraTrajectory
            case .insufficientParallax:
                return .insufficientParallax
            case .degeneratePointDistribution:
                return .degeneratePointDistribution
            case .insufficientDistinctTrackViews,
                 .rayPairWorkLimitExceeded:
                return nil
            }
        case .lowQualityReconstruction:
            return .lowReconstructionQuality
        case .fragmentedReconstruction:
            return .fragmentedReconstruction
        case .geometryCoverageTooLow:
            return .lowRegisteredViewCoverage
        case .geometryResidualCoverageTooLow:
            return .sparseResidualCoverage
        case .geometryResidualsTooHigh:
            return .excessiveResiduals
        case .invalidInput,
             .insufficientInputImages,
             .geometryRegisteredImagesMismatch,
             .geometryResidualsUnavailable,
             .geometryProvenanceUnavailable,
             .geometryCameraModelMismatch,
             .videoFrameBudgetTooSmall,
             .photoSelectionExceedsBudget,
             .incompatibleSharedCameraDimensions,
             .imageTranscodeFailed,
             .outputMissing:
            return nil
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

    static func colmapCameraGroupingEvidence(
        imageNames: [String],
        manifest: [SelectedFrameMapping]
    ) throws -> [ColmapSelectedImageCameraEvidence] {
        _ = try colmapPairGroups(imageNames: imageNames, manifest: manifest)
        let mappingByName = Dictionary(
            uniqueKeysWithValues: manifest.map { ($0.outputFileName, $0) }
        )
        return try imageNames.map { imageName in
            guard let mapping = mappingByName[imageName] else {
                throw PairPolicyError.invalidSelectedFrameManifest
            }
            return ColmapSelectedImageCameraEvidence(
                imageName: imageName,
                sourceGroupID: mapping.groupId,
                isVideo: mapping.isVideo
            )
        }
    }

    static func colmapCameraGroupingMode(
        cameraGrouping: CameraGrouping,
        evidence: [ColmapSelectedImageCameraEvidence]
    ) -> ColmapCameraGroupingMode {
        if cameraGrouping == .sameCameraAndLens {
            return .allSelectedImagesShared
        }
        return evidence.contains(where: \.isVideo)
            ? .videoSourceGroups
            : .preserveExisting
    }

    static func baseColmapPairPlan(
        imageNames: [String],
        groups: [ColmapPairGroup],
        resolvedPlan: ResolvedRunPlan,
        recoveryLevel: PairRecoveryLevel
    ) throws -> ColmapPairPlan {
        try baseColmapPairPlan(
            imageNames: imageNames,
            groups: groups,
            planBinding: PairGraphPlanBinding(resolvedPlan),
            recoveryLevel: recoveryLevel
        )
    }

    static func baseColmapPairPlan(
        imageNames: [String],
        groups: [ColmapPairGroup],
        planBinding: PairGraphPlanBinding,
        recoveryLevel: PairRecoveryLevel
    ) throws -> ColmapPairPlan {
        if usesExhaustivePairing(
            imageCount: imageNames.count,
            pairingPolicy: planBinding.pairingPolicy,
            recoveryLevel: recoveryLevel
        ) {
            return try ColmapPairPlan.exhaustive(imageNames: imageNames)
        }

        switch planBinding.temporalPairing {
        case .none:
            return try ColmapPairPlan.empty(imageNames: imageNames)
        case .linear, .multiscale:
            var offsets = planBinding.temporalOffsets
            if recoveryLevel != .normal,
               planBinding.pairingPolicy != .segmentedMixed {
                offsets = Array(Set(offsets).union(1...12)).sorted()
            }
            let temporalGroups: [ColmapPairGroup]
            if planBinding.pairingPolicy == .segmentedMixed {
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
        groups: [ColmapPairGroup],
        resolvedPlan: ResolvedRunPlan,
        recoveryLevel: PairRecoveryLevel
    ) throws -> VocabularyRetrievalRequest? {
        guard !usesExhaustivePairing(
            imageCount: imageNames.count,
            pairingPolicy: resolvedPlan.pairingPolicy,
            recoveryLevel: recoveryLevel
        ) else {
            return nil
        }

        guard PairGraphRetrievalScheduling.isRequired(
            pairingPolicy: resolvedPlan.pairingPolicy,
            selectedFrameCount: imageNames.count,
            requiresCrossClipRetrieval: resolvedPlan.requiresCrossClipRetrieval
        ) else { return nil }

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
        let queryNames = try vocabularyRetrievalQueryImageNames(
            imageNames: imageNames,
            groups: groups,
            queryStride: stride,
            requiresCrossClipRetrieval: resolvedPlan.requiresCrossClipRetrieval
        )
        let minimumSeparation: Int
        switch (resolvedPlan.requiresCrossClipRetrieval, resolvedPlan.pairingPolicy) {
        case (true, _):
            minimumSeparation = 0
        case (false, .orderedContinuous), (false, .orderedOrbit),
             (false, .orderedWalkthrough), (false, .orderedLargeArea):
            minimumSeparation = max(12, imageNames.count / 10)
        case (false, .segmentedMixed), (false, .unorderedRetrieval):
            minimumSeparation = 0
        }
        return VocabularyRetrievalRequest(
            queryImageNames: queryNames,
            candidateCount: candidateCount,
            returnedNeighborCount: neighborCount,
            minimumFrameSeparation: minimumSeparation,
            imageGroupContract: try vocabularyRetrievalImageGroupContract(
                imageNames: imageNames,
                groups: groups,
                requiresCrossClipRetrieval: resolvedPlan.requiresCrossClipRetrieval
            )
        )
    }

    static func vocabularyRetrievalImageGroupContract(
        imageNames: [String],
        groups: [ColmapPairGroup],
        requiresCrossClipRetrieval: Bool
    ) throws -> VocabularyRetrievalImageGroupContract? {
        guard requiresCrossClipRetrieval else { return nil }
        guard groups.count >= 2,
              groups.allSatisfy({ $0.isVideo && !$0.imageNames.isEmpty }),
              groups.flatMap(\.imageNames) == imageNames,
              Set(imageNames).count == imageNames.count else {
            throw PairPolicyError.invalidSelectedFrameManifest
        }
        var groupIndexByImageName: [String: Int] = [:]
        for (groupIndex, group) in groups.enumerated() {
            for imageName in group.imageNames {
                guard !imageName.isEmpty,
                      !imageName.contains(where: \.isWhitespace),
                      groupIndexByImageName.updateValue(
                          groupIndex,
                          forKey: imageName
                      ) == nil else {
                    throw PairPolicyError.invalidSelectedFrameManifest
                }
            }
        }
        guard groupIndexByImageName.count == imageNames.count else {
            throw PairPolicyError.invalidSelectedFrameManifest
        }
        let canonicalLines = try imageNames
            .sorted(by: PairGraphEvidenceStore.canonicalUTF8Less)
            .map { imageName -> String in
                guard let groupIndex = groupIndexByImageName[imageName] else {
                    throw PairPolicyError.invalidSelectedFrameManifest
                }
                return "\(imageName)\t\(groupIndex)"
            }
        let policy = PairGraphRetrievalCandidatePolicy.crossGroupV1
        return VocabularyRetrievalImageGroupContract(
            policy: policy,
            digest: PairGraphEvidenceStore.imageGroupListDigest(
                policy: policy,
                canonicalLines: canonicalLines
            ),
            canonicalLines: canonicalLines,
            groupIndexByImageName: groupIndexByImageName
        )
    }

    static func vocabularyRetrievalQueryImageNames(
        imageNames: [String],
        groups: [ColmapPairGroup],
        queryStride: Int,
        requiresCrossClipRetrieval: Bool
    ) throws -> [String] {
        guard queryStride > 0 else {
            throw PairPolicyError.invalidSelectedFrameManifest
        }
        guard requiresCrossClipRetrieval else {
            return Swift.stride(from: 0, to: imageNames.count, by: queryStride).map {
                imageNames[$0]
            }
        }
        guard groups.count > 1,
              groups.allSatisfy({ $0.isVideo && !$0.imageNames.isEmpty }),
              groups.flatMap(\.imageNames) == imageNames else {
            throw PairPolicyError.invalidSelectedFrameManifest
        }
        return groups.flatMap { group in
            Swift.stride(from: 0, to: group.imageNames.count, by: queryStride).map {
                group.imageNames[$0]
            }
        }
    }

    static func validatedVocabularyRetrievalContract(
        _ lines: [String],
        engine: RetrievalEngine,
        queryStride: Int,
        request: VocabularyRetrievalRequest,
        imageNames: [String],
        excluding basePlan: ColmapPairPlan
    ) throws -> PairGraphRetrievalAttemptEvidence {
        guard Set(imageNames).count == imageNames.count,
              Set(request.queryImageNames).count == request.queryImageNames.count,
              queryStride > 0,
              request.candidateCount > 0,
              request.returnedNeighborCount > 0,
              request.returnedNeighborCount <= request.candidateCount,
              request.minimumFrameSeparation >= 0 else {
            throw PairPolicyError.invalidRetrievalOutput
        }
        let requestDigest = PairGraphEvidenceStore.retrievalRequestDigest(
            engine: engine,
            queryImageNames: request.queryImageNames,
            queryStride: queryStride,
            candidateCount: request.candidateCount,
            returnedNeighborCount: request.returnedNeighborCount,
            minimumFrameSeparation: request.minimumFrameSeparation,
            candidatePolicy: request.imageGroupContract?.policy,
            imageGroupListDigest: request.imageGroupContract?.digest
        )
        var expectedHeaderFields = [
            request.imageGroupContract == nil
                ? "EASYSPLAT_RETRIEVAL_OUTCOMES_V2"
                : "EASYSPLAT_RETRIEVAL_OUTCOMES_V3",
            engine.rawValue,
            String(queryStride),
            String(request.candidateCount),
            String(request.returnedNeighborCount),
            String(request.minimumFrameSeparation),
        ]
        if let groupContract = request.imageGroupContract {
            expectedHeaderFields.append(groupContract.policy.rawValue)
            expectedHeaderFields.append(groupContract.digest)
        }
        expectedHeaderFields.append(String(request.queryImageNames.count))
        expectedHeaderFields.append(requestDigest)
        let expectedHeader = expectedHeaderFields.joined(separator: " ")
        guard lines.first == expectedHeader,
              lines.count >= request.queryImageNames.count + 1 else {
            throw PairPolicyError.invalidRetrievalOutput
        }

        var outcomes: [PairGraphRetrievalQueryOutcome] = []
        outcomes.reserveCapacity(request.queryImageNames.count)
        for (offset, expectedQuery) in request.queryImageNames.enumerated() {
            let fields = lines[offset + 1].split(whereSeparator: \.isWhitespace).map(String.init)
            guard fields.count >= 4,
                  fields[0] == "Q",
                  let status = PairGraphRetrievalQueryStatus(rawValue: fields[1]),
                  fields[2] == expectedQuery,
                  let neighborCount = Int(fields[3]),
                  neighborCount >= 0,
                  fields.count == neighborCount + 4 else {
                throw PairPolicyError.invalidRetrievalOutput
            }
            outcomes.append(PairGraphRetrievalQueryOutcome(
                queryImageName: expectedQuery,
                status: status,
                rankedNeighborImageNames: Array(fields.dropFirst(4))
            ))
        }

        var directedPairLines: [String] = []
        for line in lines.dropFirst(request.queryImageNames.count + 1) {
            let fields = line.split(whereSeparator: \.isWhitespace).map(String.init)
            guard fields.count == 3, fields[0] == "P" else {
                throw PairPolicyError.invalidRetrievalOutput
            }
            directedPairLines.append("\(fields[1]) \(fields[2])")
        }
        let evidence = PairGraphRetrievalAttemptEvidence(
            engine: engine,
            queryImageNames: request.queryImageNames,
            queryStride: queryStride,
            candidateCount: request.candidateCount,
            returnedNeighborCount: request.returnedNeighborCount,
            minimumFrameSeparation: request.minimumFrameSeparation,
            candidatePolicy: request.imageGroupContract?.policy,
            imageGroupListDigest: request.imageGroupContract?.digest,
            imageGroupLines: request.imageGroupContract?.canonicalLines,
            queryOutcomes: outcomes,
            directedPairLines: directedPairLines
        )
        guard PairGraphEvidenceStore.retrievalContractLines(evidence) == lines,
              evidence.outputDigest
                == PairGraphEvidenceStore.retrievalOutputDigest(lines: lines) else {
            throw PairPolicyError.invalidRetrievalOutput
        }
        _ = try validatedVocabularyRetrievalEvidence(
            evidence,
            request: request,
            imageNames: imageNames,
            excluding: basePlan
        )
        return evidence
    }

    static func validatedVocabularyRetrievalEvidence(
        _ retrieval: PairGraphRetrievalAttemptEvidence,
        request: VocabularyRetrievalRequest,
        imageNames: [String],
        excluding basePlan: ColmapPairPlan
    ) throws -> [String] {
        guard retrieval.engine == .localSiftVocabularyV2,
              retrieval.queryImageNames == request.queryImageNames,
              retrieval.candidateCount == request.candidateCount,
              retrieval.returnedNeighborCount == request.returnedNeighborCount,
              retrieval.minimumFrameSeparation == request.minimumFrameSeparation,
              retrieval.candidatePolicy == request.imageGroupContract?.policy,
              retrieval.imageGroupListDigest == request.imageGroupContract?.digest,
              retrieval.imageGroupLines
                == request.imageGroupContract?.canonicalLines,
              vocabularyRetrievalImageGroupContractIsValid(
                  request.imageGroupContract,
                  imageNames: imageNames
              ),
              basePlan.imageNames == imageNames else {
            throw PairPolicyError.invalidRetrievalOutput
        }
        do {
            try PairGraphEvidenceStore.validateRetrievalContractEvidence(
                retrieval,
                imageNames: imageNames
            )
        } catch {
            throw PairPolicyError.invalidRetrievalOutput
        }

        let imageIndex = Dictionary(
            uniqueKeysWithValues: imageNames.enumerated().map { ($0.element, $0.offset) }
        )
        let excludedEdges = Set(basePlan.pairs.map {
            RetrievalEdge($0.firstImageName, $0.secondImageName)
        })
        var seenEdges: Set<RetrievalEdge> = []
        var expectedPairLines: [String] = []
        for outcome in retrieval.queryOutcomes {
            guard let queryIndex = imageIndex[outcome.queryImageName] else {
                throw PairPolicyError.invalidRetrievalOutput
            }
            var retainedNeighborCount = 0
            for neighbor in outcome.rankedNeighborImageNames {
                guard let neighborIndex = imageIndex[neighbor] else {
                    throw PairPolicyError.invalidRetrievalOutput
                }
                if let groupContract = request.imageGroupContract {
                    guard let queryGroup = groupContract.groupIndex(
                        for: outcome.queryImageName
                    ),
                    let neighborGroup = groupContract.groupIndex(for: neighbor),
                    queryGroup != neighborGroup else {
                        throw PairPolicyError.invalidRetrievalOutput
                    }
                }
                let edge = RetrievalEdge(outcome.queryImageName, neighbor)
                guard !excludedEdges.contains(edge) else {
                    throw PairPolicyError.invalidRetrievalOutput
                }
                guard abs(queryIndex - neighborIndex)
                        >= request.minimumFrameSeparation else {
                    throw PairPolicyError.invalidRetrievalOutput
                }
                retainedNeighborCount += 1
                guard retainedNeighborCount <= request.returnedNeighborCount else {
                    throw PairPolicyError.invalidRetrievalOutput
                }
                if seenEdges.insert(edge).inserted {
                    expectedPairLines.append("\(outcome.queryImageName) \(neighbor)")
                }
            }
        }
        expectedPairLines.sort(by: PairGraphEvidenceStore.canonicalUTF8Less)
        guard retrieval.directedPairLines == expectedPairLines else {
            throw PairPolicyError.invalidRetrievalOutput
        }
        return expectedPairLines
    }

    private static func vocabularyRetrievalImageGroupContractIsValid(
        _ contract: VocabularyRetrievalImageGroupContract?,
        imageNames: [String]
    ) -> Bool {
        guard let contract else { return true }
        let groupIndices = Set(contract.groupIndexByImageName.values)
        guard contract.policy == .crossGroupV1,
              contract.groupIndexByImageName.count == imageNames.count,
              Set(contract.groupIndexByImageName.keys) == Set(imageNames),
              groupIndices.count >= 2,
              groupIndices == Set(0..<groupIndices.count) else {
            return false
        }
        let expectedLines = imageNames
            .sorted(by: PairGraphEvidenceStore.canonicalUTF8Less)
            .compactMap { imageName -> String? in
                contract.groupIndexByImageName[imageName].map {
                    "\(imageName)\t\($0)"
                }
            }
        return expectedLines.count == imageNames.count
            && contract.canonicalLines == expectedLines
            && contract.digest == PairGraphEvidenceStore.imageGroupListDigest(
                policy: contract.policy,
                canonicalLines: expectedLines
            )
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
