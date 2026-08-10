import CryptoKit
import Darwin
import Foundation

package struct PublishedResultLiveProject: Sendable, Equatable {
    package let projectID: UUID
    package let title: String
    package let notes: String?
    package let viewerPreferences: ViewerPreferences

    package init(metadata: ProjectMetadata) {
        projectID = metadata.id
        title = metadata.title
        notes = metadata.notes
        viewerPreferences = metadata.viewerPreferences
    }
}

package struct ReceiptBoundProjectSnapshot: Sendable, Equatable {
    package let snapshot: ProjectArtifactSnapshot
    package let trainingManifestData: Data
    package let geometryManifestDigest: String

    package init(
        snapshot: ProjectArtifactSnapshot,
        trainingManifestData: Data,
        geometryManifestDigest: String
    ) {
        self.snapshot = snapshot
        self.trainingManifestData = trainingManifestData
        self.geometryManifestDigest = geometryManifestDigest
    }

    package static func == (
        lhs: ReceiptBoundProjectSnapshot,
        rhs: ReceiptBoundProjectSnapshot
    ) -> Bool {
        snapshotsEqual(lhs.snapshot, rhs.snapshot)
            && lhs.trainingManifestData == rhs.trainingManifestData
            && lhs.geometryManifestDigest == rhs.geometryManifestDigest
    }
}

package struct ReceiptBoundSnapshotLoadOperations: @unchecked Sendable {
    package var geometryManifestSHA256: @Sendable (Data) -> String
    package var afterGeometryManifestValidation: @Sendable () throws -> Void

    package static func system() -> Self {
        Self(
            geometryManifestSHA256: { data in
                SHA256.hash(data: data)
                    .map { String(format: "%02x", $0) }
                    .joined()
            },
            afterGeometryManifestValidation: {}
        )
    }
}

package struct ReceiptBoundCurrentPublishedResult: Sendable, Equatable {
    package let publishedResult: ValidatedPublishedResult
    package let snapshot: ProjectArtifactSnapshot
    package let liveProject: PublishedResultLiveProject

    package var presentation: PublishedResultPresentation {
        publishedResult.receipt.presentation
    }

    package static func == (
        lhs: ReceiptBoundCurrentPublishedResult,
        rhs: ReceiptBoundCurrentPublishedResult
    ) -> Bool {
        lhs.publishedResult == rhs.publishedResult
            && snapshotsEqual(lhs.snapshot, rhs.snapshot)
            && lhs.liveProject == rhs.liveProject
    }
}

package struct LegacyCurrentPublishedResult: Sendable, Equatable {
    package let outputURL: URL
    package let snapshot: ProjectArtifactSnapshot
    package let liveProject: PublishedResultLiveProject

    package static func == (
        lhs: LegacyCurrentPublishedResult,
        rhs: LegacyCurrentPublishedResult
    ) -> Bool {
        lhs.outputURL == rhs.outputURL
            && snapshotsEqual(lhs.snapshot, rhs.snapshot)
            && lhs.liveProject == rhs.liveProject
    }
}

package enum CurrentPublishedResult: Sendable, Equatable {
    case receiptBound(ReceiptBoundCurrentPublishedResult)
    case legacy(LegacyCurrentPublishedResult)
}

package struct PreviousPublishedResult: Sendable, Equatable {
    package let publishedResult: ValidatedPublishedResult
    package let liveProject: PublishedResultLiveProject

    package var presentation: PublishedResultPresentation {
        publishedResult.receipt.presentation
    }
}

package enum PublishedResultResolverUnavailability: Sendable, Equatable {
    case noPublishedResult
    case invalidPublishedResult
    case publicationConflict
    case projectMismatch
    case bindingMismatch
    case latestAttemptNotViewable
    case currentProjectInvalid
    case projectChanged
}

package enum ResolvedPublishedResult: Sendable, Equatable {
    case current(CurrentPublishedResult)
    case previous(PreviousPublishedResult)
    case unavailable(PublishedResultResolverUnavailability)
}

package enum PublishedResultPreservationError: Error, Equatable {
    case currentResultUnavailable
}

package struct PublishedLegacyResultIdentity: Sendable, Equatable {
    package let outputDirectory: PublishedResolverFileIdentity
    package let outputPly: PublishedResolverFileIdentity

    fileprivate func namesSameLegacyCandidate(
        as other: PublishedLegacyResultIdentity
    ) -> Bool {
        outputDirectory == other.outputDirectory
            && outputPly == other.outputPly
    }
}

package struct PublishedResolverFileIdentity: Sendable, Equatable {
    package let device: UInt64
    package let inode: UInt64
    package let size: Int64
    package let owner: UInt32
    package let mode: UInt32
    package let linkCount: UInt64
    package let modifiedSeconds: Int64
    package let modifiedNanoseconds: Int64
    package let changedSeconds: Int64
    package let changedNanoseconds: Int64

    fileprivate init(_ status: stat) {
        device = UInt64(status.st_dev)
        inode = UInt64(status.st_ino)
        size = Int64(status.st_size)
        owner = UInt32(status.st_uid)
        mode = UInt32(status.st_mode)
        linkCount = UInt64(status.st_nlink)
        modifiedSeconds = Int64(status.st_mtimespec.tv_sec)
        modifiedNanoseconds = Int64(status.st_mtimespec.tv_nsec)
        changedSeconds = Int64(status.st_ctimespec.tv_sec)
        changedNanoseconds = Int64(status.st_ctimespec.tv_nsec)
    }

}

package enum PublishedResultFallbackState: Sendable, Equatable {
    case absent
    case legacy(PublishedLegacyResultIdentity)
    case blocked
    case conflict
}

extension ProjectArtifactSnapshotStore {
    /// Performs the full finished-project structural checks while consuming
    /// the PLY evidence already authenticated by the published-pair lock.
    /// This is the receipt-bound equivalent of `.full` and deliberately avoids
    /// hashing a large canonical PLY a second time in one authority decision.
    package static func loadReceiptBoundFull(
        projectURL: URL,
        outputEvidence: ValidatedPlyArtifactEvidence,
        operations: ReceiptBoundSnapshotLoadOperations = .system()
    ) throws -> ReceiptBoundProjectSnapshot {
        try PublishedResultResolver.loadReceiptBoundSnapshot(
            projectURL: projectURL,
            outputEvidence: outputEvidence,
            operations: operations
        )
    }
}

package struct PublishedResultResolverOperations: @unchecked Sendable {
    package var pairOperations: PublishedResultPairOperations
    /// Resolver-level observation point for every PLY evidence validation used
    /// to grant published-result authority. The resolver installs this on the
    /// exact pair-store operations value passed into authorization so tests do
    /// not depend on a lower-level hook that a direct resolver hash could skip.
    package var didBeginPlyEvidenceValidation: @Sendable (String) -> Void
    package var authorizePair: (
        ProjectPaths,
        PublishedResultPairOperations,
        @escaping @Sendable () -> Bool,
        (ValidatedPublishedResult) throws -> ResolvedPublishedResult
    ) throws -> ResolvedPublishedResult?
    package var loadMetadata: (URL) throws -> ProjectMetadata
    package var loadReceiptBoundSnapshot: (
        URL,
        ValidatedPlyArtifactEvidence
    ) throws -> ReceiptBoundProjectSnapshot
    package var loadLegacySnapshot: (URL) throws -> ProjectArtifactSnapshot
    package var inspectFallbackState: (
        ProjectPaths
    ) throws -> PublishedResultFallbackState

    package static func system() -> Self {
        Self(
            pairOperations: .system(),
            didBeginPlyEvidenceValidation: { _ in },
            authorizePair: { paths, pairOperations, shouldCancel, evaluate in
                var decision: ResolvedPublishedResult?
                let result = try PublishedResultPairStore.commitResolvedResultIf(
                    projectPaths: paths,
                    operations: pairOperations,
                    shouldCancel: shouldCancel,
                    matches: { pair in
                        decision = try evaluate(pair)
                        return true
                    },
                    afterCommit: { _ in }
                )
                guard result != nil else { return nil }
                guard let decision else {
                    throw PublishedResultResolverSemanticFailure()
                }
                return decision
            },
            loadMetadata: { metadataURL in
                try ProjectMetadataStore.load(from: metadataURL)
            },
            loadReceiptBoundSnapshot: { projectURL, evidence in
                try ProjectArtifactSnapshotStore.loadReceiptBoundFull(
                    projectURL: projectURL,
                    outputEvidence: evidence
                )
            },
            loadLegacySnapshot: { projectURL in
                try ProjectArtifactSnapshotStore.load(
                    projectURL: projectURL,
                    validationDepth: .full
                )
            },
            inspectFallbackState: { paths in
                try PublishedResultResolver.inspectFallbackState(paths: paths)
            }
        )
    }
}

package enum PublishedResultResolver {
    private static let maximumStabilityAttempts = 3
    private static let maximumManifestBytes = 1_048_576

    package static func resolve(
        projectURL: URL,
        operations: PublishedResultResolverOperations = .system(),
        shouldCancel: @escaping @Sendable () -> Bool = { Task.isCancelled },
        allowLegacyCurrent: Bool = true
    ) throws -> ResolvedPublishedResult {
        if shouldCancel() { throw CancellationError() }
        let paths = ProjectPaths(root: projectURL)
        // Only a PLY that was already a safe, receipt-less canonical file may
        // enter the legacy path. An invalid receipt must not become legacy by
        // disappearing after pair validation rejects it.
        let initialFallback = try operations.inspectFallbackState(paths)
        var pairOperations = operations.pairOperations
        let lowerLevelObserver = pairOperations.willValidatePly
        let resolverObserver = operations.didBeginPlyEvidenceValidation
        pairOperations.willValidatePly = { leaf in
            lowerLevelObserver(leaf)
            resolverObserver(leaf)
        }
        do {
            if let result = try operations.authorizePair(
                paths,
                pairOperations,
                shouldCancel,
                { pair in
                    try resolveStablePair(
                        pair,
                        paths: paths,
                        operations: operations
                    )
                }
            ) {
                return result
            }
            return try resolveFallback(
                paths: paths,
                operations: operations,
                initialFallback: initialFallback,
                allowLegacy: false
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch is PublishedResultResolverSemanticFailure {
            return .unavailable(.currentProjectInvalid)
        } catch let error as PublishedResultPairError {
            switch error {
            case .publicationConflict:
                return try resolveFallback(
                    paths: paths,
                    operations: operations,
                    initialFallback: initialFallback,
                    allowLegacy: allowLegacyCurrent
                )
            case .unsafeOutput, .invalidSource:
                return .unavailable(.invalidPublishedResult)
            case .persistence:
                throw error
            }
        }
    }

    /// Cheap sidebar hint only. This never grants viewer, export, share, or
    /// retraining authority; those paths must call `resolve(projectURL:)`.
    package static func hasQuickPreviousResultHint(
        projectURL: URL,
        metadata: ProjectMetadata
    ) -> Bool {
        guard latestAttemptKind(metadata) == .previous else { return false }
        let paths = ProjectPaths(root: projectURL)
        guard let receipt = try? PublishedSplatReceiptStore.load(
            projectPaths: paths
        ), receipt.projectID == metadata.id,
           receipt.outputPath == PublishedSplatReceipt.canonicalOutputPath,
           receipt.outputEvidence.byteCount <= UInt64(Int64.max) else {
            return false
        }
        let descriptor = Darwin.open(
            paths.outputSplatURL.path,
            O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC
        )
        guard descriptor >= 0 else { return false }
        defer { Darwin.close(descriptor) }
        var opened = stat()
        var named = stat()
        guard Darwin.fstat(descriptor, &opened) == 0,
              Darwin.lstat(paths.outputSplatURL.path, &named) == 0,
              (opened.st_mode & S_IFMT) == S_IFREG,
              opened.st_uid == geteuid(),
              opened.st_nlink == 1,
              opened.st_size == off_t(receipt.outputEvidence.byteCount),
              PublishedResolverFileIdentity(opened)
                == PublishedResolverFileIdentity(named) else {
            return false
        }
        return true
    }

    /// Ensures a retrain starts with durable authority for the result it must
    /// preserve. Existing receipt-bound current and previous results are
    /// returned unchanged. A receipt-less legacy result is eligible only after
    /// the same full finished-project validation used to open it succeeds; the
    /// bridge then installs a receipt without replacing the canonical PLY.
    package static func preserveCurrentResultForRetraining(
        projectURL: URL,
        publicationID: UUID = UUID(),
        publishedAt: Date = Date(),
        pairOperations: PublishedResultPairOperations = .system(),
        shouldCancel: @escaping @Sendable () -> Bool = { Task.isCancelled }
    ) throws -> ValidatedPublishedResult {
        if shouldCancel() { throw CancellationError() }
        var resolverOperations = PublishedResultResolverOperations.system()
        resolverOperations.pairOperations = pairOperations
        let initial = try resolve(
            projectURL: projectURL,
            operations: resolverOperations,
            shouldCancel: shouldCancel,
            allowLegacyCurrent: false
        )
        switch initial {
        case .current(.receiptBound(let current)):
            return current.publishedResult
        case .previous(let previous):
            return previous.publishedResult
        case .unavailable, .current(.legacy):
            break
        }

        let paths = ProjectPaths(root: projectURL)
        var preparedSnapshot: ReceiptBoundProjectSnapshot?
        var preparedEvidence: ValidatedPlyArtifactEvidence?
        do {
            return try PublishedResultPairStore.backfillLegacyReceipt(
                projectPaths: paths,
                operations: pairOperations,
                shouldCancel: shouldCancel,
                makeReceipt: { evidence, recoveredReceipt in
                    let snapshot = try ProjectArtifactSnapshotStore
                        .loadReceiptBoundFull(
                            projectURL: projectURL,
                            outputEvidence: evidence
                        )
                    guard let plan = snapshot.snapshot.metadata.resolvedRunPlan,
                          let geometry = snapshot.snapshot.geometryArtifact,
                          let training = snapshot.snapshot.trainingArtifact else {
                        throw PublishedResultPreservationError
                            .currentResultUnavailable
                    }
                    preparedSnapshot = snapshot
                    preparedEvidence = evidence
                    let candidate = try PublishedSplatReceiptFactory.make(
                        metadata: snapshot.snapshot.metadata,
                        resolvedRunPlan: plan,
                        geometry: geometry,
                        geometryManifestDigest:
                            snapshot.geometryManifestDigest,
                        reboundTraining: training,
                        reboundTrainingManifestData:
                            snapshot.trainingManifestData,
                        outputEvidence: evidence,
                        projectPaths: paths,
                        publicationID: recoveredReceipt?.publicationID
                            ?? publicationID,
                        publishedAt: recoveredReceipt?.publishedAt
                            ?? publishedAt
                    )
                    guard recoveredReceipt == nil || recoveredReceipt == candidate else {
                        throw PublishedResultPairError.publicationConflict(
                            "the interrupted legacy receipt does not match the current project"
                        )
                    }
                    return candidate
                },
                beforeCommit: {
                    guard let preparedSnapshot, let preparedEvidence else {
                        throw PublishedResultPreservationError
                            .currentResultUnavailable
                    }
                    let current = try ProjectArtifactSnapshotStore
                        .loadReceiptBoundFull(
                            projectURL: projectURL,
                            outputEvidence: preparedEvidence
                        )
                    guard try metadataAuthorityData(
                        current.snapshot.metadata
                    ) == metadataAuthorityData(
                        preparedSnapshot.snapshot.metadata
                    ),
                          current.snapshot.geometryArtifact
                            == preparedSnapshot.snapshot.geometryArtifact,
                          current.snapshot.trainingArtifact
                            == preparedSnapshot.snapshot.trainingArtifact,
                          current.trainingManifestData
                            == preparedSnapshot.trainingManifestData,
                          current.geometryManifestDigest
                            == preparedSnapshot.geometryManifestDigest else {
                        throw PublishedResultPreservationError
                            .currentResultUnavailable
                    }
                }
            )
        } catch let error as PublishedResultPairError {
            switch error {
            case .unsafeOutput, .invalidSource:
                throw PublishedResultPreservationError.currentResultUnavailable
            case .persistence:
                throw error
            case .publicationConflict:
                break
            }
            // Another process may have completed the same one-time bridge
            // while this caller moved from legacy validation to the pair lock.
            // Accept only a fresh full resolver decision; malformed or future
            // authority remains unavailable.
            switch try resolve(
                projectURL: projectURL,
                operations: resolverOperations,
                shouldCancel: shouldCancel
            ) {
            case .current(.receiptBound(let current)):
                return current.publishedResult
            case .previous(let previous):
                return previous.publishedResult
            case .current(.legacy), .unavailable:
                throw error
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch where isSemanticProjectStateError(error) {
            throw PublishedResultPreservationError.currentResultUnavailable
        }
    }
}

private extension PublishedResultResolver {
    enum LatestAttemptKind: Equatable {
        case current
        case previous
        case unavailable
    }

    static func resolveStablePair(
        _ pair: ValidatedPublishedResult,
        paths: ProjectPaths,
        operations: PublishedResultResolverOperations
    ) throws -> ResolvedPublishedResult {
        for _ in 0..<maximumStabilityAttempts {
            do {
                let before = try operations.loadMetadata(paths.metadataURL)
                let beforeAuthority = try metadataAuthorityData(before)
                let kind = latestAttemptKind(before)
                let receiptBoundSnapshot: ReceiptBoundProjectSnapshot?
                switch kind {
                case .current:
                    receiptBoundSnapshot = try operations.loadReceiptBoundSnapshot(
                        paths.root,
                        pair.outputEvidence
                    )
                case .previous, .unavailable:
                    receiptBoundSnapshot = nil
                }

                let after = try operations.loadMetadata(paths.metadataURL)
                guard try metadataAuthorityData(after) == beforeAuthority else {
                    continue
                }
                if let receiptBoundSnapshot,
                   try metadataAuthorityData(receiptBoundSnapshot.snapshot.metadata)
                        != beforeAuthority {
                    continue
                }
                guard pair.receipt.projectID == after.id else {
                    return .unavailable(.projectMismatch)
                }

                let liveProject = PublishedResultLiveProject(metadata: after)
                switch kind {
                case .current:
                    guard let receiptBoundSnapshot,
                          let geometry = receiptBoundSnapshot.snapshot.geometryArtifact,
                          let training = receiptBoundSnapshot.snapshot.trainingArtifact,
                          let plan = after.resolvedRunPlan else {
                        return .unavailable(.currentProjectInvalid)
                    }
                    let expected: PublishedSplatReceipt
                    do {
                        expected = try PublishedSplatReceiptFactory.makeAdoptionCandidate(
                            existing: pair.receipt,
                            metadata: after,
                            resolvedRunPlan: plan,
                            geometry: geometry,
                            geometryManifestDigest:
                                receiptBoundSnapshot.geometryManifestDigest,
                            reboundTraining: training,
                            reboundTrainingManifestData:
                                receiptBoundSnapshot.trainingManifestData,
                            outputEvidence: pair.outputEvidence,
                            projectPaths: paths
                        )
                    } catch is PublishedSplatReceiptFactoryError {
                        return .unavailable(.bindingMismatch)
                    }
                    guard PublishedSplatReceiptFactory.isBound(
                        pair.receipt,
                        to: expected
                    ) else {
                        return .unavailable(.bindingMismatch)
                    }
                    let stableSnapshot = ProjectArtifactSnapshot(
                        metadata: after,
                        geometryArtifact: geometry,
                        trainingArtifact: training
                    )
                    return .current(.receiptBound(
                        ReceiptBoundCurrentPublishedResult(
                            publishedResult: pair,
                            snapshot: stableSnapshot,
                            liveProject: liveProject
                        )
                    ))
                case .previous:
                    return .previous(PreviousPublishedResult(
                        publishedResult: pair,
                        liveProject: liveProject
                    ))
                case .unavailable:
                    return .unavailable(.latestAttemptNotViewable)
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch where isSemanticProjectStateError(error) {
                return .unavailable(.currentProjectInvalid)
            }
        }
        return .unavailable(.projectChanged)
    }

    static func resolveFallback(
        paths: ProjectPaths,
        operations: PublishedResultResolverOperations,
        initialFallback: PublishedResultFallbackState?,
        allowLegacy: Bool
    ) throws -> ResolvedPublishedResult {
        let fallback = try operations.inspectFallbackState(paths)
        switch fallback {
        case .absent:
            return .unavailable(.noPublishedResult)
        case .blocked:
            return .unavailable(.invalidPublishedResult)
        case .conflict:
            return .unavailable(.publicationConflict)
        case .legacy(let identity):
            guard allowLegacy,
                  case .legacy(let initialIdentity) = initialFallback,
                  initialIdentity.namesSameLegacyCandidate(as: identity) else {
                return .unavailable(.invalidPublishedResult)
            }
            return try resolveStableLegacy(
                identity: identity,
                paths: paths,
                operations: operations
            )
        }
    }

    static func resolveStableLegacy(
        identity: PublishedLegacyResultIdentity,
        paths: ProjectPaths,
        operations: PublishedResultResolverOperations
    ) throws -> ResolvedPublishedResult {
        for _ in 0..<maximumStabilityAttempts {
            let beforeState: PublishedResultFallbackState
            do {
                beforeState = try operations.inspectFallbackState(paths)
            } catch is CancellationError {
                throw CancellationError()
            } catch where isSemanticProjectStateError(error) {
                return .unavailable(.invalidPublishedResult)
            }
            guard beforeState == .legacy(identity) else {
                return .unavailable(.projectChanged)
            }

            let before: ProjectMetadata
            do {
                before = try operations.loadMetadata(paths.metadataURL)
            } catch is CancellationError {
                throw CancellationError()
            } catch where isSemanticProjectStateError(error) {
                return .unavailable(.currentProjectInvalid)
            }
            let beforeAuthority: Data
            do {
                beforeAuthority = try metadataAuthorityData(before)
            } catch {
                return .unavailable(.currentProjectInvalid)
            }
            guard latestAttemptKind(before) == .current else {
                let after: ProjectMetadata
                do {
                    after = try operations.loadMetadata(paths.metadataURL)
                } catch is CancellationError {
                    throw CancellationError()
                } catch where isSemanticProjectStateError(error) {
                    return .unavailable(.projectChanged)
                }
                let afterAuthority: Data
                do {
                    afterAuthority = try metadataAuthorityData(after)
                } catch {
                    return .unavailable(.projectChanged)
                }
                if afterAuthority == beforeAuthority {
                    return .unavailable(.latestAttemptNotViewable)
                }
                continue
            }

            let snapshot: ProjectArtifactSnapshot
            do {
                snapshot = try operations.loadLegacySnapshot(paths.root)
            } catch is CancellationError {
                throw CancellationError()
            } catch where isSemanticProjectStateError(error) {
                return .unavailable(.currentProjectInvalid)
            }
            let after: ProjectMetadata
            do {
                after = try operations.loadMetadata(paths.metadataURL)
            } catch is CancellationError {
                throw CancellationError()
            } catch where isSemanticProjectStateError(error) {
                return .unavailable(.projectChanged)
            }
            let afterState: PublishedResultFallbackState
            do {
                afterState = try operations.inspectFallbackState(paths)
            } catch is CancellationError {
                throw CancellationError()
            } catch where isSemanticProjectStateError(error) {
                return .unavailable(.invalidPublishedResult)
            }
            guard afterState == .legacy(identity) else {
                return .unavailable(.projectChanged)
            }
            let afterAuthority: Data
            do {
                afterAuthority = try metadataAuthorityData(after)
            } catch {
                return .unavailable(.projectChanged)
            }
            let snapshotAuthority: Data
            do {
                snapshotAuthority = try metadataAuthorityData(snapshot.metadata)
            } catch {
                return .unavailable(.currentProjectInvalid)
            }
            guard afterAuthority == beforeAuthority,
                  snapshotAuthority == beforeAuthority else {
                continue
            }
            guard latestAttemptKind(after) == .current,
                  snapshot.trainingArtifact?.completionStatus == .completed,
                  snapshot.trainingArtifact?.outputPath
                    == PublishedSplatReceipt.canonicalOutputPath else {
                return .unavailable(.currentProjectInvalid)
            }
            let stableSnapshot = ProjectArtifactSnapshot(
                metadata: after,
                geometryArtifact: snapshot.geometryArtifact,
                trainingArtifact: snapshot.trainingArtifact
            )
            return .current(.legacy(LegacyCurrentPublishedResult(
                outputURL: paths.outputSplatURL,
                snapshot: stableSnapshot,
                liveProject: PublishedResultLiveProject(metadata: after)
            )))
        }
        return .unavailable(.projectChanged)
    }

    static func latestAttemptKind(_ metadata: ProjectMetadata) -> LatestAttemptKind {
        if metadata.state.stage == .done,
           metadata.state.lastError == nil,
           metadata.checkpoint == nil,
           metadata.lastRunStartedAt == nil {
            return .current
        }
        if metadata.state.lastError != nil
            || metadata.checkpoint != nil
            || metadata.lastRunStartedAt != nil {
            return .previous
        }
        return .unavailable
    }

    static func metadataAuthorityData(_ metadata: ProjectMetadata) throws -> Data {
        var authority = metadata
        authority.title = ""
        authority.notes = nil
        authority.viewerPreferences = ViewerPreferences()
        authority.createToViewerReadySeconds = nil
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(authority)
    }

    static func loadReceiptBoundSnapshot(
        projectURL: URL,
        outputEvidence: ValidatedPlyArtifactEvidence,
        operations: ReceiptBoundSnapshotLoadOperations
    ) throws -> ReceiptBoundProjectSnapshot {
        let paths = ProjectPaths(root: projectURL)
        let initialMetadata = try ProjectMetadataStore.load(from: paths.metadataURL)
        let boundGeometryManifest = try BoundGeometryManifest.open(
            at: paths.geometryManifestURL,
            maximumBytes: GeometryArtifactStore.maximumManifestBytes
        )
        let geometryEnvelope = try JSONDecoder().decode(
            PublishedResolverGeometrySchemaVersionEnvelope.self,
            from: boundGeometryManifest.data
        )
        guard geometryEnvelope.schemaVersion
                == GeometryArtifact.currentSchemaVersion else {
            throw GeometryArtifactStore.Error.invalidSchema(
                geometryEnvelope.schemaVersion
            )
        }
        let fullGeometry = try JSONDecoder().decode(
            GeometryArtifact.self,
            from: boundGeometryManifest.data
        )
        try GeometryArtifactStore.validate(
            fullGeometry,
            projectPaths: paths,
            input: initialMetadata.input
        )
        guard let plan = initialMetadata.resolvedRunPlan else {
            throw ProjectArtifactSnapshotError.artifactWithoutResolvedPlan
        }
        do {
            try GeometryArtifactStore.requireRunPlanBinding(
                fullGeometry,
                plan: plan
            )
        } catch {
            throw ProjectArtifactSnapshotError.geometryPlanMismatch
        }
        try operations.afterGeometryManifestValidation()
        try boundGeometryManifest.requireStableBytes()
        let initialManifestData = try BoundedFileReader.readRegularFile(
            at: paths.trainingManifestURL,
            maximumBytes: maximumManifestBytes
        )
        let training = try TrainingArtifactStore.loadManifest(
            from: paths.trainingManifestURL,
            projectPaths: paths
        )
        try TrainingArtifactStore.validateCompletedOutput(
            training,
            evidence: outputEvidence
        )
        guard training.detailProfile
                == initialMetadata.requestedRunOptions.detailProfile,
              training.matchesResolvedTrainingPlan(
                  plan,
                  resourcePolicy:
                      initialMetadata.requestedRunOptions.resourcePolicy
              ) else {
            throw ProjectArtifactSnapshotError.trainingPlanMismatch
        }
        guard training.datasetDerivation.sourceSelectedFramesDigest
                == fullGeometry.selectedFramesDigest else {
            throw ProjectArtifactSnapshotError.trainingGeometryMismatch
        }
        guard initialMetadata.state.stage == .done,
              initialMetadata.state.lastError == nil,
              initialMetadata.checkpoint == nil,
              initialMetadata.lastRunStartedAt == nil,
              training.completionStatus == .completed,
              training.outputPath
                == PublishedSplatReceipt.canonicalOutputPath else {
            throw ProjectArtifactSnapshotError.invalidFinishedTraining
        }
        let canonicalManifestData = try TrainingArtifactStore.encodedManifestData(
            training,
            projectPaths: paths
        )
        let finalManifestData = try BoundedFileReader.readRegularFile(
            at: paths.trainingManifestURL,
            maximumBytes: maximumManifestBytes
        )
        guard initialManifestData == canonicalManifestData,
              finalManifestData == canonicalManifestData else {
            throw ProjectArtifactSnapshotError.invalidFinishedTraining
        }
        let finalMetadata = try ProjectMetadataStore.load(from: paths.metadataURL)
        guard try metadataAuthorityData(finalMetadata)
                == metadataAuthorityData(initialMetadata) else {
            throw ProjectArtifactSnapshotError.invalidFinishedTraining
        }
        try boundGeometryManifest.requireStableBytes()
        let geometryManifestDigest = operations.geometryManifestSHA256(
            boundGeometryManifest.data
        )
        try boundGeometryManifest.requireStableBytes()
        guard geometryManifestDigest
                == training.datasetDerivation.sourceGeometryManifestSHA256 else {
            throw ProjectArtifactSnapshotError.trainingGeometryMismatch
        }
        return ReceiptBoundProjectSnapshot(
            snapshot: ProjectArtifactSnapshot(
                metadata: finalMetadata,
                geometryArtifact: fullGeometry,
                trainingArtifact: training
            ),
            trainingManifestData: canonicalManifestData,
            geometryManifestDigest: geometryManifestDigest
        )
    }

    static func inspectFallbackState(
        paths: ProjectPaths
    ) throws -> PublishedResultFallbackState {
        var namedOutput = stat()
        let outputStatus = retryingLstat(paths.outputURL.path, status: &namedOutput)
        if outputStatus != 0 {
            return errno == ENOENT ? .absent : .blocked
        }
        let outputDescriptor = Darwin.open(
            paths.outputURL.path,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard outputDescriptor >= 0 else { return .blocked }
        defer { Darwin.close(outputDescriptor) }
        var openedOutput = stat()
        guard Darwin.fstat(outputDescriptor, &openedOutput) == 0,
              safeDirectory(openedOutput),
              sameNamedFile(openedOutput, namedOutput) else {
            return .blocked
        }
        // The pair store lazily creates this permanent reserved lock. Ensure it
        // exists before capturing the directory timestamps used to detect
        // transient receipt/transaction churn; otherwise the lock's first
        // creation would make every legacy project's first resolution fail.
        guard try ensurePublicationLock(in: outputDescriptor) else {
            return .blocked
        }
        guard Darwin.fstat(outputDescriptor, &openedOutput) == 0,
              retryingLstat(paths.outputURL.path, status: &namedOutput) == 0,
              safeDirectory(openedOutput),
              sameNamedFile(openedOutput, namedOutput) else {
            return .blocked
        }
        let initialOutputIdentity = PublishedResolverFileIdentity(openedOutput)
        guard try !containsPublishedTransaction(in: outputDescriptor) else {
            return .conflict
        }

        let receiptPresence = entryPresence(
            parent: outputDescriptor,
            name: paths.outputSplatReceiptURL.lastPathComponent
        )
        guard receiptPresence == .missing else { return .blocked }

        let plyName = paths.outputSplatURL.lastPathComponent
        switch entryPresence(parent: outputDescriptor, name: plyName) {
        case .missing:
            return .absent
        case .unsafe:
            return .blocked
        case .present:
            break
        }
        let plyDescriptor = plyName.withCString {
            Darwin.openat(
                outputDescriptor,
                $0,
                O_RDONLY | O_NOFOLLOW | O_CLOEXEC
            )
        }
        guard plyDescriptor >= 0 else { return .blocked }
        defer { Darwin.close(plyDescriptor) }
        var openedPly = stat()
        var namedPly = stat()
        let namedPlyStatus = plyName.withCString {
            Darwin.fstatat(outputDescriptor, $0, &namedPly, AT_SYMLINK_NOFOLLOW)
        }
        guard Darwin.fstat(plyDescriptor, &openedPly) == 0,
              namedPlyStatus == 0,
              safeLegacyPly(openedPly),
              sameNamedFile(openedPly, namedPly) else {
            return .blocked
        }
        let plyIdentity = PublishedResolverFileIdentity(openedPly)

        var finalOpenedOutput = stat()
        var finalNamedOutput = stat()
        var finalOpenedPly = stat()
        var finalNamedPly = stat()
        let finalOutputStatus = retryingLstat(
            paths.outputURL.path,
            status: &finalNamedOutput
        )
        let finalPlyStatus = plyName.withCString {
            Darwin.fstatat(
                outputDescriptor,
                $0,
                &finalNamedPly,
                AT_SYMLINK_NOFOLLOW
            )
        }
        guard Darwin.fstat(outputDescriptor, &finalOpenedOutput) == 0,
              finalOutputStatus == 0,
              Darwin.fstat(plyDescriptor, &finalOpenedPly) == 0,
              finalPlyStatus == 0,
              PublishedResolverFileIdentity(finalOpenedOutput)
                == initialOutputIdentity,
              PublishedResolverFileIdentity(finalNamedOutput)
                == initialOutputIdentity,
              PublishedResolverFileIdentity(finalOpenedPly) == plyIdentity,
              PublishedResolverFileIdentity(finalNamedPly) == plyIdentity else {
            return .blocked
        }
        return .legacy(PublishedLegacyResultIdentity(
            outputDirectory: initialOutputIdentity,
            outputPly: plyIdentity
        ))
    }

    enum EntryPresence: Equatable {
        case missing
        case present
        case unsafe
    }

    static func entryPresence(parent: Int32, name: String) -> EntryPresence {
        var status = stat()
        while true {
            let result = name.withCString {
                Darwin.fstatat(parent, $0, &status, AT_SYMLINK_NOFOLLOW)
            }
            if result == 0 {
                return (status.st_mode & S_IFMT) == S_IFREG ? .present : .unsafe
            }
            let code = errno
            if code == EINTR { continue }
            return code == ENOENT ? .missing : .unsafe
        }
    }

    /// Returns `false` for an existing object that cannot be the private
    /// publication lock. Resource failures remain errors so resolver callers
    /// do not mistake descriptor exhaustion or I/O failure for bad project
    /// state.
    static func ensurePublicationLock(in outputDescriptor: Int32) throws -> Bool {
        let name = ".published-result.lock"
        var descriptor = name.withCString {
            Darwin.openat(
                outputDescriptor,
                $0,
                O_RDWR | O_CREAT | O_EXCL | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC,
                mode_t(0o600)
            )
        }
        let created: Bool
        if descriptor >= 0 {
            created = true
        } else if errno == EEXIST {
            descriptor = name.withCString {
                Darwin.openat(
                    outputDescriptor,
                    $0,
                    O_RDWR | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC
                )
            }
            created = false
        } else {
            if errno == ELOOP || errno == ENOTDIR || errno == EACCES
                || errno == EPERM || errno == EROFS {
                return false
            }
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        guard descriptor >= 0 else {
            if errno == ELOOP || errno == ENOTDIR || errno == EACCES
                || errno == EPERM || errno == EROFS {
                return false
            }
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        defer { Darwin.close(descriptor) }

        if created {
            guard Darwin.fchmod(descriptor, 0o600) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            try synchronize(descriptor)
            try synchronize(outputDescriptor)
        }

        var opened = stat()
        var named = stat()
        let namedStatus = name.withCString {
            Darwin.fstatat(
                outputDescriptor,
                $0,
                &named,
                AT_SYMLINK_NOFOLLOW
            )
        }
        guard Darwin.fstat(descriptor, &opened) == 0,
              namedStatus == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        guard (opened.st_mode & S_IFMT) == S_IFREG,
              (opened.st_mode & 0o7777) == mode_t(0o600),
              opened.st_uid == geteuid(),
              opened.st_nlink == 1,
              PublishedResolverFileIdentity(opened)
                == PublishedResolverFileIdentity(named) else {
            return false
        }
        return true
    }

    static func synchronize(_ descriptor: Int32) throws {
        while Darwin.fsync(descriptor) != 0 {
            if errno == EINTR { continue }
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    static func containsPublishedTransaction(in outputDescriptor: Int32) throws -> Bool {
        let duplicate = Darwin.dup(outputDescriptor)
        guard duplicate >= 0, let directory = Darwin.fdopendir(duplicate) else {
            if duplicate >= 0 { Darwin.close(duplicate) }
            throw POSIXError(.EIO)
        }
        defer { Darwin.closedir(directory) }
        errno = 0
        while let entry = Darwin.readdir(directory) {
            let name = withUnsafePointer(to: entry.pointee.d_name) {
                $0.withMemoryRebound(
                    to: CChar.self,
                    capacity: Int(MAXNAMLEN) + 1
                ) {
                    String(cString: $0)
                }
            }
            if isPublishedTransactionName(name) { return true }
            errno = 0
        }
        guard errno == 0 else { throw POSIXError(.EIO) }
        return false
    }

    static func isPublishedTransactionName(_ name: String) -> Bool {
        // Pair cleanup quarantines one app-owned entry by prepending exactly
        // one `.cleanup-`. Inspect the original logical name so an interrupted
        // quarantine cannot make publication authority invisible to legacy
        // fallback.
        let foldedName = name
            .decomposedStringWithCanonicalMapping
            .folding(
                options: [.caseInsensitive],
                locale: Locale(identifier: "en_US_POSIX")
            )
        let cleanupPrefix = ".cleanup-"
        let logicalName = foldedName.hasPrefix(cleanupPrefix)
            ? String(foldedName.dropFirst(cleanupPrefix.count))
            : foldedName
        return [
            ".published-result-build-",
            ".published-result-build-authority-",
            ".published-result-tx-",
            ".published-result-retired-",
            ".published-receipt-build-",
            ".published-receipt-build-authority-",
            ".published-receipt-tx-",
            ".published-receipt-retired-",
            ".published-receipt-cleanup-",
        ].contains { logicalName.hasPrefix($0) }
    }

    static func retryingLstat(
        _ path: String,
        status: UnsafeMutablePointer<stat>
    ) -> Int32 {
        while Darwin.lstat(path, status) != 0 {
            if errno == EINTR { continue }
            return -1
        }
        return 0
    }

    static func safeDirectory(_ status: stat) -> Bool {
        (status.st_mode & S_IFMT) == S_IFDIR
            && status.st_uid == geteuid()
            && (status.st_mode & 0o022) == 0
    }

    static func safeLegacyPly(_ status: stat) -> Bool {
        (status.st_mode & S_IFMT) == S_IFREG
            && status.st_uid == geteuid()
            && status.st_nlink == 1
            && status.st_size > 0
            && (status.st_mode & 0o7777) == mode_t(0o600)
    }

    static func sameNamedFile(_ lhs: stat, _ rhs: stat) -> Bool {
        lhs.st_dev == rhs.st_dev
            && lhs.st_ino == rhs.st_ino
            && (lhs.st_mode & S_IFMT) == (rhs.st_mode & S_IFMT)
    }
}

private struct PublishedResultResolverSemanticFailure: Error {}

private struct PublishedResolverGeometrySchemaVersionEnvelope: Decodable {
    let schemaVersion: Int
}

private final class BoundGeometryManifest {
    let data: Data

    private let url: URL
    private let descriptor: Int32
    private let identity: PublishedResolverFileIdentity

    private init(
        url: URL,
        descriptor: Int32,
        identity: PublishedResolverFileIdentity,
        data: Data
    ) {
        self.url = url
        self.descriptor = descriptor
        self.identity = identity
        self.data = data
    }

    deinit {
        Darwin.close(descriptor)
    }

    static func open(at url: URL, maximumBytes: Int) throws -> BoundGeometryManifest {
        let descriptor = Darwin.open(
            url.path,
            O_RDONLY | O_NOFOLLOW | O_CLOEXEC
        )
        guard descriptor >= 0 else {
            try throwOpenFailure(errno)
        }
        var ownsDescriptor = true
        defer {
            if ownsDescriptor { Darwin.close(descriptor) }
        }

        let opened = try descriptorStatus(descriptor)
        let named = try pathStatus(url)
        let identity = PublishedResolverFileIdentity(opened)
        guard maximumBytes >= 0,
              (opened.st_mode & S_IFMT) == S_IFREG,
              opened.st_nlink == 1,
              opened.st_size >= 0,
              opened.st_size <= off_t(maximumBytes),
              PublishedResolverFileIdentity(named) == identity else {
            throw GeometryArtifactStore.Error.artifactDigestMismatch(
                "geometry manifest"
            )
        }
        let data = try readExact(
            descriptor: descriptor,
            byteCount: Int(opened.st_size)
        )
        let bound = BoundGeometryManifest(
            url: url,
            descriptor: descriptor,
            identity: identity,
            data: data
        )
        try bound.requireStableBytes()
        ownsDescriptor = false
        return bound
    }

    func requireStableBytes() throws {
        let opened = try Self.descriptorStatus(descriptor)
        let named = try Self.pathStatus(url)
        guard PublishedResolverFileIdentity(opened) == identity,
              PublishedResolverFileIdentity(named) == identity,
              try Self.readExact(
                  descriptor: descriptor,
                  byteCount: data.count
              ) == data else {
            throw GeometryArtifactStore.Error.artifactDigestMismatch(
                "geometry manifest"
            )
        }
    }

    private static func descriptorStatus(_ descriptor: Int32) throws -> stat {
        var status = stat()
        while Darwin.fstat(descriptor, &status) != 0 {
            if errno == EINTR { continue }
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        return status
    }

    private static func pathStatus(_ url: URL) throws -> stat {
        var status = stat()
        while Darwin.lstat(url.path, &status) != 0 {
            let code = errno
            if code == EINTR { continue }
            if code == ENOENT || code == ENOTDIR {
                throw GeometryArtifactStore.Error.artifactDigestMismatch(
                    "geometry manifest"
                )
            }
            throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        }
        return status
    }

    private static func readExact(
        descriptor: Int32,
        byteCount: Int
    ) throws -> Data {
        var data = Data(count: byteCount)
        var offset = 0
        while offset < byteCount {
            let count = data.withUnsafeMutableBytes { bytes in
                Darwin.pread(
                    descriptor,
                    bytes.baseAddress?.advanced(by: offset),
                    byteCount - offset,
                    off_t(offset)
                )
            }
            if count < 0, errno == EINTR { continue }
            if count < 0 {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            guard count > 0 else {
                throw GeometryArtifactStore.Error.artifactDigestMismatch(
                    "geometry manifest"
                )
            }
            offset += count
        }
        return data
    }

    private static func throwOpenFailure(_ code: Int32) throws -> Never {
        if code == ENOENT || code == ELOOP || code == ENOTDIR {
            throw GeometryArtifactStore.Error.artifactDigestMismatch(
                "geometry manifest"
            )
        }
        throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
    }
}

private func isSemanticProjectStateError(_ error: Error) -> Bool {
    if error is PublishedResultResolverSemanticFailure
        || error is ProjectMetadataStore.LoadError
        || error is ProjectMetadataStore.SaveError
        || error is ProjectArtifactSnapshotError
        || error is ProjectArtifactError
        || error is ProjectPathError
        || error is GeometryArtifactStore.Error
        || error is TrainingArtifactStoreError
        || error is PublishedSplatReceiptFactoryError
        || error is DecodingError
        || error is EncodingError {
        return true
    }
    if BoundedFileReader.isMissingFileError(error) {
        return true
    }
    if let cocoaError = error as? CocoaError {
        return cocoaError.code == .fileReadNoSuchFile
            || cocoaError.code == .fileNoSuchFile
    }
    return false
}

private func snapshotsEqual(
    _ lhs: ProjectArtifactSnapshot,
    _ rhs: ProjectArtifactSnapshot
) -> Bool {
    encodedMetadata(lhs.metadata) == encodedMetadata(rhs.metadata)
        && lhs.geometryArtifact == rhs.geometryArtifact
        && lhs.trainingArtifact == rhs.trainingArtifact
}

private func encodedMetadata(_ metadata: ProjectMetadata) -> Data? {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return try? encoder.encode(metadata)
}
