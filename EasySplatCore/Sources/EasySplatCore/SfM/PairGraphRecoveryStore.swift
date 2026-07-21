import Foundation

enum PairGraphRecoveryMode: String, Codable, Sendable, Equatable {
    case policy
    case sameScheduleExact
    case terminalExact
}

enum PairGraphRecoveryPhase: String, Codable, Sendable, Equatable {
    case preparing
    case matching
}

struct PairGraphRecoveryState: Codable, Sendable, Equatable {
    static let currentSchemaVersion = 18

    var schemaVersion: Int
    var selectedFramesDigest: String
    var imageNames: [String]
    var groups: [ColmapPairGroup]
    var pairingPolicy: ResolvedPairingPolicy
    var planBinding: PairGraphPlanBinding
    var mode: PairGraphRecoveryMode
    var exactRecoveryReason: DescriptorMatcherRecoveryReason?
    var computeMode: GeometryRecoveryComputeMode
    var phase: PairGraphRecoveryPhase
    var activeRecoveryLevel: PairGraphRecoveryLevel
    var activeScheduledPairs: [ColmapScheduledPair]
    var activePairListDigest: String
    var activeRetrieval: PairGraphRetrievalAttemptEvidence?
    var attempts: [PairGraphAttemptEvidence]
    var retrievalWasScheduled: Bool
    var usedLocalVocabularyRetrieval: Bool
    var matchingDurationSeconds: Double
    var fallbackReasons: [String]

    init(
        selectedFramesDigest: String,
        imageNames: [String],
        groups: [ColmapPairGroup],
        pairingPolicy: ResolvedPairingPolicy = .orderedContinuous,
        planBinding: PairGraphPlanBinding,
        mode: PairGraphRecoveryMode,
        exactRecoveryReason: DescriptorMatcherRecoveryReason? = nil,
        computeMode: GeometryRecoveryComputeMode = .gpu,
        phase: PairGraphRecoveryPhase = .matching,
        activeRecoveryLevel: PairGraphRecoveryLevel,
        activePlan: ColmapPairPlan,
        activeRetrieval: PairGraphRetrievalAttemptEvidence? = nil,
        attempts: [PairGraphAttemptEvidence],
        retrievalWasScheduled: Bool = false,
        usedLocalVocabularyRetrieval: Bool = false,
        matchingDurationSeconds: Double,
        fallbackReasons: [String]
    ) {
        schemaVersion = Self.currentSchemaVersion
        self.selectedFramesDigest = selectedFramesDigest
        self.imageNames = imageNames
        self.groups = groups
        self.pairingPolicy = pairingPolicy
        self.planBinding = planBinding
        self.mode = mode
        self.exactRecoveryReason = exactRecoveryReason
        self.computeMode = computeMode
        self.phase = phase
        self.activeRecoveryLevel = activeRecoveryLevel
        activeScheduledPairs = activePlan.pairs
        activePairListDigest = activePlan.sha256
        self.activeRetrieval = activeRetrieval
        self.attempts = attempts
        self.retrievalWasScheduled = retrievalWasScheduled
        self.usedLocalVocabularyRetrieval = usedLocalVocabularyRetrieval
        self.matchingDurationSeconds = matchingDurationSeconds
        self.fallbackReasons = fallbackReasons
    }

#if DEBUG
    init(
        selectedFramesDigest: String,
        imageNames: [String],
        groups: [ColmapPairGroup]? = nil,
        pairingPolicy: ResolvedPairingPolicy = .orderedContinuous,
        mode: PairGraphRecoveryMode,
        exactRecoveryReason: DescriptorMatcherRecoveryReason? = nil,
        computeMode: GeometryRecoveryComputeMode = .gpu,
        phase: PairGraphRecoveryPhase = .matching,
        activeRecoveryLevel: PairGraphRecoveryLevel,
        activePlan: ColmapPairPlan,
        activeRetrieval: PairGraphRetrievalAttemptEvidence? = nil,
        attempts: [PairGraphAttemptEvidence],
        retrievalWasScheduled: Bool = false,
        usedLocalVocabularyRetrieval: Bool = false,
        matchingDurationSeconds: Double,
        fallbackReasons: [String]
    ) {
        self.init(
            selectedFramesDigest: selectedFramesDigest,
            imageNames: imageNames,
            groups: groups ?? [ColmapPairGroup(
                imageNames: imageNames,
                isVideo: pairingPolicy != .unorderedRetrieval
            )],
            pairingPolicy: pairingPolicy,
            planBinding: .testingDefault(pairingPolicy: pairingPolicy),
            mode: mode,
            exactRecoveryReason: exactRecoveryReason,
            computeMode: computeMode,
            phase: phase,
            activeRecoveryLevel: activeRecoveryLevel,
            activePlan: activePlan,
            activeRetrieval: activeRetrieval,
            attempts: attempts,
            retrievalWasScheduled: retrievalWasScheduled,
            usedLocalVocabularyRetrieval: usedLocalVocabularyRetrieval,
            matchingDurationSeconds: matchingDurationSeconds,
            fallbackReasons: fallbackReasons
        )
    }
#endif

    func restoredRecovery() throws -> RestoredPairGraphRecovery {
        try PairGraphRecoveryStore.restore(self)
    }
}

struct RestoredPairGraphRecovery: Sendable, Equatable {
    let mode: PairGraphRecoveryMode
    let exactRecoveryReason: DescriptorMatcherRecoveryReason?
    let pairingPolicy: ResolvedPairingPolicy
    let groups: [ColmapPairGroup]
    let planBinding: PairGraphPlanBinding
    let computeMode: GeometryRecoveryComputeMode
    let phase: PairGraphRecoveryPhase
    let activePlan: ColmapPairPlan
    let activeRetrieval: PairGraphRetrievalAttemptEvidence?
    let recoveryLevel: PairGraphRecoveryLevel
    let attempts: [PairGraphAttemptEvidence]
    let retrievalWasScheduled: Bool
    let usedLocalVocabularyRetrieval: Bool
    let matchingDurationSeconds: Double
    let fallbackReasons: [String]

}

enum PairGraphRecoveryStore {
    static let maximumBytes = 64 * 1_024 * 1_024

    static func load(
        from url: URL,
        projectPaths: ProjectPaths
    ) throws -> PairGraphRecoveryState {
        try Task.checkCancellation()
        try validateLocation(url, projectPaths: projectPaths)
        let data = try BoundedFileReader.readRegularFile(
            at: url,
            maximumBytes: maximumBytes
        )
        try Task.checkCancellation()
        guard !data.isEmpty else {
            throw PairGraphRecoveryStoreError.invalidState
        }
        let state: PairGraphRecoveryState
        do {
            state = try JSONDecoder().decode(PairGraphRecoveryState.self, from: data)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw PairGraphRecoveryStoreError.invalidState
        }
        try validate(state)
        try Task.checkCancellation()
        return state
    }

    static func loadBound(
        from url: URL,
        expectedImageNames: [String],
        expectedGroups: [ColmapPairGroup]? = nil,
        projectPaths: ProjectPaths
    ) throws -> PairGraphRecoveryState {
        try Task.checkCancellation()
        let state = try load(from: url, projectPaths: projectPaths)
        let selectedFramesDigest = try GeometryArtifactStore.selectedFramesDigest(
            orderedImageNames: expectedImageNames,
            projectPaths: projectPaths
        )
        guard state.imageNames == expectedImageNames,
              expectedGroups.map({ $0 == state.groups }) ?? true,
              state.selectedFramesDigest == selectedFramesDigest else {
            throw PairGraphRecoveryStoreError.invalidState
        }
        try Task.checkCancellation()
        return state
    }

    static func save(
        _ state: PairGraphRecoveryState,
        to url: URL,
        projectPaths: ProjectPaths
    ) throws {
        try Task.checkCancellation()
        try validateLocation(url, projectPaths: projectPaths)
        try validateExistingDestinationIfPresent(url)
        try validate(state)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data: Data
        do {
            data = try encoder.encode(state)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw PairGraphRecoveryStoreError.invalidState
        }
        guard !data.isEmpty, data.count <= maximumBytes else {
            throw PairGraphRecoveryStoreError.invalidState
        }
        try Task.checkCancellation()
        try data.write(to: url, options: [.atomic])
    }

    static func validate(_ state: PairGraphRecoveryState) throws {
        try Task.checkCancellation()
        guard state.schemaVersion == PairGraphRecoveryState.currentSchemaVersion else {
            throw PairGraphRecoveryStoreError.invalidSchema(state.schemaVersion)
        }
        guard isSHA256(state.selectedFramesDigest),
              isSHA256(state.activePairListDigest),
              state.planBinding.isStructurallyValid,
              state.planBinding.pairingPolicy == state.pairingPolicy,
              state.planBinding.normalDescriptorMatcher == .faiss,
              state.planBinding.retrievalCandidateCount > 0,
              state.planBinding.retrievalNeighborCount > 0,
              state.planBinding.retrievalNeighborCount
                <= state.planBinding.retrievalCandidateCount,
              state.planBinding.retrievalQueryStride > 0,
              !state.groups.isEmpty,
              state.groups.allSatisfy({ !$0.imageNames.isEmpty }),
              state.groups.flatMap(\.imageNames) == state.imageNames,
              !state.planBinding.requiresCrossClipRetrieval
                || (state.groups.count > 1
                    && state.groups.allSatisfy(\.isVideo)),
              state.retrievalWasScheduled
                == PairGraphRetrievalScheduling.isRequired(
                    pairingPolicy: state.pairingPolicy,
                    selectedFrameCount: state.imageNames.count,
                    requiresCrossClipRetrieval:
                        state.planBinding.requiresCrossClipRetrieval
                ),
              !state.usedLocalVocabularyRetrieval || state.retrievalWasScheduled,
              state.imageNames.allSatisfy({ imageName in
                  !imageName.isEmpty
                      && imageName != "."
                      && imageName != ".."
                      && !imageName.contains("/")
                      && !imageName.contains("\\")
                      && !imageName.contains(where: \.isWhitespace)
                      && !imageName.utf8.contains(0)
              }) else {
            throw PairGraphRecoveryStoreError.invalidState
        }
        do {
            for attempt in state.attempts {
                let expectsRetrieval = PairGraphEvidenceStore.retrievalIsRequired(
                    pairingPolicy: state.pairingPolicy,
                    imageCount: state.imageNames.count,
                    recoveryLevel: attempt.artifact.recoveryLevel,
                    requiresCrossClipRetrieval:
                        state.planBinding.requiresCrossClipRetrieval
                )
                guard (attempt.retrieval != nil) == expectsRetrieval else {
                    throw PairGraphRecoveryStoreError.invalidState
                }
                if let retrieval = attempt.retrieval {
                    try validateRetrievalBinding(
                        retrieval,
                        recoveryLevel: attempt.artifact.recoveryLevel,
                        state: state,
                        scheduledPairs: attempt.scheduledPairs
                    )
                }
            }
            let activeExpectsRetrieval = PairGraphEvidenceStore.retrievalIsRequired(
                pairingPolicy: state.pairingPolicy,
                imageCount: state.imageNames.count,
                recoveryLevel: state.activeRecoveryLevel,
                requiresCrossClipRetrieval:
                    state.planBinding.requiresCrossClipRetrieval
            )
            guard state.phase == .preparing
                    ? state.activeRetrieval == nil
                    : (state.activeRetrieval != nil) == activeExpectsRetrieval else {
                throw PairGraphRecoveryStoreError.invalidState
            }
            if let activeRetrieval = state.activeRetrieval {
                try validateRetrievalBinding(
                    activeRetrieval,
                    recoveryLevel: state.activeRecoveryLevel,
                    state: state,
                    scheduledPairs: state.activeScheduledPairs
                )
                let scheduledNonlocalEdges = Set(state.activeScheduledPairs.compactMap { pair in
                    pair.role == .local
                        ? nil
                        : PairGraphRecoveryEdge(pair.firstImageName, pair.secondImageName)
                })
                let retrievalEdges: Set<PairGraphRecoveryEdge> = Set(
                    activeRetrieval.directedPairLines.compactMap { line in
                        let fields = line.split(whereSeparator: \.isWhitespace)
                        guard fields.count == 2 else { return nil }
                        return PairGraphRecoveryEdge(String(fields[0]), String(fields[1]))
                    }
                )
                guard state.usedLocalVocabularyRetrieval,
                      retrievalEdges.isSubset(of: scheduledNonlocalEdges) else {
                    throw PairGraphRecoveryStoreError.invalidState
                }
            }
            let hasExecutedRetrieval = state.activeRetrieval != nil
                || state.attempts.contains(where: \.retrievalWasExecuted)
            guard state.usedLocalVocabularyRetrieval == hasExecutedRetrieval else {
                throw PairGraphRecoveryStoreError.invalidState
            }
            if state.attempts.isEmpty {
                guard state.matchingDurationSeconds.isFinite else {
                    throw PairGraphRecoveryStoreError.invalidState
                }
            } else {
                try PairGraphEvidenceStore.validateAttemptHistory(
                    imageNames: state.imageNames,
                    pairingPolicy: state.pairingPolicy,
                    attempts: state.attempts,
                    matchingDurationSeconds: state.matchingDurationSeconds,
                    fallbackReasons: state.fallbackReasons
                )
            }
            _ = try restoreValidated(state)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as PairGraphRecoveryStoreError {
            throw error
        } catch {
            throw PairGraphRecoveryStoreError.invalidState
        }
        try Task.checkCancellation()
    }

    static func restore(
        _ state: PairGraphRecoveryState
    ) throws -> RestoredPairGraphRecovery {
        try validate(state)
        return try restoreValidated(state)
    }

    private static func restoreValidated(
        _ state: PairGraphRecoveryState
    ) throws -> RestoredPairGraphRecovery {
        try Task.checkCancellation()
        let activePlan = try ColmapPairPlan.persisted(
            imageNames: state.imageNames,
            scheduledPairs: state.activeScheduledPairs
        )
        guard activePlan.sha256 == state.activePairListDigest else {
            throw PairGraphRecoveryStoreError.invalidState
        }
        guard let lastAttempt = state.attempts.last else {
            guard state.mode == .policy,
                  state.exactRecoveryReason == nil,
                  state.phase == .preparing,
                  state.retrievalWasScheduled,
                  state.matchingDurationSeconds == 0,
                  Set(state.fallbackReasons).count == state.fallbackReasons.count,
                  state.fallbackReasons.allSatisfy({ reason in
                      let trimmed = reason.trimmingCharacters(
                          in: .whitespacesAndNewlines
                      )
                      return !trimmed.isEmpty
                          && trimmed == reason
                          && reason.utf8.count <= 512
                  }) else {
                throw PairGraphRecoveryStoreError.invalidState
            }
            return RestoredPairGraphRecovery(
                mode: state.mode,
                exactRecoveryReason: nil,
                pairingPolicy: state.pairingPolicy,
                groups: state.groups,
                planBinding: state.planBinding,
                computeMode: state.computeMode,
                phase: state.phase,
                activePlan: activePlan,
                activeRetrieval: state.activeRetrieval,
                recoveryLevel: state.activeRecoveryLevel,
                attempts: [],
                retrievalWasScheduled: true,
                usedLocalVocabularyRetrieval: state.usedLocalVocabularyRetrieval,
                matchingDurationSeconds: 0,
                fallbackReasons: state.fallbackReasons
            )
        }
        let lastPlan = try ColmapPairPlan.persisted(
            imageNames: state.imageNames,
            scheduledPairs: lastAttempt.scheduledPairs
        )
        if state.mode == .policy {
            guard state.exactRecoveryReason == nil,
                  lastAttempt.artifact.matcher == .faiss else {
                throw PairGraphRecoveryStoreError.invalidState
            }
            let historicalLevel = recoveryLevelIndex(
                lastAttempt.artifact.recoveryLevel
            )
            let activeLevel = recoveryLevelIndex(state.activeRecoveryLevel)
            let validPhase: Bool
            switch state.phase {
            case .preparing:
                validPhase = activeLevel > historicalLevel
                    && activeLevel - historicalLevel
                        <= min(2, state.fallbackReasons.count)
                    && activePlan == lastPlan
            case .matching:
                validPhase = activePlan.isConnected
                    && activeLevel >= historicalLevel
                    && activeLevel - historicalLevel
                        <= min(2, max(1, state.fallbackReasons.count))
                    && (activeLevel != historicalLevel
                        || activePlan == lastPlan)
                    && (activeLevel != historicalLevel
                        || state.activeRetrieval == lastAttempt.retrieval)
            }
            guard validPhase else {
                throw PairGraphRecoveryStoreError.invalidState
            }
            return RestoredPairGraphRecovery(
                mode: state.mode,
                exactRecoveryReason: nil,
                pairingPolicy: state.pairingPolicy,
                groups: state.groups,
                planBinding: state.planBinding,
                computeMode: state.computeMode,
                phase: state.phase,
                activePlan: activePlan,
                activeRetrieval: state.activeRetrieval,
                recoveryLevel: state.activeRecoveryLevel,
                attempts: state.attempts,
                retrievalWasScheduled: state.retrievalWasScheduled,
                usedLocalVocabularyRetrieval: state.usedLocalVocabularyRetrieval,
                matchingDurationSeconds: state.matchingDurationSeconds,
                fallbackReasons: state.fallbackReasons
            )
        }
        if state.mode == .sameScheduleExact {
            let historicalLevel = recoveryLevelIndex(
                lastAttempt.artifact.recoveryLevel
            )
            let activeLevel = recoveryLevelIndex(state.activeRecoveryLevel)
            let exactTransitionIsPermitted = PairGraphEvidenceStore
                .permitsExactMatcherTransition(
                    after: lastAttempt.artifact,
                    reason: state.exactRecoveryReason,
                    imageCount: state.imageNames.count,
                    pairingPolicy: state.pairingPolicy
                )
            guard state.phase == .matching,
                  state.exactRecoveryReason != nil,
                  activeLevel == historicalLevel,
                  activePlan == lastPlan,
                  DescriptorMatcherRecoveryPolicy.permitsExactRecovery(
                      scheduledPairCount: activePlan.pairs.count
                  ),
                  exactTransitionIsPermitted else {
                throw PairGraphRecoveryStoreError.invalidState
            }
            return RestoredPairGraphRecovery(
                mode: state.mode,
                exactRecoveryReason: state.exactRecoveryReason,
                pairingPolicy: state.pairingPolicy,
                groups: state.groups,
                planBinding: state.planBinding,
                computeMode: state.computeMode,
                phase: state.phase,
                activePlan: activePlan,
                activeRetrieval: state.activeRetrieval,
                recoveryLevel: state.activeRecoveryLevel,
                attempts: state.attempts,
                retrievalWasScheduled: state.retrievalWasScheduled,
                usedLocalVocabularyRetrieval: state.usedLocalVocabularyRetrieval,
                matchingDurationSeconds: state.matchingDurationSeconds,
                fallbackReasons: state.fallbackReasons
            )
        }
        if state.mode == .terminalExact {
            guard state.phase == .matching,
                  let reason = state.exactRecoveryReason,
                  lastAttempt.artifact.matcher == .exact,
                  lastAttempt.artifact.outcome != .completed,
                  lastAttempt.artifact.exactRecoveryReason == reason,
                  state.attempts.count >= 2 else {
                throw PairGraphRecoveryStoreError.invalidState
            }
            let previousAttempt = state.attempts[state.attempts.count - 2]
            let previousPlan = try ColmapPairPlan.persisted(
                imageNames: state.imageNames,
                scheduledPairs: previousAttempt.scheduledPairs
            )
            guard previousAttempt.artifact.recoveryLevel
                    == lastAttempt.artifact.recoveryLevel,
                  previousPlan == lastPlan,
                  activePlan == lastPlan,
                  PairGraphEvidenceStore.permitsExactMatcherTransition(
                    after: previousAttempt.artifact,
                    reason: reason,
                    imageCount: state.imageNames.count,
                    pairingPolicy: state.pairingPolicy
                  ) else {
                throw PairGraphRecoveryStoreError.invalidState
            }
            return RestoredPairGraphRecovery(
                mode: state.mode,
                exactRecoveryReason: reason,
                pairingPolicy: state.pairingPolicy,
                groups: state.groups,
                planBinding: state.planBinding,
                computeMode: state.computeMode,
                phase: state.phase,
                activePlan: activePlan,
                activeRetrieval: state.activeRetrieval,
                recoveryLevel: state.activeRecoveryLevel,
                attempts: state.attempts,
                retrievalWasScheduled: state.retrievalWasScheduled,
                usedLocalVocabularyRetrieval: state.usedLocalVocabularyRetrieval,
                matchingDurationSeconds: state.matchingDurationSeconds,
                fallbackReasons: state.fallbackReasons
            )
        }
        throw PairGraphRecoveryStoreError.invalidState
    }

    private static func recoveryLevelIndex(_ level: PairGraphRecoveryLevel) -> Int {
        switch level {
        case .normal: return 0
        case .expanded: return 1
        case .maximum: return 2
        }
    }

    private static func validateRetrievalBinding(
        _ retrieval: PairGraphRetrievalAttemptEvidence,
        recoveryLevel: PairGraphRecoveryLevel,
        state: PairGraphRecoveryState,
        scheduledPairs: [ColmapScheduledPair]
    ) throws {
        try PairGraphEvidenceStore.validateRetrievalEvidence(
            retrieval,
            imageNames: state.imageNames
        )
        let expectedCandidateCount: Int
        let expectedNeighborCount: Int
        switch recoveryLevel {
        case .normal:
            expectedCandidateCount = state.planBinding.retrievalCandidateCount
            expectedNeighborCount = state.planBinding.retrievalNeighborCount
        case .expanded:
            switch state.pairingPolicy {
            case .unorderedRetrieval, .segmentedMixed:
                expectedCandidateCount = 40
                expectedNeighborCount = 16
            case .orderedContinuous, .orderedOrbit, .orderedWalkthrough,
                 .orderedLargeArea:
                expectedCandidateCount = state.planBinding.retrievalCandidateCount
                expectedNeighborCount = state.planBinding.retrievalNeighborCount
            }
        case .maximum:
            expectedCandidateCount = 80
            expectedNeighborCount = 32
        }
        let expectedQueries = try PipelineRunner.vocabularyRetrievalQueryImageNames(
            imageNames: state.imageNames,
            groups: state.groups,
            queryStride: state.planBinding.retrievalQueryStride,
            requiresCrossClipRetrieval:
                state.planBinding.requiresCrossClipRetrieval
        )
        let expectedMinimumSeparation: Int
        switch (state.planBinding.requiresCrossClipRetrieval, state.pairingPolicy) {
        case (true, _):
            expectedMinimumSeparation = 0
        case (false, .orderedContinuous), (false, .orderedOrbit),
             (false, .orderedWalkthrough), (false, .orderedLargeArea):
            expectedMinimumSeparation = max(12, state.imageNames.count / 10)
        case (false, .segmentedMixed), (false, .unorderedRetrieval):
            expectedMinimumSeparation = 0
        }
        guard retrieval.engine == state.planBinding.retrievalEngine,
              retrieval.queryImageNames == expectedQueries,
              retrieval.queryStride == state.planBinding.retrievalQueryStride,
              retrieval.candidateCount == expectedCandidateCount,
              retrieval.returnedNeighborCount == expectedNeighborCount,
              retrieval.minimumFrameSeparation == expectedMinimumSeparation else {
            throw PairGraphRecoveryStoreError.invalidState
        }
        let scheduledNonlocalEdges = Set(scheduledPairs.compactMap { pair in
            pair.role == .local
                ? nil
                : PairGraphRecoveryEdge(pair.firstImageName, pair.secondImageName)
        })
        let retrievalEdges: Set<PairGraphRecoveryEdge> = Set(
            retrieval.directedPairLines.compactMap { line in
            let fields = line.split(whereSeparator: \.isWhitespace)
            guard fields.count == 2 else { return nil }
            return PairGraphRecoveryEdge(String(fields[0]), String(fields[1]))
            }
        )
        guard retrievalEdges.isSubset(of: scheduledNonlocalEdges) else {
            throw PairGraphRecoveryStoreError.invalidState
        }
    }

    private static func validateLocation(
        _ url: URL,
        projectPaths: ProjectPaths
    ) throws {
        let expected: URL
        do {
            expected = try projectPaths.validateReservedProjectPath(
                url,
                relativePath: "SfM/pair_graph_recovery.json"
            )
        } catch {
            throw PairGraphRecoveryStoreError.invalidLocation
        }
        let parentValues = try expected.deletingLastPathComponent().resourceValues(
            forKeys: [.isDirectoryKey, .isSymbolicLinkKey]
        )
        guard parentValues.isDirectory == true,
              parentValues.isSymbolicLink != true else {
            throw PairGraphRecoveryStoreError.invalidLocation
        }
    }

    private static func validateExistingDestinationIfPresent(_ url: URL) throws {
        let fileManager = FileManager.default
        let isSymbolicLink = (try? fileManager.destinationOfSymbolicLink(
            atPath: url.path
        )) != nil
        guard fileManager.fileExists(atPath: url.path) || isSymbolicLink else {
            return
        }
        do {
            _ = try BoundedFileReader.readRegularFile(
                at: url,
                maximumBytes: maximumBytes
            )
        } catch {
            throw PairGraphRecoveryStoreError.invalidLocation
        }
    }

    private static func isSHA256(_ value: String) -> Bool {
        value.count == 64 && value.utf8.allSatisfy { byte in
            (48...57).contains(byte) || (97...102).contains(byte)
        }
    }
}

private struct PairGraphRecoveryEdge: Hashable {
    let first: String
    let second: String

    init(_ lhs: String, _ rhs: String) {
        if lhs < rhs {
            first = lhs
            second = rhs
        } else {
            first = rhs
            second = lhs
        }
    }
}

enum PairGraphRecoveryStoreError: Error, LocalizedError, Equatable {
    case invalidLocation
    case invalidSchema(Int)
    case invalidState
    case terminalExactRecovery
    case conflictingCompletedEvidence

    var errorDescription: String? {
        switch self {
        case .invalidLocation:
            return "Pair-graph recovery state must stay at its canonical project path."
        case .invalidSchema(let schema):
            return "Unsupported pair-graph recovery schema \(schema)."
        case .invalidState:
            return "Pair-graph recovery state is incomplete or inconsistent."
        case .terminalExactRecovery:
            return "The one permitted exact-matching recovery already failed."
        case .conflictingCompletedEvidence:
            return "Completed matching evidence conflicts with the pending recovery state."
        }
    }
}
