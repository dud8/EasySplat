import Foundation

enum PairGraphRecoveryMode: String, Codable, Sendable, Equatable {
    case policy
    case sameScheduleExact
}

enum PairGraphRecoveryPhase: String, Codable, Sendable, Equatable {
    case preparing
    case matching
}

struct PairGraphRecoveryState: Codable, Sendable, Equatable {
    static let currentSchemaVersion = 7

    var schemaVersion: Int
    var selectedFramesDigest: String
    var imageNames: [String]
    var pairingPolicy: ResolvedPairingPolicy
    var mode: PairGraphRecoveryMode
    var computeMode: GeometryRecoveryComputeMode
    var phase: PairGraphRecoveryPhase
    var activeRecoveryLevel: PairGraphRecoveryLevel
    var activeScheduledPairs: [ColmapScheduledPair]
    var activePairListDigest: String
    var attempts: [PairGraphAttemptEvidence]
    var usedLocalVocabularyRetrieval: Bool
    var matchingDurationSeconds: Double
    var fallbackReasons: [String]

    init(
        selectedFramesDigest: String,
        imageNames: [String],
        pairingPolicy: ResolvedPairingPolicy = .orderedContinuous,
        mode: PairGraphRecoveryMode,
        computeMode: GeometryRecoveryComputeMode = .gpu,
        phase: PairGraphRecoveryPhase = .matching,
        activeRecoveryLevel: PairGraphRecoveryLevel,
        activePlan: ColmapPairPlan,
        attempts: [PairGraphAttemptEvidence],
        usedLocalVocabularyRetrieval: Bool = false,
        matchingDurationSeconds: Double,
        fallbackReasons: [String]
    ) {
        schemaVersion = Self.currentSchemaVersion
        self.selectedFramesDigest = selectedFramesDigest
        self.imageNames = imageNames
        self.pairingPolicy = pairingPolicy
        self.mode = mode
        self.computeMode = computeMode
        self.phase = phase
        self.activeRecoveryLevel = activeRecoveryLevel
        activeScheduledPairs = activePlan.pairs
        activePairListDigest = activePlan.sha256
        self.attempts = attempts
        self.usedLocalVocabularyRetrieval = usedLocalVocabularyRetrieval
        self.matchingDurationSeconds = matchingDurationSeconds
        self.fallbackReasons = fallbackReasons
    }

    func restoredRecovery() throws -> RestoredPairGraphRecovery {
        try PairGraphRecoveryStore.restore(self)
    }
}

struct RestoredPairGraphRecovery: Sendable, Equatable {
    let mode: PairGraphRecoveryMode
    let pairingPolicy: ResolvedPairingPolicy
    let computeMode: GeometryRecoveryComputeMode
    let phase: PairGraphRecoveryPhase
    let activePlan: ColmapPairPlan
    let recoveryLevel: PairGraphRecoveryLevel
    let attempts: [PairGraphAttemptEvidence]
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
                pairingPolicy: state.pairingPolicy,
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
        guard let lastAttempt = state.attempts.last else {
            throw PairGraphRecoveryStoreError.invalidState
        }
        let lastPlan = try ColmapPairPlan.persisted(
            imageNames: state.imageNames,
            scheduledPairs: lastAttempt.scheduledPairs
        )
        if state.mode == .policy {
            guard lastAttempt.artifact.matcher == .faiss else {
                throw PairGraphRecoveryStoreError.invalidState
            }
            let historicalLevel = recoveryLevelIndex(
                lastAttempt.artifact.recoveryLevel
            )
            let activeLevel = recoveryLevelIndex(state.activeRecoveryLevel)
            let validPhase: Bool
            switch state.phase {
            case .preparing:
                validPhase = activeLevel == historicalLevel + 1
                    && activePlan == lastPlan
            case .matching:
                validPhase = activePlan.isConnected
                    && activeLevel >= historicalLevel
                    && activeLevel - historicalLevel <= 1
                    && (activeLevel != historicalLevel
                        || activePlan == lastPlan)
            }
            guard validPhase else {
                throw PairGraphRecoveryStoreError.invalidState
            }
            return RestoredPairGraphRecovery(
                mode: state.mode,
                pairingPolicy: state.pairingPolicy,
                computeMode: state.computeMode,
                phase: state.phase,
                activePlan: activePlan,
                recoveryLevel: state.activeRecoveryLevel,
                attempts: state.attempts,
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
            guard activeLevel >= historicalLevel,
                  activeLevel - historicalLevel <= 1 else {
                throw PairGraphRecoveryStoreError.invalidState
            }
            if state.phase == .preparing {
                guard activeLevel == historicalLevel + 1,
                      lastAttempt.artifact.matcher == .exact,
                      activePlan == lastPlan else {
                    throw PairGraphRecoveryStoreError.invalidState
                }
            } else if activeLevel == historicalLevel {
                guard activePlan == lastPlan,
                      lastAttempt.artifact.matcher != .exact
                          || lastAttempt.artifact.outcome != .completed else {
                    throw PairGraphRecoveryStoreError.invalidState
                }
            } else {
                let predecessor = lastAttempt.artifact
                guard predecessor.matcher == .exact,
                      activePlan.isConnected,
                      activePlan != lastPlan else {
                    throw PairGraphRecoveryStoreError.invalidState
                }
            }
            return RestoredPairGraphRecovery(
                mode: state.mode,
                pairingPolicy: state.pairingPolicy,
                computeMode: state.computeMode,
                phase: state.phase,
                activePlan: activePlan,
                recoveryLevel: state.activeRecoveryLevel,
                attempts: state.attempts,
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
