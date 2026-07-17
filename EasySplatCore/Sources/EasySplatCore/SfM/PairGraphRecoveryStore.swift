import Foundation

enum PairGraphRecoveryMode: String, Codable, Sendable, Equatable {
    case policy
    case sameScheduleExact
    case targetedExact
    case fullExact
}

enum PairGraphRecoveryPhase: String, Codable, Sendable, Equatable {
    case preparing
    case matching
}

struct PairGraphRecoveryState: Codable, Sendable, Equatable {
    static let currentSchemaVersion = 4

    var schemaVersion: Int
    var selectedFramesDigest: String
    var imageNames: [String]
    var mode: PairGraphRecoveryMode
    var computeMode: GeometryRecoveryComputeMode
    var phase: PairGraphRecoveryPhase
    var activeRecoveryLevel: PairGraphRecoveryLevel
    var activeScheduledPairs: [ColmapScheduledPair]
    var activePairListDigest: String
    var attempts: [PairGraphAttemptEvidence]
    var matchingDurationSeconds: Double
    var fallbackReasons: [String]

    init(
        selectedFramesDigest: String,
        imageNames: [String],
        mode: PairGraphRecoveryMode,
        computeMode: GeometryRecoveryComputeMode = .gpu,
        phase: PairGraphRecoveryPhase = .matching,
        activeRecoveryLevel: PairGraphRecoveryLevel,
        activePlan: ColmapPairPlan,
        attempts: [PairGraphAttemptEvidence],
        matchingDurationSeconds: Double,
        fallbackReasons: [String]
    ) {
        schemaVersion = Self.currentSchemaVersion
        self.selectedFramesDigest = selectedFramesDigest
        self.imageNames = imageNames
        self.mode = mode
        self.computeMode = computeMode
        self.phase = phase
        self.activeRecoveryLevel = activeRecoveryLevel
        activeScheduledPairs = activePlan.pairs
        activePairListDigest = activePlan.sha256
        self.attempts = attempts
        self.matchingDurationSeconds = matchingDurationSeconds
        self.fallbackReasons = fallbackReasons
    }

    func restoredRecovery() throws -> RestoredPairGraphRecovery {
        try PairGraphRecoveryStore.restore(self)
    }
}

struct RestoredPairGraphRecovery: Sendable, Equatable {
    let mode: PairGraphRecoveryMode
    let computeMode: GeometryRecoveryComputeMode
    let phase: PairGraphRecoveryPhase
    let activePlan: ColmapPairPlan
    let sourcePlan: ColmapPairPlan
    let recoveryLevel: PairGraphRecoveryLevel
    let attempts: [PairGraphAttemptEvidence]
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
        projectPaths: ProjectPaths
    ) throws -> PairGraphRecoveryState {
        try Task.checkCancellation()
        let state = try load(from: url, projectPaths: projectPaths)
        let selectedFramesDigest = try GeometryArtifactStore.selectedFramesDigest(
            orderedImageNames: expectedImageNames,
            projectPaths: projectPaths
        )
        guard state.imageNames == expectedImageNames,
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
            try PairGraphEvidenceStore.validateAttemptHistory(
                imageNames: state.imageNames,
                attempts: state.attempts,
                matchingDurationSeconds: state.matchingDurationSeconds,
                fallbackReasons: state.fallbackReasons
            )
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
        let policyHistory = try validatePolicyHistory(
            state.attempts,
            imageNames: state.imageNames
        )

        let firstRecoveryIndex = state.attempts.firstIndex {
            $0.purpose != .policy
        }
        if state.mode == .policy {
            guard firstRecoveryIndex == nil,
                  policyHistory.lastAttempt.artifact.matcher == .faiss else {
                throw PairGraphRecoveryStoreError.invalidState
            }
            let historicalLevel = recoveryLevelIndex(
                policyHistory.lastAttempt.artifact.recoveryLevel
            )
            let activeLevel = recoveryLevelIndex(state.activeRecoveryLevel)
            let validPhase: Bool
            switch state.phase {
            case .preparing:
                validPhase = activeLevel == historicalLevel + 1
                    && activePlan == policyHistory.lastPlan
            case .matching:
                validPhase = activePlan.isConnected
                    && activeLevel >= historicalLevel
                    && activeLevel - historicalLevel <= 1
                    && (activeLevel != historicalLevel
                        || activePlan == policyHistory.lastPlan)
            }
            guard validPhase else {
                throw PairGraphRecoveryStoreError.invalidState
            }
            return RestoredPairGraphRecovery(
                mode: state.mode,
                computeMode: state.computeMode,
                phase: state.phase,
                activePlan: activePlan,
                sourcePlan: policyHistory.lastPlan,
                recoveryLevel: state.activeRecoveryLevel,
                attempts: state.attempts,
                matchingDurationSeconds: state.matchingDurationSeconds,
                fallbackReasons: state.fallbackReasons
            )
        }
        if state.mode == .sameScheduleExact {
            guard firstRecoveryIndex == nil else {
                throw PairGraphRecoveryStoreError.invalidState
            }
            let historicalLevel = recoveryLevelIndex(
                policyHistory.lastAttempt.artifact.recoveryLevel
            )
            let activeLevel = recoveryLevelIndex(state.activeRecoveryLevel)
            guard activeLevel >= historicalLevel,
                  activeLevel - historicalLevel <= 1 else {
                throw PairGraphRecoveryStoreError.invalidState
            }
            if state.phase == .preparing {
                guard activeLevel == historicalLevel + 1,
                      policyHistory.lastAttempt.artifact.matcher == .exact,
                      activePlan == policyHistory.lastPlan else {
                    throw PairGraphRecoveryStoreError.invalidState
                }
            } else if activeLevel == historicalLevel {
                guard activePlan == policyHistory.lastPlan,
                      policyHistory.lastAttempt.artifact.matcher != .exact
                          || policyHistory.lastAttempt.artifact.outcome != .completed else {
                    throw PairGraphRecoveryStoreError.invalidState
                }
            } else {
                let predecessor = policyHistory.lastAttempt.artifact
                guard predecessor.matcher == .exact,
                      activePlan.isConnected,
                      activePlan != policyHistory.lastPlan else {
                    throw PairGraphRecoveryStoreError.invalidState
                }
            }
            return RestoredPairGraphRecovery(
                mode: state.mode,
                computeMode: state.computeMode,
                phase: state.phase,
                activePlan: activePlan,
                sourcePlan: activePlan,
                recoveryLevel: state.activeRecoveryLevel,
                attempts: state.attempts,
                matchingDurationSeconds: state.matchingDurationSeconds,
                fallbackReasons: state.fallbackReasons
            )
        }

        guard state.phase == .matching, activePlan.isConnected else {
            throw PairGraphRecoveryStoreError.invalidState
        }
        let sourceAttemptIndex: Int?
        if let firstRecoveryIndex {
            sourceAttemptIndex = firstRecoveryIndex > 0
                ? firstRecoveryIndex - 1
                : nil
        } else {
            sourceAttemptIndex = state.attempts.lastIndex {
                $0.purpose == .policy
            }
        }
        guard let sourceAttemptIndex else {
            throw PairGraphRecoveryStoreError.invalidState
        }
        let sourceAttempt = state.attempts[sourceAttemptIndex]
        guard sourceAttempt.artifact.matcher == .faiss else {
            throw PairGraphRecoveryStoreError.invalidState
        }
        let sourcePlan = try ColmapPairPlan.persisted(
            imageNames: state.imageNames,
            scheduledPairs: sourceAttempt.scheduledPairs
        )
        guard sourcePlan.isConnected,
              state.activeRecoveryLevel == sourceAttempt.artifact.recoveryLevel else {
            throw PairGraphRecoveryStoreError.invalidState
        }

        let recoveryAttempts = Array(state.attempts.dropFirst(sourceAttemptIndex + 1))
        switch state.mode {
        case .policy:
            throw PairGraphRecoveryStoreError.invalidState
        case .sameScheduleExact:
            throw PairGraphRecoveryStoreError.invalidState

        case .targetedExact:
            guard sourceAttempt.artifact.outcome == .completed,
                  activePlan.pairs.count < sourcePlan.pairs.count,
                  activePlan.pairs.allSatisfy(Set(sourcePlan.pairs).contains),
                  recoveryAttempts.allSatisfy({ attempt in
                      attempt.purpose == .targetedExactGraphRecovery
                          && attempt.artifact.matcher == .exact
                          && attempt.artifact.recoveryLevel
                              == sourceAttempt.artifact.recoveryLevel
                          && attempt.artifact.outcome == .failed
                          && attempt.scheduledPairs == activePlan.pairs
                  }) else {
                throw PairGraphRecoveryStoreError.invalidState
            }

        case .fullExact:
            guard sourceAttempt.artifact.outcome == .completed,
                  activePlan == sourcePlan else {
                throw PairGraphRecoveryStoreError.invalidState
            }
            let targetedAttempts = recoveryAttempts.prefix {
                $0.purpose == .targetedExactGraphRecovery
            }
            let fullAttempts = recoveryAttempts.dropFirst(targetedAttempts.count)
            guard fullAttempts.allSatisfy({ attempt in
                      attempt.purpose == .fullExactGraphRecovery
                          && attempt.artifact.matcher == .exact
                          && attempt.artifact.recoveryLevel
                              == sourceAttempt.artifact.recoveryLevel
                          && attempt.artifact.outcome == .failed
                          && attempt.scheduledPairs == sourcePlan.pairs
                  }),
                  targetedAttempts.isEmpty
                      || targetedAttempts.last?.artifact.outcome == .completed else {
                throw PairGraphRecoveryStoreError.invalidState
            }
        }

        try Task.checkCancellation()
        return RestoredPairGraphRecovery(
            mode: state.mode,
            computeMode: state.computeMode,
            phase: state.phase,
            activePlan: activePlan,
            sourcePlan: sourcePlan,
            recoveryLevel: state.activeRecoveryLevel,
            attempts: state.attempts,
            matchingDurationSeconds: state.matchingDurationSeconds,
            fallbackReasons: state.fallbackReasons
        )
    }

    private static func validatePolicyHistory(
        _ attempts: [PairGraphAttemptEvidence],
        imageNames: [String]
    ) throws -> (lastAttempt: PairGraphAttemptEvidence, lastPlan: ColmapPairPlan) {
        var sawFaiss = false
        var sawExact = false
        var previousLevel: Int?
        var previousMatcher: DescriptorMatcher?
        var previousPlan: ColmapPairPlan?
        var lastAttempt: PairGraphAttemptEvidence?
        var lastPlan: ColmapPairPlan?

        for attempt in attempts {
            try Task.checkCancellation()
            guard attempt.purpose == .policy else {
                break
            }
            switch attempt.artifact.matcher {
            case .faiss:
                guard !sawExact else {
                    throw PairGraphRecoveryStoreError.invalidState
                }
                sawFaiss = true
            case .exact:
                guard sawFaiss else {
                    throw PairGraphRecoveryStoreError.invalidState
                }
                sawExact = true
            }

            let plan = try ColmapPairPlan.persisted(
                imageNames: imageNames,
                scheduledPairs: attempt.scheduledPairs
            )
            guard attempt.artifact.outcome != .completed || plan.isConnected else {
                throw PairGraphRecoveryStoreError.invalidState
            }
            let level = recoveryLevelIndex(attempt.artifact.recoveryLevel)
            if let previousLevel, let previousMatcher, let previousPlan {
                guard level >= previousLevel,
                      level - previousLevel <= 1 else {
                    throw PairGraphRecoveryStoreError.invalidState
                }
                if attempt.artifact.matcher != previousMatcher {
                    guard previousMatcher == .faiss,
                          attempt.artifact.matcher == .exact,
                          level == previousLevel,
                          plan == previousPlan else {
                        throw PairGraphRecoveryStoreError.invalidState
                    }
                }
                if level > previousLevel {
                    guard attempt.artifact.matcher == previousMatcher else {
                        throw PairGraphRecoveryStoreError.invalidState
                    }
                }
            }
            previousLevel = level
            previousMatcher = attempt.artifact.matcher
            previousPlan = plan
            lastAttempt = attempt
            lastPlan = plan
        }

        guard sawFaiss,
              previousLevel != nil,
              let lastAttempt,
              let lastPlan else {
            throw PairGraphRecoveryStoreError.invalidState
        }
        return (lastAttempt, lastPlan)
    }

    private static func recoveryLevelIndex(_ level: PairGraphRecoveryLevel) -> Int {
        switch level {
        case .normal: return 0
        case .expanded: return 1
        case .maximum: return 2
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

enum PairGraphRecoveryStoreError: Error, LocalizedError, Equatable {
    case invalidLocation
    case invalidSchema(Int)
    case invalidState

    var errorDescription: String? {
        switch self {
        case .invalidLocation:
            return "Pair-graph recovery state must stay at its canonical project path."
        case .invalidSchema(let schema):
            return "Unsupported pair-graph recovery schema \(schema)."
        case .invalidState:
            return "Pair-graph recovery state is incomplete or inconsistent."
        }
    }
}
