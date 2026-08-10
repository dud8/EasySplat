import CryptoKit
import Darwin
import Foundation

@_silgen_name("flock")
private func subjectIsolationFlock(_ descriptor: Int32, _ operation: Int32) -> Int32

public struct SubjectIsolationRequest: Sendable {
    public let projectPaths: ProjectPaths
    public let nativeExecutableURL: URL
    public let nativeMetallibURL: URL
    public let toolchainBuildIdentity: String
    public let memoryBudgetBytes: Int64
    public let anchor: SubjectAnchor?

    public init(
        projectPaths: ProjectPaths,
        nativeExecutableURL: URL,
        nativeMetallibURL: URL,
        toolchainBuildIdentity: String,
        memoryBudgetBytes: Int64,
        anchor: SubjectAnchor? = nil
    ) {
        self.projectPaths = projectPaths
        self.nativeExecutableURL = nativeExecutableURL
        self.nativeMetallibURL = nativeMetallibURL
        self.toolchainBuildIdentity = toolchainBuildIdentity
        self.memoryBudgetBytes = memoryBudgetBytes
        self.anchor = anchor
    }
}

public protocol SubjectIsolationCoordinating: Sendable {
    func isolate(
        request: SubjectIsolationRequest,
        onProgress: @escaping @Sendable (SubjectIsolationProgress) -> Void,
        onLog: @escaping @Sendable (String, Bool) -> Void
    ) async throws -> SubjectIsolationOutcome
}

public enum SubjectIsolationCoordinatorError: Error, LocalizedError, Sendable, Equatable {
    case invalidProject
    case heldOutRejected

    public var errorDescription: String? {
        switch self {
        case .invalidProject:
            "This project does not contain a valid completed splat and camera dataset."
        case .heldOutRejected:
            "Subject isolation did not agree with the held-out camera views."
        }
    }
}

public struct SubjectIsolationCleanupFailure: Error, LocalizedError, Sendable, Equatable {
    public static let maximumSummaryByteCount = 512

    public let primaryFailureSummary: String?
    public let cleanupFailureSummary: String

    init(primaryError: Error?, cleanupErrors: [Error]) {
        primaryFailureSummary = primaryError.map(Self.summary)
        cleanupFailureSummary = Self.bounded(
            cleanupErrors.map(Self.summary).joined(separator: " | ")
        )
    }

    public var errorDescription: String? {
        if primaryFailureSummary == nil {
            return "EasySplat couldn’t safely clean up temporary subject-isolation files."
        }
        return "Subject isolation failed, and EasySplat couldn’t safely clean up its temporary files."
    }

    private static func summary(_ error: Error) -> String {
        let nsError = error as NSError
        return bounded(
            "\(String(reflecting: error)) [\(nsError.domain):\(nsError.code)]"
        )
    }

    private static func bounded(_ value: String) -> String {
        var result = ""
        var byteCount = 0
        for character in value {
            let characterByteCount = String(character).utf8.count
            guard byteCount + characterByteCount <= maximumSummaryByteCount else {
                break
            }
            result.append(character)
            byteCount += characterByteCount
        }
        return result
    }
}

typealias SubjectIsolationNativeOperation = @Sendable (
    _ request: SubjectIsolationNativeRunRequest,
    _ onProgress: @escaping @Sendable (SubjectIsolationProgress) -> Void,
    _ onLog: @escaping @Sendable (String, Bool) -> Void
) async throws -> SubjectIsolationNativeRunResult

typealias SubjectIsolationMaskAcquisition = @Sendable (
    _ views: [SubjectIsolationAnalysisView],
    _ stagingDirectory: URL,
    _ startingOrdinal: Int,
    _ shouldCancel: @escaping @Sendable () -> Bool
) async throws -> [SubjectIsolationAcquiredMask]

enum SubjectIsolationAmbiguityLeaseCheckpoint: Sendable, Equatable {
    case claimWillBindStaging
    case markerTemporaryWritten
    case markerTemporarySynchronized
    case markerCanonicalPublished
    case claimDurable
}

enum SubjectIsolationAmbiguityCleanupCheckpoint: Sendable, Equatable {
    case willOpenStagingRoot
    case willQuarantine(relativePath: String)
    case willUnlinkQuarantined(relativePath: String, quarantineLeaf: String)
    case didReadDirectoryEntry(count: Int)
}

typealias SubjectIsolationAmbiguityLeaseCheckpointOperation = @Sendable (
    _ checkpoint: SubjectIsolationAmbiguityLeaseCheckpoint,
    _ isolationURL: URL
) throws -> Void

typealias SubjectIsolationAmbiguityLockContentionOperation = @Sendable () -> Void

typealias SubjectIsolationAmbiguityCleanupCheckpointOperation = @Sendable (
    _ checkpoint: SubjectIsolationAmbiguityCleanupCheckpoint
) throws -> Void

private struct SubjectIsolationPreparedOutcome {
    let outcome: SubjectIsolationOutcome
    let retainsOwnedStagingAuthority: Bool
}

private struct SubjectIsolationAuthorityRollbackFailure: Error {
    let primaryError: Error
    let rollbackError: Error
}

public struct SubjectIsolationCoordinator: SubjectIsolationCoordinating, Sendable {
    private let nativeOperation: SubjectIsolationNativeOperation
    private let maskAcquisition: SubjectIsolationMaskAcquisition
    private let ambiguityLeaseCheckpoint: SubjectIsolationAmbiguityLeaseCheckpointOperation
    private let ambiguityLockContention: SubjectIsolationAmbiguityLockContentionOperation

    public init() {
        let native = SubjectIsolationNativeRunner()
        let vision = SubjectIsolationVisionMaskAcquirer()
        nativeOperation = { request, onProgress, onLog in
            try await native.run(
                request,
                onProgress: onProgress,
                onLog: onLog
            )
        }
        maskAcquisition = { views, directory, startingOrdinal, shouldCancel in
            try await vision.acquire(
                views: views,
                stagingDirectory: directory,
                startingOrdinal: startingOrdinal,
                shouldCancel: shouldCancel
            )
        }
        ambiguityLeaseCheckpoint = { _, _ in }
        ambiguityLockContention = {}
    }

    init(
        nativeOperation: @escaping SubjectIsolationNativeOperation,
        maskAcquisition: @escaping SubjectIsolationMaskAcquisition,
        ambiguityLeaseCheckpoint: @escaping SubjectIsolationAmbiguityLeaseCheckpointOperation = {
            _, _ in
        },
        ambiguityLockContention: @escaping SubjectIsolationAmbiguityLockContentionOperation = {}
    ) {
        self.nativeOperation = nativeOperation
        self.maskAcquisition = maskAcquisition
        self.ambiguityLeaseCheckpoint = ambiguityLeaseCheckpoint
        self.ambiguityLockContention = ambiguityLockContention
    }

    public static func cancelPendingAmbiguity(
        projectPaths: ProjectPaths
    ) throws {
        try SubjectIsolationAmbiguityStagingLease.retireAll(in: projectPaths)
    }

    static func cancelPendingAmbiguity(
        projectPaths: ProjectPaths,
        beforeOwnedStagingRemoval: (URL) throws -> Void,
        onLockContention: SubjectIsolationAmbiguityLockContentionOperation = {},
        cleanupCheckpoint: SubjectIsolationAmbiguityCleanupCheckpointOperation = { _ in }
    ) throws {
        try SubjectIsolationAmbiguityStagingLease.retireAll(
            in: projectPaths,
            beforeOwnedStagingRemoval: beforeOwnedStagingRemoval,
            onLockContention: onLockContention,
            cleanupCheckpoint: cleanupCheckpoint
        )
    }

    public func isolate(
        request: SubjectIsolationRequest,
        onProgress: @escaping @Sendable (SubjectIsolationProgress) -> Void,
        onLog: @escaping @Sendable (String, Bool) -> Void
    ) async throws -> SubjectIsolationOutcome {
        guard request.memoryBudgetBytes > 0,
              !request.toolchainBuildIdentity.isEmpty else {
            throw SubjectIsolationCoordinatorError.invalidProject
        }
        try Task.checkCancellation()
        let paths = request.projectPaths
        do {
            try SubjectIsolationAmbiguityStagingLease.retireAll(
                in: paths,
                onLockContention: ambiguityLockContention
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw SubjectIsolationCoordinatorError.invalidProject
        }
        let canonical: CanonicalSplatPublication
        let poses: [SubjectIsolationCameraPose]
        do {
            canonical = try SubjectIsolationArtifactStore.captureCanonicalPublication(
                paths: paths
            )
            try Task.checkCancellation()
            let sparse = paths.trainingURL.appendingPathComponent(
                "msplat_dataset/sparse/0",
                isDirectory: true
            )
            poses = try SubjectIsolationColmapPoseReader.read(
                sparseDirectory: sparse
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw SubjectIsolationCoordinatorError.invalidProject
        }
        let sampled = SubjectIsolationViewSampler.sample(
            poses,
            maximumCount: IsolationArtifact.maximumMaskCount
        )
        let stages = SubjectIsolationViewSampler.progressiveStages(for: sampled)
        guard !stages.isEmpty else {
            throw SubjectIsolationCoordinatorError.invalidProject
        }
        onProgress(SubjectIsolationProgress(
            phase: .preparing,
            completedUnitCount: 0,
            totalUnitCount: 1
        ))
        try Task.checkCancellation()
        try paths.ensureIsolationDirectories()
        let runID = UUID()
        let ownedStaging: SubjectIsolationOwnedStagingDirectory
        do {
            ownedStaging = try SubjectIsolationOwnedStagingDirectory.create(
                paths: paths,
                runID: runID
            )
        } catch let cleanup as SubjectIsolationCleanupFailure {
            throw cleanup
        } catch {
            throw SubjectIsolationCoordinatorError.invalidProject
        }
        let nativeRuntime: SubjectIsolationNativeRuntimeBinding
        do {
            nativeRuntime = try SubjectIsolationNativeRuntimeBinding.create(
                executableURL: request.nativeExecutableURL,
                metallibURL: request.nativeMetallibURL,
                staging: ownedStaging
            )
        } catch let runtimeCleanup as SubjectIsolationCleanupFailure {
            let cleanupErrors = cleanupOwnedStaging(
                nativeRuntime: nil,
                ownedStaging: ownedStaging
            )
            guard !cleanupErrors.isEmpty else { throw runtimeCleanup }
            throw SubjectIsolationCleanupFailure(
                primaryError: runtimeCleanup,
                cleanupErrors: cleanupErrors
            )
        } catch {
            let primaryError: Error = error is CancellationError
                ? CancellationError()
                : SubjectIsolationCoordinatorError.invalidProject
            let cleanupErrors = cleanupOwnedStaging(
                nativeRuntime: nil,
                ownedStaging: ownedStaging
            )
            if !cleanupErrors.isEmpty {
                throw SubjectIsolationCleanupFailure(
                    primaryError: primaryError,
                    cleanupErrors: cleanupErrors
                )
            }
            throw primaryError
        }

        let prepared: SubjectIsolationPreparedOutcome
        do {
            prepared = try await executePreparedIsolation(
                request: request,
                canonical: canonical,
                sampled: sampled,
                ownedStaging: ownedStaging,
                nativeRuntime: nativeRuntime,
                runID: runID,
                onProgress: onProgress,
                onLog: onLog
            )
        } catch let rollback as SubjectIsolationAuthorityRollbackFailure {
            throw SubjectIsolationCleanupFailure(
                primaryError: rollback.primaryError,
                cleanupErrors: [rollback.rollbackError]
            )
        } catch {
            let cleanupErrors = cleanupOwnedStaging(
                nativeRuntime: nativeRuntime,
                ownedStaging: ownedStaging
            )
            if !cleanupErrors.isEmpty {
                throw SubjectIsolationCleanupFailure(
                    primaryError: error,
                    cleanupErrors: cleanupErrors
                )
            }
            throw error
        }

        guard !prepared.retainsOwnedStagingAuthority else {
            return prepared.outcome
        }
        let cleanupErrors = cleanupOwnedStaging(
            nativeRuntime: nativeRuntime,
            ownedStaging: ownedStaging
        )
        guard cleanupErrors.isEmpty else {
            throw SubjectIsolationCleanupFailure(
                primaryError: nil,
                cleanupErrors: cleanupErrors
            )
        }
        return prepared.outcome
    }

    private func cleanupOwnedStaging(
        nativeRuntime: SubjectIsolationNativeRuntimeBinding?,
        ownedStaging: SubjectIsolationOwnedStagingDirectory
    ) -> [Error] {
        var errors: [Error] = []
        if let nativeRuntime {
            do {
                try nativeRuntime.removePrivateCopies()
            } catch {
                errors.append(error)
            }
        }
        do {
            try ownedStaging.remove()
        } catch {
            errors.append(error)
        }
        return errors
    }

    private func executePreparedIsolation(
        request: SubjectIsolationRequest,
        canonical: CanonicalSplatPublication,
        sampled: [SubjectIsolationCameraPose],
        ownedStaging: SubjectIsolationOwnedStagingDirectory,
        nativeRuntime: SubjectIsolationNativeRuntimeBinding,
        runID: UUID,
        onProgress: @escaping @Sendable (SubjectIsolationProgress) -> Void,
        onLog: @escaping @Sendable (String, Bool) -> Void
    ) async throws -> SubjectIsolationPreparedOutcome {
        let stages = SubjectIsolationViewSampler.progressiveStages(for: sampled)
        guard !stages.isEmpty else {
            throw SubjectIsolationCoordinatorError.invalidProject
        }
        let paths = request.projectPaths
        let staging = ownedStaging.url
        let masksDirectory = ownedStaging.masksURL
        let datasetURL = paths.trainingURL.appendingPathComponent(
            "msplat_dataset",
            isDirectory: true
        )
        let imagesURL = datasetURL.appendingPathComponent("images", isDirectory: true)
        let analysisCacheURL = staging.appendingPathComponent("analysis.cache")
        let digests = SubjectIsolationNativeDigests(
            sourcePly: canonical.outputEvidence.sha256,
            input: canonical.trainingInputDigest,
            geometry: canonical.trainingGeometryDigest,
            selectedFrames: canonical.selectedFramesDigest,
            trainingManifest: canonical.trainingManifestSHA256
        )
        var acquired: [SubjectIsolationAcquiredMask] = []
        var attempt = 0

        for (stageIndex, stage) in stages.enumerated() {
            try Task.checkCancellation()
            let orderedStageViews = (stage.workViews + stage.heldOutViews)
                .sorted { $0.samplePosition < $1.samplePosition }
            let newlyNeeded = orderedStageViews.dropFirst(acquired.count)
            let analysisViews = newlyNeeded.map {
                SubjectIsolationAnalysisView(
                    imageIdentity: $0.imageIdentity,
                    imageURL: imagesURL.appendingPathComponent($0.imageIdentity),
                    nativeCameraIndex: $0.nativeCameraIndex
                )
            }
            if !analysisViews.isEmpty {
                let newMasks = try await maskAcquisition(
                    analysisViews,
                    masksDirectory,
                    acquired.count,
                    { Task.isCancelled }
                )
                guard newMasks.map(\.imageIdentity)
                        == analysisViews.map(\.imageIdentity) else {
                    throw SubjectIsolationCoordinatorError.invalidProject
                }
                acquired.append(contentsOf: newMasks)
            }
            onProgress(SubjectIsolationProgress(
                phase: .segmenting,
                completedUnitCount: acquired.count,
                totalUnitCount: sampled.count
            ))
            let manifestURL = staging.appendingPathComponent(
                "mask-manifest-\(orderedStageViews.count).json"
            )
            try writeNativeMaskManifest(
                to: manifestURL,
                orderedViews: orderedStageViews,
                masks: acquired,
                workIdentities: Set(stage.workViews.map(\.imageIdentity)),
                digests: digests
            )

            let result = try await runNativeAttempt(
                request: request,
                datasetURL: datasetURL,
                maskManifestURL: manifestURL,
                analysisCacheURL: analysisCacheURL,
                stagingURL: staging,
                digests: digests,
                nativeRuntime: nativeRuntime,
                attempt: &attempt,
                anchor: nil,
                onProgress: onProgress,
                onLog: onLog
            )
            if case .completed(let completion) = result {
                return SubjectIsolationPreparedOutcome(
                    outcome: try publish(
                        completion: completion,
                        nativeOutputURL: staging.appendingPathComponent(
                            "attempt-\(attempt - 1).ply"
                        ),
                        request: request,
                        canonical: canonical,
                        acquiredMasks: acquired,
                        stagingURL: staging,
                        runID: runID,
                        nativeRuntime: nativeRuntime,
                        subjectAnchor: nil,
                        onProgress: onProgress
                    ),
                    retainsOwnedStagingAuthority: false
                )
            }

            let isFinal = stageIndex == stages.count - 1
            guard isFinal else { continue }
            var finalResult = result
            if case .ambiguity = result, let anchor = request.anchor {
                finalResult = try await runNativeAttempt(
                    request: request,
                    datasetURL: datasetURL,
                    maskManifestURL: manifestURL,
                    analysisCacheURL: analysisCacheURL,
                    stagingURL: staging,
                    digests: digests,
                    nativeRuntime: nativeRuntime,
                    attempt: &attempt,
                    anchor: anchor,
                    onProgress: onProgress,
                    onLog: onLog
                )
                if case .completed(let completion) = finalResult {
                    return SubjectIsolationPreparedOutcome(
                        outcome: try publish(
                            completion: completion,
                            nativeOutputURL: staging.appendingPathComponent(
                                "attempt-\(attempt - 1).ply"
                            ),
                            request: request,
                            canonical: canonical,
                            acquiredMasks: acquired,
                            stagingURL: staging,
                            runID: runID,
                            nativeRuntime: nativeRuntime,
                            subjectAnchor: anchor,
                            onProgress: onProgress
                        ),
                        retainsOwnedStagingAuthority: false
                    )
                }
            }
            switch finalResult {
            case .noSubject:
                return SubjectIsolationPreparedOutcome(
                    outcome: .noSubject,
                    retainsOwnedStagingAuthority: false
                )
            case .heldOutRejected:
                throw SubjectIsolationCoordinatorError.heldOutRejected
            case .ambiguity(let components):
                let choice = try choiceRequest(
                    components: components,
                    acquiredMasks: acquired,
                    imagesDirectory: imagesURL
                )
                do {
                    try nativeRuntime.removePrivateCopies()
                    let claim = try SubjectIsolationAmbiguityStagingLease.claim(
                        staging: ownedStaging,
                        runID: runID,
                        in: paths,
                        checkpoint: ambiguityLeaseCheckpoint,
                        onLockContention: ambiguityLockContention
                    )
                    defer { claim.release() }
                    return SubjectIsolationPreparedOutcome(
                        outcome: .ambiguity(choice),
                        retainsOwnedStagingAuthority: true
                    )
                } catch let rollback as SubjectIsolationAuthorityRollbackFailure {
                    throw rollback
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    throw SubjectIsolationCoordinatorError.invalidProject
                }
            case .completed:
                throw SubjectIsolationCoordinatorError.invalidProject
            }
        }
        throw SubjectIsolationCoordinatorError.invalidProject
    }

    private func runNativeAttempt(
        request: SubjectIsolationRequest,
        datasetURL: URL,
        maskManifestURL: URL,
        analysisCacheURL: URL,
        stagingURL: URL,
        digests: SubjectIsolationNativeDigests,
        nativeRuntime: SubjectIsolationNativeRuntimeBinding,
        attempt: inout Int,
        anchor: SubjectAnchor?,
        onProgress: @escaping @Sendable (SubjectIsolationProgress) -> Void,
        onLog: @escaping @Sendable (String, Bool) -> Void
    ) async throws -> SubjectIsolationNativeRunResult {
        let outputURL = stagingURL.appendingPathComponent("attempt-\(attempt).ply")
        attempt += 1
        guard !FileManager.default.fileExists(atPath: outputURL.path) else {
            throw SubjectIsolationCoordinatorError.invalidProject
        }
        do {
            try nativeRuntime.revalidate()
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw SubjectIsolationCoordinatorError.invalidProject
        }
        let result = try await nativeOperation(
            SubjectIsolationNativeRunRequest(
                executableURL: nativeRuntime.executableURL,
                metallibURL: nativeRuntime.metallibURL,
                datasetURL: datasetURL,
                sourcePlyURL: request.projectPaths.outputSplatURL,
                maskManifestURL: maskManifestURL,
                analysisCacheURL: analysisCacheURL,
                outputURL: outputURL,
                digests: digests,
                memoryBudgetBytes: request.memoryBudgetBytes,
                anchor: anchor
            ),
            onProgress,
            onLog
        )
        do {
            try nativeRuntime.revalidate()
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw SubjectIsolationCoordinatorError.invalidProject
        }
        return result
    }

    private func publish(
        completion: SubjectIsolationNativeCompletion,
        nativeOutputURL: URL,
        request: SubjectIsolationRequest,
        canonical: CanonicalSplatPublication,
        acquiredMasks: [SubjectIsolationAcquiredMask],
        stagingURL: URL,
        runID: UUID,
        nativeRuntime: SubjectIsolationNativeRuntimeBinding,
        subjectAnchor: SubjectAnchor?,
        onProgress: @escaping @Sendable (SubjectIsolationProgress) -> Void
    ) throws -> SubjectIsolationOutcome {
        do {
            try nativeRuntime.revalidate()
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw SubjectIsolationCoordinatorError.invalidProject
        }
        onProgress(SubjectIsolationProgress(
            phase: .publishing,
            completedUnitCount: 0,
            totalUnitCount: 1
        ))
        let stagedOutputURL = stagingURL.appendingPathComponent("isolated.ply")
        try FileManager.default.moveItem(
            at: nativeOutputURL,
            to: stagedOutputURL
        )
        let masks = acquiredMasks.enumerated().map { index, mask in
            IsolationArtifact.Mask(
                relativePath: "Isolation/masks/\(runID.uuidString)-\(String(format: "%04d", index)).png",
                imageIdentity: mask.imageIdentity,
                imageSHA256: mask.imageSHA256,
                maskSHA256: mask.maskSHA256,
                pixelWidth: mask.pixelWidth,
                pixelHeight: mask.pixelHeight,
                instanceLabels: mask.instanceLabels
            )
        }
        let artifact = IsolationArtifact(
            sourcePublicationID: canonical.publicationID,
            sourcePlySHA256: canonical.outputEvidence.sha256,
            trainingManifestSHA256: canonical.trainingManifestSHA256,
            dataset: .init(
                inputDigest: canonical.trainingInputDigest,
                geometryDigest: canonical.trainingGeometryDigest,
                selectedFramesDigest: canonical.selectedFramesDigest,
                selectedImageOrder: canonical.selectedImageOrder
            ),
            masks: masks,
            toolchainBuildIdentity: request.toolchainBuildIdentity,
            nativeExecutableSHA256: nativeRuntime.executableSHA256,
            visionRequestRevision: 1,
            selectedViewIdentities: completion.selectedViewIdentities,
            heldOutViewIdentities: completion.heldOutViewIdentities,
            policy: .init(
                version: 1,
                minimumMaskConfidence: 0,
                minimumHeldOutMedianIoU: 0.70,
                minimumHeldOutFirstQuartileIoU: 0.50,
                minimumRetainedGaussianFraction: 0.001,
                maximumRetainedGaussianFraction: 0.90
            ),
            subjectAnchor: subjectAnchor,
            metrics: .init(
                meanMaskConfidence: 0,
                heldOutMeanIoU: completion.heldOutMeanIoU,
                heldOutMedianIoU: completion.heldOutMedianIoU,
                heldOutFirstQuartileIoU: completion.heldOutFirstQuartileIoU,
                retainedGaussianFraction: completion.retainedGaussianFraction
            ),
            output: .init(
                identity: runID,
                relativePath: "Output/isolated.ply",
                sha256: completion.outputSHA256,
                byteCount: completion.outputByteCount,
                gaussianCount: completion.gaussianCount,
                sceneBounds: completion.sceneBounds
            )
        )
        let output = try SubjectIsolationArtifactStore.publish(
            artifact,
            stagedOutputURL: stagedOutputURL,
            stagedMasksURL: stagingURL.appendingPathComponent(
                "masks",
                isDirectory: true
            ),
            paths: request.projectPaths
        )
        onProgress(SubjectIsolationProgress(
            phase: .publishing,
            completedUnitCount: 1,
            totalUnitCount: 1
        ))
        return .completed(output)
    }

    private func choiceRequest(
        components: [SubjectIsolationNativeComponent],
        acquiredMasks: [SubjectIsolationAcquiredMask],
        imagesDirectory: URL
    ) throws -> SubjectChoiceRequest {
        let orderedComponents = components.sorted {
            $0.score == $1.score
                ? $0.identity < $1.identity
                : $0.score > $1.score
        }
        guard let clearest = orderedComponents.first,
              let keyframe = bestKeyframe(in: clearest),
              let mask = acquiredMasks.first(where: {
                  $0.imageIdentity == keyframe.imageIdentity
              }) else {
            throw SubjectIsolationCoordinatorError.invalidProject
        }
        let candidates: [SubjectChoiceRequest.Candidate] = orderedComponents.compactMap { component in
            guard let contribution = component.keyframes
                .filter({ $0.imageIdentity == keyframe.imageIdentity })
                .max(by: keyframeLessThan) else {
                return nil
            }
            return SubjectChoiceRequest.Candidate(
                componentIdentity: component.identity,
                instanceLabel: contribution.instanceLabel,
                confidence: min(1, max(0, component.score)),
                previewMaskURL: mask.fileURL
            )
        }
        guard !candidates.isEmpty else {
            throw SubjectIsolationCoordinatorError.invalidProject
        }
        return SubjectChoiceRequest(
            keyframeImageURL: imagesDirectory.appendingPathComponent(
                keyframe.imageIdentity
            ),
            combinedInstanceLabelMaskURL: mask.fileURL,
            pixelWidth: mask.pixelWidth,
            pixelHeight: mask.pixelHeight,
            candidates: candidates
        )
    }

    private func bestKeyframe(
        in component: SubjectIsolationNativeComponent
    ) -> SubjectIsolationNativeKeyframeContribution? {
        component.keyframes.max(by: keyframeLessThan)
    }

    private func keyframeLessThan(
        _ lhs: SubjectIsolationNativeKeyframeContribution,
        _ rhs: SubjectIsolationNativeKeyframeContribution
    ) -> Bool {
        if lhs.fraction != rhs.fraction { return lhs.fraction < rhs.fraction }
        if lhs.weight != rhs.weight { return lhs.weight < rhs.weight }
        return lhs.imageIdentity > rhs.imageIdentity
    }
}

private final class SubjectIsolationOwnedStagingDirectory: @unchecked Sendable {
    let url: URL
    let masksURL: URL

    private let parentDescriptor: Int32
    private let descriptor: Int32
    private let leaf: String
    private let identity: SubjectIsolationFileIdentity
    private let removalLock = NSLock()
    private var wasRemoved = false

    private init(
        url: URL,
        parentDescriptor: Int32,
        descriptor: Int32,
        leaf: String,
        identity: SubjectIsolationFileIdentity
    ) {
        self.url = url
        masksURL = url.appendingPathComponent("masks", isDirectory: true)
        self.parentDescriptor = parentDescriptor
        self.descriptor = descriptor
        self.leaf = leaf
        self.identity = identity
    }

    deinit {
        Darwin.close(descriptor)
        Darwin.close(parentDescriptor)
    }

    static func create(
        paths: ProjectPaths,
        runID: UUID
    ) throws -> SubjectIsolationOwnedStagingDirectory {
        let parent = Darwin.open(
            paths.isolationStagingURL.path,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard parent >= 0 else { throw currentPOSIXError() }
        var keepParent = false
        defer {
            if !keepParent { Darwin.close(parent) }
        }
        let parentIdentity = SubjectIsolationFileIdentity(try status(of: parent))
        guard parentIdentity.isDirectory,
              parentIdentity.owner == UInt32(geteuid()) else {
            throw CocoaError(.fileReadNoPermission)
        }

        let leaf = runID.uuidString
        guard leaf.withCString({ Darwin.mkdirat(parent, $0, mode_t(0o700)) }) == 0 else {
            throw currentPOSIXError()
        }
        var run: Int32 = -1
        var createdRunIdentity: SubjectIsolationFileIdentity?
        do {
            run = leaf.withCString {
                Darwin.openat(
                    parent,
                    $0,
                    O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
                )
            }
            guard run >= 0 else { throw currentPOSIXError() }
            let runIdentity = SubjectIsolationFileIdentity(try status(of: run))
            createdRunIdentity = runIdentity
            guard runIdentity.isDirectory,
                  runIdentity.owner == UInt32(geteuid()),
                  "masks".withCString({
                      Darwin.mkdirat(run, $0, mode_t(0o700))
                  }) == 0,
                  Darwin.fsync(run) == 0,
                  Darwin.fsync(parent) == 0 else {
                throw currentPOSIXError()
            }

            keepParent = true
            return SubjectIsolationOwnedStagingDirectory(
                url: paths.isolationStagingURL(for: runID),
                parentDescriptor: parent,
                descriptor: run,
                leaf: leaf,
                identity: runIdentity
            )
        } catch {
            let primaryError = error
            var cleanupErrors: [Error] = []
            if run >= 0 {
                var visited = 0
                do {
                    try SubjectIsolationAmbiguityStagingLease.removeDirectoryContents(
                        descriptor: run,
                        depth: 0,
                        visitedEntries: &visited,
                        honorsCancellation: false
                    )
                } catch {
                    cleanupErrors.append(error)
                }
                if let createdRunIdentity {
                    do {
                        try SubjectIsolationOwnedEntryRemover.remove(
                            parent: parent,
                            leaf: leaf,
                            expectedIdentity: createdRunIdentity,
                            kind: .directory,
                            relativePath: leaf,
                            honorsCancellation: false
                        )
                    } catch {
                        cleanupErrors.append(error)
                    }
                }
                Darwin.close(run)
            } else {
                var named = stat()
                let statusResult = leaf.withCString {
                    Darwin.fstatat(parent, $0, &named, AT_SYMLINK_NOFOLLOW)
                }
                if statusResult == 0 {
                    do {
                        try SubjectIsolationOwnedEntryRemover.remove(
                            parent: parent,
                            leaf: leaf,
                            expectedIdentity: SubjectIsolationFileIdentity(named),
                            kind: .directory,
                            relativePath: leaf,
                            honorsCancellation: false
                        )
                    } catch {
                        cleanupErrors.append(error)
                    }
                } else if errno != ENOENT {
                    cleanupErrors.append(currentPOSIXError())
                }
            }
            if !cleanupErrors.isEmpty {
                throw SubjectIsolationCleanupFailure(
                    primaryError: primaryError,
                    cleanupErrors: cleanupErrors
                )
            }
            throw primaryError
        }
    }

    func duplicateDescriptor() throws -> Int32 {
        let duplicate = Darwin.fcntl(descriptor, F_DUPFD_CLOEXEC, 0)
        guard duplicate >= 0 else { throw Self.currentPOSIXError() }
        return duplicate
    }

    func matchesBoundDirectory(
        _ candidate: SubjectIsolationFileIdentity
    ) throws -> Bool {
        let live = SubjectIsolationFileIdentity(try Self.status(of: descriptor))
        return identity.sameInode(as: live)
            && live.isDirectory
            && live.owner == UInt32(geteuid())
            && identity.sameInode(as: candidate)
            && candidate.isDirectory
            && candidate.owner == UInt32(geteuid())
    }

    func remove() throws {
        try removalLock.withLock {
            guard !wasRemoved else { return }
            var visitedEntries = 0
            try SubjectIsolationAmbiguityStagingLease.removeDirectoryContents(
                descriptor: descriptor,
                depth: 0,
                visitedEntries: &visitedEntries,
                honorsCancellation: false
            )
            try SubjectIsolationOwnedEntryRemover.remove(
                parent: parentDescriptor,
                leaf: leaf,
                expectedIdentity: identity,
                kind: .directory,
                relativePath: leaf,
                honorsCancellation: false
            )
            wasRemoved = true
        }
    }

    private static func status(of descriptor: Int32) throws -> stat {
        var value = stat()
        guard Darwin.fstat(descriptor, &value) == 0 else {
            throw currentPOSIXError()
        }
        return value
    }

    private static func currentPOSIXError() -> NSError {
        NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
    }
}

private final class SubjectIsolationNativeSourceBinding: @unchecked Sendable {
    let sha256: String

    private let url: URL
    private let descriptor: Int32
    private let identity: SubjectIsolationFileIdentity
    private let requiresExecutablePermission: Bool

    init(url: URL, requiresExecutablePermission: Bool) throws {
        guard url.isFileURL else {
            throw CocoaError(.fileReadInvalidFileName)
        }
        self.url = url
        self.requiresExecutablePermission = requiresExecutablePermission
        descriptor = try Self.openFile(at: url)
        do {
            let status = try Self.status(of: descriptor)
            let identity = SubjectIsolationFileIdentity(status)
            guard identity.isRegularFile,
                  identity.linkCount == 1,
                  identity.byteCount > 0,
                  !requiresExecutablePermission || status.st_mode & mode_t(0o111) != 0 else {
                throw CocoaError(.fileReadCorruptFile)
            }
            self.identity = identity
            sha256 = try Self.hash(descriptor: descriptor)
            try revalidate()
        } catch {
            Darwin.close(descriptor)
            throw error
        }
    }

    deinit {
        Darwin.close(descriptor)
    }

    func revalidate() throws {
        try Task.checkCancellation()
        let first = try Self.status(of: descriptor)
        guard identity == SubjectIsolationFileIdentity(first),
              !requiresExecutablePermission || first.st_mode & mode_t(0o111) != 0,
              try Self.hash(descriptor: descriptor) == sha256,
              identity == SubjectIsolationFileIdentity(try Self.status(of: descriptor)) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let namedDescriptor = try Self.openFile(at: url)
        defer { Darwin.close(namedDescriptor) }
        guard identity == SubjectIsolationFileIdentity(try Self.status(of: namedDescriptor)) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        try Task.checkCancellation()
    }

    func copy(
        to parent: Int32,
        leaf: String,
        mode: mode_t
    ) throws -> (descriptor: Int32, identity: SubjectIsolationFileIdentity) {
        try revalidate()
        let writer = leaf.withCString {
            Darwin.openat(
                parent,
                $0,
                O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
                mode
            )
        }
        guard writer >= 0 else { throw Self.currentPOSIXError() }
        var keepFile = false
        var createdIdentity: SubjectIsolationFileIdentity?
        defer {
            Darwin.close(writer)
            if !keepFile, let createdIdentity {
                Self.unlinkCreatedFileIfSame(
                    parent: parent,
                    leaf: leaf,
                    expectedIdentity: createdIdentity
                )
            }
        }
        let initialIdentity = SubjectIsolationFileIdentity(
            try Self.status(of: writer)
        )
        createdIdentity = initialIdentity
        guard initialIdentity.isRegularFile,
              initialIdentity.owner == UInt32(geteuid()),
              initialIdentity.linkCount == 1 else {
            throw CocoaError(.fileWriteNoPermission)
        }

        var offset: Int64 = 0
        var buffer = [UInt8](repeating: 0, count: 1_048_576)
        while true {
            try Task.checkCancellation()
            let count = buffer.withUnsafeMutableBytes {
                Darwin.pread(descriptor, $0.baseAddress, $0.count, off_t(offset))
            }
            if count < 0, errno == EINTR { continue }
            guard count >= 0 else { throw Self.currentPOSIXError() }
            if count == 0 { break }
            var written = 0
            while written < count {
                let result = buffer.withUnsafeBytes {
                    Darwin.write(
                        writer,
                        $0.baseAddress?.advanced(by: written),
                        count - written
                    )
                }
                if result < 0, errno == EINTR { continue }
                guard result > 0 else { throw Self.currentPOSIXError() }
                written += result
            }
            offset += Int64(count)
        }
        guard Darwin.fchmod(writer, mode) == 0,
              Darwin.fsync(writer) == 0 else {
            throw Self.currentPOSIXError()
        }
        let copiedIdentity = SubjectIsolationFileIdentity(try Self.status(of: writer))
        guard copiedIdentity.isRegularFile,
              copiedIdentity.linkCount == 1,
              copiedIdentity.byteCount == identity.byteCount else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let reader = leaf.withCString {
            Darwin.openat(
                parent,
                $0,
                O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC
            )
        }
        guard reader >= 0 else { throw Self.currentPOSIXError() }
        do {
            guard copiedIdentity == SubjectIsolationFileIdentity(try Self.status(of: reader)),
                  try Self.hash(descriptor: reader) == sha256 else {
                throw CocoaError(.fileReadCorruptFile)
            }
            try revalidate()
            keepFile = true
            return (reader, copiedIdentity)
        } catch {
            Darwin.close(reader)
            throw error
        }
    }

    fileprivate static func openFile(at url: URL) throws -> Int32 {
        while true {
            let descriptor = Darwin.open(
                url.path,
                O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC
            )
            if descriptor >= 0 { return descriptor }
            let code = errno
            if code == EINTR { continue }
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(code))
        }
    }

    fileprivate static func status(of descriptor: Int32) throws -> stat {
        while true {
            var status = stat()
            if Darwin.fstat(descriptor, &status) == 0 { return status }
            let code = errno
            if code == EINTR { continue }
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(code))
        }
    }

    fileprivate static func hash(descriptor: Int32) throws -> String {
        var hasher = SHA256()
        var offset: Int64 = 0
        var buffer = [UInt8](repeating: 0, count: 1_048_576)
        while true {
            try Task.checkCancellation()
            let count = buffer.withUnsafeMutableBytes {
                Darwin.pread(descriptor, $0.baseAddress, $0.count, off_t(offset))
            }
            if count < 0, errno == EINTR { continue }
            guard count >= 0 else { throw currentPOSIXError() }
            if count == 0 { break }
            hasher.update(data: Data(buffer[..<count]))
            offset += Int64(count)
        }
        try Task.checkCancellation()
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func unlinkCreatedFileIfSame(
        parent: Int32,
        leaf: String,
        expectedIdentity: SubjectIsolationFileIdentity
    ) {
        try? SubjectIsolationOwnedEntryRemover.remove(
            parent: parent,
            leaf: leaf,
            expectedIdentity: expectedIdentity,
            kind: .regularFile(),
            relativePath: leaf,
            honorsCancellation: false
        )
    }

    fileprivate static func currentPOSIXError() -> NSError {
        NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
    }
}

private final class SubjectIsolationNativeRuntimeBinding: @unchecked Sendable {
    let executableURL: URL
    let metallibURL: URL
    let executableSHA256: String

    private static let runtimeLeaf = ".native-runtime"
    private static let executableLeaf = "easysplat-train"
    private static let metallibLeaf = "default.metallib"
    private let metallibSHA256: String
    private let stagingDescriptor: Int32
    private let runtimeDescriptor: Int32
    private let runtimeIdentity: SubjectIsolationFileIdentity
    private let namedExecutableURL: URL
    private let namedMetallibURL: URL
    private let executableDescriptor: Int32
    private let executableIdentity: SubjectIsolationFileIdentity
    private let metallibDescriptor: Int32
    private let metallibIdentity: SubjectIsolationFileIdentity
    private let cleanupLock = NSLock()
    private var copiesRemoved = false

    private init(
        stagingURL: URL,
        executableSHA256: String,
        metallibSHA256: String,
        stagingDescriptor: Int32,
        runtimeDescriptor: Int32,
        runtimeIdentity: SubjectIsolationFileIdentity,
        executableDescriptor: Int32,
        executableIdentity: SubjectIsolationFileIdentity,
        metallibDescriptor: Int32,
        metallibIdentity: SubjectIsolationFileIdentity
    ) {
        let runtimeURL = stagingURL.appendingPathComponent(
            Self.runtimeLeaf,
            isDirectory: true
        )
        namedExecutableURL = runtimeURL.appendingPathComponent(Self.executableLeaf)
        namedMetallibURL = runtimeURL.appendingPathComponent(Self.metallibLeaf)
        executableURL = Self.volumeURL(for: executableIdentity)
        metallibURL = Self.volumeURL(for: metallibIdentity)
        self.executableSHA256 = executableSHA256
        self.metallibSHA256 = metallibSHA256
        self.stagingDescriptor = stagingDescriptor
        self.runtimeDescriptor = runtimeDescriptor
        self.runtimeIdentity = runtimeIdentity
        self.executableDescriptor = executableDescriptor
        self.executableIdentity = executableIdentity
        self.metallibDescriptor = metallibDescriptor
        self.metallibIdentity = metallibIdentity
    }

    deinit {
        Darwin.close(metallibDescriptor)
        Darwin.close(executableDescriptor)
        Darwin.close(runtimeDescriptor)
        Darwin.close(stagingDescriptor)
    }

    static func create(
        executableURL: URL,
        metallibURL: URL,
        staging: SubjectIsolationOwnedStagingDirectory
    ) throws -> SubjectIsolationNativeRuntimeBinding {
        let executableSource = try SubjectIsolationNativeSourceBinding(
            url: executableURL,
            requiresExecutablePermission: true
        )
        let metallibSource = try SubjectIsolationNativeSourceBinding(
            url: metallibURL,
            requiresExecutablePermission: false
        )
        let stagingDescriptor = try staging.duplicateDescriptor()
        var keepStaging = false
        defer {
            if !keepStaging { Darwin.close(stagingDescriptor) }
        }
        guard runtimeLeaf.withCString({
            Darwin.mkdirat(stagingDescriptor, $0, mode_t(0o700))
        }) == 0 else {
            throw SubjectIsolationNativeSourceBinding.currentPOSIXError()
        }
        var runtimeDescriptor: Int32 = -1
        var executableDescriptor: Int32 = -1
        var metallibDescriptor: Int32 = -1
        var keepRuntime = false
        defer {
            if !keepRuntime {
                if executableDescriptor >= 0 {
                    _ = Darwin.fchflags(executableDescriptor, 0)
                    Darwin.close(executableDescriptor)
                }
                if metallibDescriptor >= 0 {
                    _ = Darwin.fchflags(metallibDescriptor, 0)
                    Darwin.close(metallibDescriptor)
                }
                if runtimeDescriptor >= 0 {
                    _ = Darwin.fchflags(runtimeDescriptor, 0)
                    Darwin.close(runtimeDescriptor)
                }
            }
        }
        runtimeDescriptor = runtimeLeaf.withCString {
            Darwin.openat(
                stagingDescriptor,
                $0,
                O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
            )
        }
        guard runtimeDescriptor >= 0 else {
            throw SubjectIsolationNativeSourceBinding.currentPOSIXError()
        }
        let executableCopy = try executableSource.copy(
            to: runtimeDescriptor,
            leaf: executableLeaf,
            mode: mode_t(0o500)
        )
        executableDescriptor = executableCopy.descriptor
        let metallibCopy = try metallibSource.copy(
            to: runtimeDescriptor,
            leaf: metallibLeaf,
            mode: mode_t(0o400)
        )
        metallibDescriptor = metallibCopy.descriptor
        guard Darwin.fchflags(executableDescriptor, UInt32(UF_IMMUTABLE)) == 0,
              Darwin.fchflags(metallibDescriptor, UInt32(UF_IMMUTABLE)) == 0,
              Darwin.fchflags(runtimeDescriptor, UInt32(UF_IMMUTABLE)) == 0,
              Darwin.fsync(runtimeDescriptor) == 0,
              Darwin.fsync(stagingDescriptor) == 0 else {
            throw SubjectIsolationNativeSourceBinding.currentPOSIXError()
        }
        let hardenedRuntimeIdentity = SubjectIsolationFileIdentity(
            try SubjectIsolationNativeSourceBinding.status(of: runtimeDescriptor)
        )
        let hardenedExecutableIdentity = SubjectIsolationFileIdentity(
            try SubjectIsolationNativeSourceBinding.status(of: executableDescriptor)
        )
        let hardenedMetallibIdentity = SubjectIsolationFileIdentity(
            try SubjectIsolationNativeSourceBinding.status(of: metallibDescriptor)
        )
        keepStaging = true
        keepRuntime = true
        let binding = SubjectIsolationNativeRuntimeBinding(
            stagingURL: staging.url,
            executableSHA256: executableSource.sha256,
            metallibSHA256: metallibSource.sha256,
            stagingDescriptor: stagingDescriptor,
            runtimeDescriptor: runtimeDescriptor,
            runtimeIdentity: hardenedRuntimeIdentity,
            executableDescriptor: executableDescriptor,
            executableIdentity: hardenedExecutableIdentity,
            metallibDescriptor: metallibDescriptor,
            metallibIdentity: hardenedMetallibIdentity
        )
        do {
            try binding.revalidate()
            return binding
        } catch {
            let primaryError = error
            do {
                try binding.removePrivateCopies()
            } catch {
                throw SubjectIsolationCleanupFailure(
                    primaryError: primaryError,
                    cleanupErrors: [error]
                )
            }
            throw primaryError
        }
    }

    func revalidate() throws {
        let runtimeStatus = try SubjectIsolationNativeSourceBinding.status(
            of: runtimeDescriptor
        )
        var namedRuntime = stat()
        let liveRuntimeIdentity = SubjectIsolationFileIdentity(runtimeStatus)
        guard runtimeIdentity == liveRuntimeIdentity,
              liveRuntimeIdentity.isDirectory,
              liveRuntimeIdentity.owner == UInt32(geteuid()),
              liveRuntimeIdentity.permissions == 0o700,
              runtimeStatus.st_flags & UInt32(UF_IMMUTABLE) != 0,
              Self.runtimeLeaf.withCString({
                  Darwin.fstatat(
                      stagingDescriptor,
                      $0,
                      &namedRuntime,
                      AT_SYMLINK_NOFOLLOW
                  )
              }) == 0,
              runtimeIdentity == SubjectIsolationFileIdentity(namedRuntime),
              SubjectIsolationFileIdentity(namedRuntime).isDirectory,
              namedRuntime.st_uid == geteuid(),
              UInt32(namedRuntime.st_mode) & 0o7777 == 0o700 else {
            throw CocoaError(.fileReadCorruptFile)
        }
        try validateCopy(
            descriptor: executableDescriptor,
            identity: executableIdentity,
            leaf: Self.executableLeaf,
            namedURL: namedExecutableURL,
            invocationURL: executableURL,
            sha256: executableSHA256
        )
        try validateCopy(
            descriptor: metallibDescriptor,
            identity: metallibIdentity,
            leaf: Self.metallibLeaf,
            namedURL: namedMetallibURL,
            invocationURL: metallibURL,
            sha256: metallibSHA256
        )
        try Task.checkCancellation()
    }

    func removePrivateCopies() throws {
        try cleanupLock.withLock {
            guard !copiesRemoved else { return }
            var firstFlagError: NSError?
            for descriptor in [
                executableDescriptor,
                metallibDescriptor,
                runtimeDescriptor,
            ] where Darwin.fchflags(descriptor, 0) != 0 {
                if firstFlagError == nil {
                    firstFlagError = SubjectIsolationNativeSourceBinding
                        .currentPOSIXError()
                }
            }
            if let firstFlagError {
                throw firstFlagError
            }
            try unlinkExact(
                parent: runtimeDescriptor,
                leaf: Self.executableLeaf,
                identity: executableIdentity,
                flags: 0
            )
            try unlinkExact(
                parent: runtimeDescriptor,
                leaf: Self.metallibLeaf,
                identity: metallibIdentity,
                flags: 0
            )
            guard Darwin.fsync(runtimeDescriptor) == 0 else {
                throw SubjectIsolationNativeSourceBinding.currentPOSIXError()
            }
            try unlinkExact(
                parent: stagingDescriptor,
                leaf: Self.runtimeLeaf,
                identity: runtimeIdentity,
                flags: AT_REMOVEDIR
            )
            guard Darwin.fsync(stagingDescriptor) == 0 else {
                throw SubjectIsolationNativeSourceBinding.currentPOSIXError()
            }
            copiesRemoved = true
        }
    }

    private func validateCopy(
        descriptor: Int32,
        identity: SubjectIsolationFileIdentity,
        leaf: String,
        namedURL: URL,
        invocationURL: URL,
        sha256: String
    ) throws {
        let first = try SubjectIsolationNativeSourceBinding.status(of: descriptor)
        let firstIdentity = SubjectIsolationFileIdentity(first)
        guard identity == firstIdentity,
              firstIdentity.isRegularFile,
              firstIdentity.owner == UInt32(geteuid()),
              firstIdentity.linkCount == 1,
              firstIdentity.permissions == identity.permissions,
              first.st_flags & UInt32(UF_IMMUTABLE) != 0,
              try SubjectIsolationNativeSourceBinding.hash(descriptor: descriptor) == sha256,
              identity == SubjectIsolationFileIdentity(
                  try SubjectIsolationNativeSourceBinding.status(of: descriptor)
              ) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let named = leaf.withCString {
            Darwin.openat(
                runtimeDescriptor,
                $0,
                O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC
            )
        }
        guard named >= 0 else {
            throw SubjectIsolationNativeSourceBinding.currentPOSIXError()
        }
        defer { Darwin.close(named) }
        let namedPathDescriptor = try SubjectIsolationNativeSourceBinding.openFile(
            at: namedURL
        )
        defer { Darwin.close(namedPathDescriptor) }
        let invocationDescriptor = try SubjectIsolationNativeSourceBinding.openFile(
            at: invocationURL
        )
        defer { Darwin.close(invocationDescriptor) }
        guard identity == SubjectIsolationFileIdentity(
            try SubjectIsolationNativeSourceBinding.status(of: named)
        ),
        identity == SubjectIsolationFileIdentity(
            try SubjectIsolationNativeSourceBinding.status(of: namedPathDescriptor)
        ),
        identity == SubjectIsolationFileIdentity(
            try SubjectIsolationNativeSourceBinding.status(of: invocationDescriptor)
        ) else {
            throw CocoaError(.fileReadCorruptFile)
        }
    }

    private static func volumeURL(
        for identity: SubjectIsolationFileIdentity
    ) -> URL {
        URL(
            fileURLWithPath: "/.vol/\(identity.device)/\(identity.inode)",
            isDirectory: false
        )
    }

    private func unlinkExact(
        parent: Int32,
        leaf: String,
        identity: SubjectIsolationFileIdentity,
        flags: Int32
    ) throws {
        try SubjectIsolationOwnedEntryRemover.remove(
            parent: parent,
            leaf: leaf,
            expectedIdentity: identity,
            kind: flags == AT_REMOVEDIR ? .directory : .regularFile(),
            relativePath: leaf,
            honorsCancellation: false
        )
    }
}

private enum SubjectIsolationOwnedEntryKind {
    case regularFile(maximumByteCount: Int64? = nil)
    case directory
}

private enum SubjectIsolationOwnedEntryRemover {
    private static let quarantinePrefix = ".easysplat-removing-"

    static func remove(
        parent: Int32,
        leaf: String,
        expectedIdentity: SubjectIsolationFileIdentity,
        kind: SubjectIsolationOwnedEntryKind,
        relativePath: String,
        checkpoint: SubjectIsolationAmbiguityCleanupCheckpointOperation = { _ in },
        honorsCancellation: Bool = true
    ) throws {
        if honorsCancellation { try Task.checkCancellation() }
        var named = stat()
        guard leaf.withCString({
            Darwin.fstatat(parent, $0, &named, AT_SYMLINK_NOFOLLOW)
        }) == 0 else {
            throw currentPOSIXError()
        }
        let namedIdentity = SubjectIsolationFileIdentity(named)
        guard expectedIdentity.sameInode(as: namedIdentity),
              namedIdentity.owner == UInt32(geteuid()),
              accepts(namedIdentity, as: kind) else {
            throw CocoaError(.fileWriteUnknown)
        }

        try checkpoint(.willQuarantine(relativePath: relativePath))
        if honorsCancellation { try Task.checkCancellation() }
        let quarantineLeaf = quarantinePrefix + UUID().uuidString
        let renamed = leaf.withCString { source in
            quarantineLeaf.withCString { destination in
                Darwin.renameatx_np(
                    parent,
                    source,
                    parent,
                    destination,
                    UInt32(RENAME_EXCL | RENAME_NOFOLLOW_ANY)
                )
            }
        }
        guard renamed == 0 else { throw currentPOSIXError() }

        var quarantined = stat()
        let quarantineStatus = quarantineLeaf.withCString {
            Darwin.fstatat(parent, $0, &quarantined, AT_SYMLINK_NOFOLLOW)
        }
        let quarantinedIdentity = SubjectIsolationFileIdentity(quarantined)
        guard quarantineStatus == 0,
              quarantinedIdentity.owner == UInt32(geteuid()),
              accepts(quarantinedIdentity, as: kind) else {
            throw CocoaError(.fileWriteUnknown)
        }
        guard expectedIdentity.sameInode(as: quarantinedIdentity) else {
            try restoreQuarantinedEntry(
                parent: parent,
                quarantineLeaf: quarantineLeaf,
                originalLeaf: leaf,
                expectedIdentity: quarantinedIdentity
            )
            throw CocoaError(.fileWriteUnknown)
        }

        let flags: Int32
        switch kind {
        case .regularFile:
            flags = 0
        case .directory:
            flags = AT_REMOVEDIR
        }

        var checkpointError: Error?
        do {
            try checkpoint(.willUnlinkQuarantined(
                relativePath: relativePath,
                quarantineLeaf: quarantineLeaf
            ))
        } catch {
            checkpointError = error
        }
        var beforeUnlink = stat()
        let beforeUnlinkStatus = quarantineLeaf.withCString {
            Darwin.fstatat(parent, $0, &beforeUnlink, AT_SYMLINK_NOFOLLOW)
        }
        guard beforeUnlinkStatus == 0,
              SubjectIsolationFileIdentity(beforeUnlink) == quarantinedIdentity else {
            throw CocoaError(.fileWriteUnknown)
        }

        if let checkpointError {
            try restoreQuarantinedEntry(
                parent: parent,
                quarantineLeaf: quarantineLeaf,
                originalLeaf: leaf,
                expectedIdentity: quarantinedIdentity
            )
            throw checkpointError
        }
        if honorsCancellation, Task.isCancelled {
            try restoreQuarantinedEntry(
                parent: parent,
                quarantineLeaf: quarantineLeaf,
                originalLeaf: leaf,
                expectedIdentity: quarantinedIdentity
            )
            throw CancellationError()
        }

        let unlinkResult = quarantineLeaf.withCString {
            Darwin.unlinkat(parent, $0, flags)
        }
        guard unlinkResult == 0 else {
            let unlinkError = currentPOSIXError()
            try restoreQuarantinedEntry(
                parent: parent,
                quarantineLeaf: quarantineLeaf,
                originalLeaf: leaf,
                expectedIdentity: quarantinedIdentity
            )
            throw unlinkError
        }
        guard Darwin.fsync(parent) == 0 else {
            throw currentPOSIXError()
        }
    }

    private static func accepts(
        _ identity: SubjectIsolationFileIdentity,
        as kind: SubjectIsolationOwnedEntryKind
    ) -> Bool {
        switch kind {
        case .regularFile(let maximumByteCount):
            return identity.isRegularFile
                && identity.linkCount == 1
                && maximumByteCount.map { identity.byteCount <= $0 } != false
        case .directory:
            return identity.isDirectory
        }
    }

    private static func restoreQuarantinedEntry(
        parent: Int32,
        quarantineLeaf: String,
        originalLeaf: String,
        expectedIdentity: SubjectIsolationFileIdentity
    ) throws {
        var named = stat()
        guard quarantineLeaf.withCString({
            Darwin.fstatat(parent, $0, &named, AT_SYMLINK_NOFOLLOW)
        }) == 0,
        SubjectIsolationFileIdentity(named) == expectedIdentity else {
            throw CocoaError(.fileWriteUnknown)
        }
        let restored = quarantineLeaf.withCString { source in
            originalLeaf.withCString { destination in
                Darwin.renameatx_np(
                    parent,
                    source,
                    parent,
                    destination,
                    UInt32(RENAME_EXCL | RENAME_NOFOLLOW_ANY)
                )
            }
        }
        guard restored == 0, Darwin.fsync(parent) == 0 else {
            throw currentPOSIXError()
        }
    }

    private static func currentPOSIXError() -> NSError {
        NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
    }
}

private final class SubjectIsolationAmbiguityLifecycleLock: @unchecked Sendable {
    private static let leaf = ".ambiguity-lifecycle.lock"
    private let directoryDescriptor: Int32
    private let legacyDescriptor: Int32
    private let releaseLock = NSLock()
    private var wasReleased = false

    private init(directoryDescriptor: Int32, legacyDescriptor: Int32) {
        self.directoryDescriptor = directoryDescriptor
        self.legacyDescriptor = legacyDescriptor
    }

    deinit {
        release()
        Darwin.close(legacyDescriptor)
        Darwin.close(directoryDescriptor)
    }

    static func acquire(
        parent: Int32,
        onContention: SubjectIsolationAmbiguityLockContentionOperation
    ) throws -> SubjectIsolationAmbiguityLifecycleLock {
        try Task.checkCancellation()
        let directoryDescriptor = ".".withCString {
            Darwin.openat(
                parent,
                $0,
                O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
            )
        }
        guard directoryDescriptor >= 0 else { throw currentPOSIXError() }
        var keepDirectory = false
        defer {
            if !keepDirectory { Darwin.close(directoryDescriptor) }
        }
        let parentIdentity = SubjectIsolationFileIdentity(try status(of: parent))
        let directoryIdentity = SubjectIsolationFileIdentity(
            try status(of: directoryDescriptor)
        )
        guard parentIdentity == directoryIdentity,
              directoryIdentity.isDirectory,
              directoryIdentity.owner == UInt32(geteuid()) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        var reportedContention = false
        try lockDirectory(
            directoryDescriptor,
            reportedContention: &reportedContention,
            onContention: onContention
        )
        var keepDirectoryLock = false
        defer {
            if !keepDirectoryLock {
                _ = subjectIsolationFlock(directoryDescriptor, LOCK_UN)
            }
        }

        let opened = try openLockFile(parent: parent)
        let legacyDescriptor = opened.descriptor
        var keepLegacy = false
        defer {
            if !keepLegacy { Darwin.close(legacyDescriptor) }
        }
        guard !opened.created
                || Darwin.fchmod(legacyDescriptor, mode_t(0o600)) == 0 else {
            throw currentPOSIXError()
        }
        let identity = SubjectIsolationFileIdentity(
            try status(of: legacyDescriptor)
        )
        guard identity.isRegularFile,
              identity.owner == UInt32(geteuid()),
              identity.linkCount == 1,
              identity.permissions == 0o600 else {
            throw CocoaError(.fileReadNoPermission)
        }

        try lockLegacyFile(
            legacyDescriptor,
            reportedContention: &reportedContention,
            onContention: onContention
        )
        var named = stat()
        guard leaf.withCString({
            Darwin.fstatat(parent, $0, &named, AT_SYMLINK_NOFOLLOW)
        }) == 0,
        identity.sameInode(as: named),
        SubjectIsolationFileIdentity(named).isRegularFile,
        named.st_uid == geteuid(),
        named.st_nlink == 1,
        UInt32(named.st_mode) & 0o7777 == 0o600 else {
            unlockLegacyFile(legacyDescriptor)
            throw CocoaError(.fileReadCorruptFile)
        }
        let reboundDirectory = SubjectIsolationFileIdentity(
            try status(of: directoryDescriptor)
        )
        guard directoryIdentity.sameInode(as: reboundDirectory),
              reboundDirectory.isDirectory,
              reboundDirectory.owner == UInt32(geteuid()) else {
            unlockLegacyFile(legacyDescriptor)
            throw CocoaError(.fileReadCorruptFile)
        }
        keepLegacy = true
        keepDirectory = true
        keepDirectoryLock = true
        return SubjectIsolationAmbiguityLifecycleLock(
            directoryDescriptor: directoryDescriptor,
            legacyDescriptor: legacyDescriptor
        )
    }

    private static func openLockFile(
        parent: Int32
    ) throws -> (descriptor: Int32, created: Bool) {
        while true {
            let descriptor = leaf.withCString {
                Darwin.openat(
                    parent,
                    $0,
                    O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
                    mode_t(0o600)
                )
            }
            if descriptor >= 0 { return (descriptor, true) }
            let code = errno
            if code == EINTR {
                try Task.checkCancellation()
                continue
            }
            guard code == EEXIST else {
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(code))
            }
            break
        }

        while true {
            try Task.checkCancellation()
            let descriptor = leaf.withCString {
                Darwin.openat(
                    parent,
                    $0,
                    O_RDWR | O_NOFOLLOW | O_CLOEXEC
                )
            }
            if descriptor >= 0 { return (descriptor, false) }
            let code = errno
            if code == EINTR { continue }
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(code))
        }
    }

    func release() {
        releaseLock.withLock {
            guard !wasReleased else { return }
            Self.unlockLegacyFile(legacyDescriptor)
            _ = subjectIsolationFlock(directoryDescriptor, LOCK_UN)
            wasReleased = true
        }
    }

    private static func lockDirectory(
        _ descriptor: Int32,
        reportedContention: inout Bool,
        onContention: SubjectIsolationAmbiguityLockContentionOperation
    ) throws {
        while true {
            try Task.checkCancellation()
            if subjectIsolationFlock(descriptor, LOCK_EX | LOCK_NB) == 0 { return }
            let code = errno
            if code == EINTR { continue }
            if code == EWOULDBLOCK || code == EAGAIN || code == EACCES {
                if !reportedContention {
                    onContention()
                    reportedContention = true
                }
                try waitForRetry()
                continue
            }
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(code))
        }
    }

    private static func lockLegacyFile(
        _ descriptor: Int32,
        reportedContention: inout Bool,
        onContention: SubjectIsolationAmbiguityLockContentionOperation
    ) throws {
        var lock = Darwin.flock()
        lock.l_start = 0
        lock.l_len = 0
        lock.l_pid = 0
        lock.l_type = Int16(F_WRLCK)
        lock.l_whence = Int16(SEEK_SET)
        while true {
            try Task.checkCancellation()
            let result = withUnsafeMutablePointer(to: &lock) {
                Darwin.fcntl(descriptor, F_OFD_SETLK, $0)
            }
            if result == 0 { return }
            if errno == EINTR { continue }
            if errno == EAGAIN || errno == EACCES {
                if !reportedContention {
                    onContention()
                    reportedContention = true
                }
                try waitForRetry()
                continue
            }
            throw currentPOSIXError()
        }
    }

    private static func unlockLegacyFile(_ descriptor: Int32) {
        var lock = Darwin.flock()
        lock.l_start = 0
        lock.l_len = 0
        lock.l_pid = 0
        lock.l_type = Int16(F_UNLCK)
        lock.l_whence = Int16(SEEK_SET)
        while withUnsafeMutablePointer(to: &lock, {
            Darwin.fcntl(descriptor, F_OFD_SETLK, $0)
        }) != 0, errno == EINTR {}
    }

    private static func waitForRetry() throws {
        try Task.checkCancellation()
        while Darwin.usleep(10_000) != 0 {
            if errno == EINTR {
                try Task.checkCancellation()
                continue
            }
            throw currentPOSIXError()
        }
        try Task.checkCancellation()
    }

    private static func status(of descriptor: Int32) throws -> stat {
        var value = stat()
        guard Darwin.fstat(descriptor, &value) == 0 else {
            throw currentPOSIXError()
        }
        return value
    }

    private static func currentPOSIXError() -> NSError {
        NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
    }
}

private enum SubjectIsolationAmbiguityStagingLease {
    private static let markerLeaf = ".ambiguity-owner-v1"
    private static let pendingMarkerLeaf = ".ambiguity-owner-v1.pending"
    private static let retiredPrefix = ".retired-ambiguity-"
    private static let maximumCleanupDepth = 64
    private static let maximumCleanupEntries = 50_000

    private struct Ownership: Equatable {
        let runID: UUID
        let token: UUID
        let stagingDevice: UInt64
        let stagingInode: UInt64

        init(runID: UUID, identity: SubjectIsolationFileIdentity) {
            self.runID = runID
            token = UUID()
            stagingDevice = identity.device
            stagingInode = identity.inode
        }

        init(data: Data) throws {
            guard data.count <= 256,
                  let value = String(data: data, encoding: .utf8) else {
                throw CocoaError(.fileReadCorruptFile)
            }
            let fields = value.split(
                separator: "\n",
                omittingEmptySubsequences: false
            )
            guard fields.count == 5,
                  fields[0] == "easysplat-subject-ambiguity-v1",
                  let runID = UUID(uuidString: String(fields[1])),
                  let token = UUID(uuidString: String(fields[2])),
                  fields[1] == Substring(runID.uuidString),
                  fields[2] == Substring(token.uuidString),
                  let device = UInt64(fields[3]),
                  let inode = UInt64(fields[4]) else {
                throw CocoaError(.fileReadCorruptFile)
            }
            self.runID = runID
            self.token = token
            stagingDevice = device
            stagingInode = inode
        }

        var data: Data {
            Data(
                """
                easysplat-subject-ambiguity-v1
                \(runID.uuidString)
                \(token.uuidString)
                \(stagingDevice)
                \(stagingInode)
                """.utf8
            )
        }

        var retiredLeaf: String {
            "\(retiredPrefix)\(runID.uuidString)-\(token.uuidString)"
        }

        func owns(_ identity: SubjectIsolationFileIdentity) -> Bool {
            stagingDevice == identity.device && stagingInode == identity.inode
        }
    }

    static func claim(
        staging ownedStaging: SubjectIsolationOwnedStagingDirectory,
        runID: UUID,
        in paths: ProjectPaths,
        checkpoint: SubjectIsolationAmbiguityLeaseCheckpointOperation,
        onLockContention: SubjectIsolationAmbiguityLockContentionOperation
    ) throws -> SubjectIsolationAmbiguityLifecycleLock {
        let stagingURL = ownedStaging.url
        let stagingRootURL = paths.isolationStagingURL.standardizedFileURL
        guard stagingURL.standardizedFileURL.deletingLastPathComponent()
                == stagingRootURL,
              stagingURL.lastPathComponent == runID.uuidString else {
            throw CocoaError(.fileReadInvalidFileName)
        }
        let isolation = try openOwnedDirectory(at: paths.isolationURL)
        defer { Darwin.close(isolation) }
        let lifecycle = try SubjectIsolationAmbiguityLifecycleLock.acquire(
            parent: isolation,
            onContention: onLockContention
        )
        try Task.checkCancellation()
        try checkpoint(.claimWillBindStaging, paths.isolationURL)
        let stagingRoot = try openOwnedDirectory(at: stagingRootURL)
        defer { Darwin.close(stagingRoot) }
        let staging = try openOwnedDirectory(
            parent: stagingRoot,
            leaf: runID.uuidString
        )
        defer { Darwin.close(staging) }
        let identity = SubjectIsolationFileIdentity(try status(of: staging))
        guard try ownedStaging.matchesBoundDirectory(identity) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let markerIdentity = try writeMarker(
            Ownership(runID: runID, identity: identity),
            to: isolation,
            isolationURL: paths.isolationURL,
            checkpoint: checkpoint
        )
        do {
            guard Darwin.fsync(stagingRoot) == 0 else {
                throw currentPOSIXError()
            }
            try checkpoint(.claimDurable, paths.isolationURL)
            return lifecycle
        } catch {
            let claimError = error
            do {
                try removeNamedFile(
                    parent: isolation,
                    leaf: markerLeaf,
                    expectedIdentity: markerIdentity,
                    honorsCancellation: false
                )
                guard Darwin.fsync(isolation) == 0 else {
                    throw currentPOSIXError()
                }
            } catch {
                lifecycle.release()
                throw SubjectIsolationAuthorityRollbackFailure(
                    primaryError: claimError,
                    rollbackError: error
                )
            }
            lifecycle.release()
            throw claimError
        }
    }

    static func retireAll(
        in paths: ProjectPaths,
        beforeOwnedStagingRemoval: (URL) throws -> Void = { _ in },
        onLockContention: SubjectIsolationAmbiguityLockContentionOperation = {},
        cleanupCheckpoint: SubjectIsolationAmbiguityCleanupCheckpointOperation = { _ in }
    ) throws {
        let isolation: Int32
        do {
            isolation = try openOwnedDirectory(at: paths.isolationURL)
        } catch let error as NSError
            where error.domain == NSPOSIXErrorDomain && error.code == Int(ENOENT) {
            return
        }
        defer { Darwin.close(isolation) }
        let lifecycle = try SubjectIsolationAmbiguityLifecycleLock.acquire(
            parent: isolation,
            onContention: onLockContention
        )
        defer { lifecycle.release() }
        try Task.checkCancellation()
        try removeInterruptedPendingMarker(
            from: isolation,
            cleanupCheckpoint: cleanupCheckpoint
        )
        guard let (ownership, markerIdentity) =
                try readMarkerIfPresent(from: isolation) else {
            return
        }

        let stagingRootURL = paths.isolationStagingURL.standardizedFileURL
        try cleanupCheckpoint(.willOpenStagingRoot)
        let stagingRoot = try openOwnedDirectory(at: stagingRootURL)
        defer { Darwin.close(stagingRoot) }
        let activeLeaf = ownership.runID.uuidString
        var ownedDirectory = try openOwnedDirectoryIfPresent(
            parent: stagingRoot,
            leaf: activeLeaf
        )

        if let active = ownedDirectory {
            let activeIdentity = SubjectIsolationFileIdentity(
                try status(of: active)
            )
            guard ownership.owns(activeIdentity) else {
                Darwin.close(active)
                throw CocoaError(.fileReadCorruptFile)
            }
            let moved = activeLeaf.withCString { source in
                ownership.retiredLeaf.withCString { destination in
                    Darwin.renameatx_np(
                        stagingRoot,
                        source,
                        stagingRoot,
                        destination,
                        UInt32(RENAME_EXCL | RENAME_NOFOLLOW_ANY)
                    )
                }
            }
            if moved != 0 {
                Darwin.close(active)
                throw currentPOSIXError()
            }
            guard Darwin.fsync(stagingRoot) == 0 else {
                Darwin.close(active)
                throw currentPOSIXError()
            }
        } else {
            ownedDirectory = try openOwnedDirectoryIfPresent(
                parent: stagingRoot,
                leaf: ownership.retiredLeaf
            )
        }

        guard ownedDirectory != nil else {
            throw CocoaError(.fileReadCorruptFile)
        }

        if let ownedDirectory {
            defer { Darwin.close(ownedDirectory) }
            let identity = SubjectIsolationFileIdentity(
                try status(of: ownedDirectory)
            )
            guard ownership.owns(identity) else {
                throw CocoaError(.fileReadCorruptFile)
            }
            let retiredURL = stagingRootURL.appendingPathComponent(
                ownership.retiredLeaf,
                isDirectory: true
            )
            try beforeOwnedStagingRemoval(retiredURL)
            try Task.checkCancellation()
            var visitedEntries = 0
            try removeDirectoryContents(
                descriptor: ownedDirectory,
                depth: 0,
                visitedEntries: &visitedEntries,
                cleanupCheckpoint: cleanupCheckpoint
            )
            try SubjectIsolationOwnedEntryRemover.remove(
                parent: stagingRoot,
                leaf: ownership.retiredLeaf,
                expectedIdentity: identity,
                kind: .directory,
                relativePath: ownership.retiredLeaf,
                checkpoint: cleanupCheckpoint
            )
        }

        try removeMarker(
            parent: isolation,
            expectedIdentity: markerIdentity,
            cleanupCheckpoint: cleanupCheckpoint
        )
        guard Darwin.fsync(isolation) == 0 else {
            throw currentPOSIXError()
        }
    }

    private static func writeMarker(
        _ ownership: Ownership,
        to directory: Int32,
        isolationURL: URL,
        checkpoint: SubjectIsolationAmbiguityLeaseCheckpointOperation
    ) throws -> SubjectIsolationFileIdentity {
        try removeInterruptedPendingMarker(from: directory)
        let descriptor = pendingMarkerLeaf.withCString {
            Darwin.openat(
                directory,
                $0,
                O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
                mode_t(0o600)
            )
        }
        guard descriptor >= 0 else { throw currentPOSIXError() }
        defer { Darwin.close(descriptor) }
        var published = false
        var markerIdentity: SubjectIsolationFileIdentity?
        do {
            markerIdentity = SubjectIsolationFileIdentity(
                try status(of: descriptor)
            )
            guard Darwin.fchmod(descriptor, mode_t(0o600)) == 0 else {
                throw currentPOSIXError()
            }
            markerIdentity = SubjectIsolationFileIdentity(
                try status(of: descriptor)
            )

            let data = ownership.data
            var offset = 0
            while offset < data.count {
                let count = data.withUnsafeBytes {
                    Darwin.write(
                        descriptor,
                        $0.baseAddress?.advanced(by: offset),
                        data.count - offset
                    )
                }
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { throw currentPOSIXError() }
                offset += count
            }
            markerIdentity = SubjectIsolationFileIdentity(try status(of: descriptor))
            try checkpoint(.markerTemporaryWritten, isolationURL)
            guard Darwin.fsync(descriptor) == 0 else {
                throw currentPOSIXError()
            }
            let identity = SubjectIsolationFileIdentity(try status(of: descriptor))
            markerIdentity = identity
            guard isPrivateMarker(identity) else {
                throw CocoaError(.fileWriteNoPermission)
            }
            try checkpoint(.markerTemporarySynchronized, isolationURL)
            let renamed = pendingMarkerLeaf.withCString { source in
                markerLeaf.withCString { destination in
                    Darwin.renameatx_np(
                        directory,
                        source,
                        directory,
                        destination,
                        UInt32(RENAME_EXCL | RENAME_NOFOLLOW_ANY)
                    )
                }
            }
            guard renamed == 0 else { throw currentPOSIXError() }
            published = true
            try checkpoint(.markerCanonicalPublished, isolationURL)
            guard Darwin.fsync(directory) == 0 else { throw currentPOSIXError() }
            let committedIdentity = SubjectIsolationFileIdentity(
                try status(of: descriptor)
            )
            guard markerIdentity?.sameInode(as: committedIdentity) == true,
                  isPrivateMarker(committedIdentity) else {
                throw CocoaError(.fileWriteUnknown)
            }
            markerIdentity = nil
            return committedIdentity
        } catch {
            let primaryError = error
            let rollbackIdentity = markerIdentity
                ?? (try? SubjectIsolationFileIdentity(status(of: descriptor)))
            guard let rollbackIdentity else {
                throw SubjectIsolationAuthorityRollbackFailure(
                    primaryError: primaryError,
                    rollbackError: CocoaError(.fileWriteUnknown)
                )
            }
            do {
                try removeNamedFile(
                    parent: directory,
                    leaf: published ? markerLeaf : pendingMarkerLeaf,
                    expectedIdentity: rollbackIdentity,
                    honorsCancellation: false
                )
                guard Darwin.fsync(directory) == 0 else {
                    throw currentPOSIXError()
                }
            } catch {
                throw SubjectIsolationAuthorityRollbackFailure(
                    primaryError: primaryError,
                    rollbackError: error
                )
            }
            throw primaryError
        }
    }

    private static func removeInterruptedPendingMarker(
        from directory: Int32,
        cleanupCheckpoint: SubjectIsolationAmbiguityCleanupCheckpointOperation = { _ in }
    ) throws {
        let descriptor = pendingMarkerLeaf.withCString {
            Darwin.openat(
                directory,
                $0,
                O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC
            )
        }
        if descriptor < 0, errno == ENOENT { return }
        guard descriptor >= 0 else { throw currentPOSIXError() }
        defer { Darwin.close(descriptor) }
        let identity = SubjectIsolationFileIdentity(try status(of: descriptor))
        guard isPrivateMarker(identity), identity.byteCount <= 256 else {
            throw CocoaError(.fileReadCorruptFile)
        }
        try removeNamedFile(
            parent: directory,
            leaf: pendingMarkerLeaf,
            expectedIdentity: identity,
            cleanupCheckpoint: cleanupCheckpoint
        )
        guard Darwin.fsync(directory) == 0 else { throw currentPOSIXError() }
    }

    private static func removeNamedFile(
        parent: Int32,
        leaf: String,
        expectedIdentity: SubjectIsolationFileIdentity,
        cleanupCheckpoint: SubjectIsolationAmbiguityCleanupCheckpointOperation = { _ in },
        honorsCancellation: Bool = true
    ) throws {
        try SubjectIsolationOwnedEntryRemover.remove(
            parent: parent,
            leaf: leaf,
            expectedIdentity: expectedIdentity,
            kind: .regularFile(maximumByteCount: 256),
            relativePath: leaf,
            checkpoint: cleanupCheckpoint,
            honorsCancellation: honorsCancellation
        )
    }

    private static func readMarkerIfPresent(
        from directory: Int32
    ) throws -> (Ownership, SubjectIsolationFileIdentity)? {
        let descriptor = markerLeaf.withCString {
            Darwin.openat(
                directory,
                $0,
                O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC
            )
        }
        if descriptor < 0, errno == ENOENT { return nil }
        guard descriptor >= 0 else { throw currentPOSIXError() }
        defer { Darwin.close(descriptor) }

        let identity = SubjectIsolationFileIdentity(try status(of: descriptor))
        guard isPrivateMarker(identity), identity.byteCount <= 256 else {
            throw CocoaError(.fileReadCorruptFile)
        }
        var data = Data(count: Int(identity.byteCount))
        var offset = 0
        while offset < data.count {
            let remaining = data.count - offset
            let count = data.withUnsafeMutableBytes {
                Darwin.pread(
                    descriptor,
                    $0.baseAddress?.advanced(by: offset),
                    remaining,
                    off_t(offset)
                )
            }
            if count < 0, errno == EINTR { continue }
            guard count > 0 else { throw CocoaError(.fileReadCorruptFile) }
            offset += count
        }
        return (try Ownership(data: data), identity)
    }

    private static func removeMarker(
        parent: Int32,
        expectedIdentity: SubjectIsolationFileIdentity,
        cleanupCheckpoint: SubjectIsolationAmbiguityCleanupCheckpointOperation = { _ in }
    ) throws {
        try SubjectIsolationOwnedEntryRemover.remove(
            parent: parent,
            leaf: markerLeaf,
            expectedIdentity: expectedIdentity,
            kind: .regularFile(maximumByteCount: 256),
            relativePath: markerLeaf,
            checkpoint: cleanupCheckpoint
        )
    }

    private static func isPrivateMarker(
        _ identity: SubjectIsolationFileIdentity
    ) -> Bool {
        identity.isRegularFile
            && identity.owner == UInt32(geteuid())
            && identity.linkCount == 1
            && identity.permissions == 0o600
    }

    private static func openOwnedDirectory(at url: URL) throws -> Int32 {
        let descriptor = Darwin.open(
            url.path,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard descriptor >= 0 else { throw currentPOSIXError() }
        do {
            let identity = SubjectIsolationFileIdentity(
                try status(of: descriptor)
            )
            guard identity.isDirectory,
                  identity.owner == UInt32(geteuid()) else {
                throw CocoaError(.fileReadNoPermission)
            }
            return descriptor
        } catch {
            Darwin.close(descriptor)
            throw error
        }
    }

    private static func openOwnedDirectory(
        parent: Int32,
        leaf: String
    ) throws -> Int32 {
        guard let descriptor = try openOwnedDirectoryIfPresent(
            parent: parent,
            leaf: leaf
        ) else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(ENOENT))
        }
        return descriptor
    }

    private static func openOwnedDirectoryIfPresent(
        parent: Int32,
        leaf: String
    ) throws -> Int32? {
        let descriptor = leaf.withCString {
            Darwin.openat(
                parent,
                $0,
                O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
            )
        }
        if descriptor < 0, errno == ENOENT { return nil }
        guard descriptor >= 0 else { throw currentPOSIXError() }
        do {
            let identity = SubjectIsolationFileIdentity(
                try status(of: descriptor)
            )
            guard identity.isDirectory,
                  identity.owner == UInt32(geteuid()) else {
                throw CocoaError(.fileReadNoPermission)
            }
            return descriptor
        } catch {
            Darwin.close(descriptor)
            throw error
        }
    }

    fileprivate static func removeDirectoryContents(
        descriptor: Int32,
        depth: Int,
        visitedEntries: inout Int,
        relativePrefix: String = "",
        cleanupCheckpoint: SubjectIsolationAmbiguityCleanupCheckpointOperation = { _ in },
        honorsCancellation: Bool = true
    ) throws {
        if honorsCancellation { try Task.checkCancellation() }
        guard depth <= maximumCleanupDepth else {
            throw CocoaError(.fileReadTooLarge)
        }
        for leaf in try directoryLeaves(
            descriptor: descriptor,
            cleanupCheckpoint: cleanupCheckpoint,
            honorsCancellation: honorsCancellation
        ) {
            if honorsCancellation { try Task.checkCancellation() }
            visitedEntries += 1
            guard visitedEntries <= maximumCleanupEntries else {
                throw CocoaError(.fileReadTooLarge)
            }
            let relativePath = relativePrefix.isEmpty
                ? leaf
                : "\(relativePrefix)/\(leaf)"

            var named = stat()
            guard leaf.withCString({
                Darwin.fstatat(
                    descriptor,
                    $0,
                    &named,
                    AT_SYMLINK_NOFOLLOW
                )
            }) == 0 else {
                throw currentPOSIXError()
            }
            let namedIdentity = SubjectIsolationFileIdentity(named)
            guard namedIdentity.owner == UInt32(geteuid()) else {
                throw CocoaError(.fileWriteNoPermission)
            }

            if namedIdentity.isDirectory {
                let child = try openOwnedDirectory(
                    parent: descriptor,
                    leaf: leaf
                )
                do {
                    defer { Darwin.close(child) }
                    let childStatus = try status(of: child)
                    guard namedIdentity == SubjectIsolationFileIdentity(childStatus) else {
                        throw CocoaError(.fileReadCorruptFile)
                    }
                    if childStatus.st_flags & UInt32(UF_IMMUTABLE) != 0 {
                        guard Darwin.fchflags(
                            child,
                            childStatus.st_flags & ~UInt32(UF_IMMUTABLE)
                        ) == 0 else {
                            throw currentPOSIXError()
                        }
                    }
                    try removeDirectoryContents(
                        descriptor: child,
                        depth: depth + 1,
                        visitedEntries: &visitedEntries,
                        relativePrefix: relativePath,
                        cleanupCheckpoint: cleanupCheckpoint,
                        honorsCancellation: honorsCancellation
                    )
                }
                try SubjectIsolationOwnedEntryRemover.remove(
                    parent: descriptor,
                    leaf: leaf,
                    expectedIdentity: namedIdentity,
                    kind: .directory,
                    relativePath: relativePath,
                    checkpoint: cleanupCheckpoint,
                    honorsCancellation: honorsCancellation
                )
            } else {
                guard namedIdentity.isRegularFile,
                      namedIdentity.linkCount == 1 else {
                    throw CocoaError(.fileReadCorruptFile)
                }
                let file = leaf.withCString {
                    Darwin.openat(
                        descriptor,
                        $0,
                        O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC
                    )
                }
                guard file >= 0 else { throw currentPOSIXError() }
                let openedIdentity: SubjectIsolationFileIdentity
                let openedStatus: stat
                do {
                    openedStatus = try status(of: file)
                    openedIdentity = SubjectIsolationFileIdentity(openedStatus)
                } catch {
                    Darwin.close(file)
                    throw error
                }
                guard namedIdentity == openedIdentity else {
                    Darwin.close(file)
                    throw CocoaError(.fileReadCorruptFile)
                }
                if openedStatus.st_flags & UInt32(UF_IMMUTABLE) != 0,
                   Darwin.fchflags(
                       file,
                       openedStatus.st_flags & ~UInt32(UF_IMMUTABLE)
                   ) != 0 {
                    let error = currentPOSIXError()
                    Darwin.close(file)
                    throw error
                }
                Darwin.close(file)
                try SubjectIsolationOwnedEntryRemover.remove(
                    parent: descriptor,
                    leaf: leaf,
                    expectedIdentity: openedIdentity,
                    kind: .regularFile(),
                    relativePath: relativePath,
                    checkpoint: cleanupCheckpoint,
                    honorsCancellation: honorsCancellation
                )
            }
        }
    }

    private static func directoryLeaves(
        descriptor: Int32,
        cleanupCheckpoint: SubjectIsolationAmbiguityCleanupCheckpointOperation,
        honorsCancellation: Bool
    ) throws -> [String] {
        let duplicate = ".".withCString {
            Darwin.openat(
                descriptor,
                $0,
                O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
            )
        }
        guard duplicate >= 0,
              let stream = Darwin.fdopendir(duplicate) else {
            if duplicate >= 0 { Darwin.close(duplicate) }
            throw currentPOSIXError()
        }
        defer { Darwin.closedir(stream) }

        var leaves: [String] = []
        errno = 0
        while let entry = Darwin.readdir(stream) {
            if honorsCancellation { try Task.checkCancellation() }
            let leaf = withUnsafePointer(to: entry.pointee.d_name) {
                $0.withMemoryRebound(
                    to: CChar.self,
                    capacity: Int(MAXNAMLEN) + 1
                ) {
                    String(cString: $0)
                }
            }
            if leaf != ".", leaf != ".." {
                guard leaves.count < maximumCleanupEntries else {
                    throw CocoaError(.fileReadTooLarge)
                }
                leaves.append(leaf)
                try cleanupCheckpoint(.didReadDirectoryEntry(
                    count: leaves.count
                ))
                if honorsCancellation { try Task.checkCancellation() }
            }
            errno = 0
        }
        guard errno == 0 else { throw currentPOSIXError() }
        return leaves.sorted()
    }

    private static func status(of descriptor: Int32) throws -> stat {
        var value = stat()
        guard Darwin.fstat(descriptor, &value) == 0 else {
            throw currentPOSIXError()
        }
        return value
    }

    private static func currentPOSIXError() -> NSError {
        NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
    }
}

private struct SubjectIsolationFileIdentity: Equatable {
    let device: UInt64
    let inode: UInt64
    let mode: UInt32
    let owner: UInt32
    let group: UInt32
    let linkCount: UInt64
    let byteCount: Int64
    let modifiedSeconds: Int64
    let modifiedNanoseconds: Int64
    let changedSeconds: Int64
    let changedNanoseconds: Int64

    init(_ status: stat) {
        device = UInt64(bitPattern: Int64(status.st_dev))
        inode = UInt64(status.st_ino)
        mode = UInt32(status.st_mode)
        owner = UInt32(status.st_uid)
        group = UInt32(status.st_gid)
        linkCount = UInt64(status.st_nlink)
        byteCount = Int64(status.st_size)
        modifiedSeconds = Int64(status.st_mtimespec.tv_sec)
        modifiedNanoseconds = Int64(status.st_mtimespec.tv_nsec)
        changedSeconds = Int64(status.st_ctimespec.tv_sec)
        changedNanoseconds = Int64(status.st_ctimespec.tv_nsec)
    }

    var isDirectory: Bool { mode & UInt32(S_IFMT) == UInt32(S_IFDIR) }
    var isRegularFile: Bool { mode & UInt32(S_IFMT) == UInt32(S_IFREG) }
    var permissions: UInt32 { mode & 0o7777 }

    func sameInode(as status: stat) -> Bool {
        device == UInt64(bitPattern: Int64(status.st_dev))
            && inode == UInt64(status.st_ino)
    }

    func sameInode(as other: SubjectIsolationFileIdentity) -> Bool {
        device == other.device && inode == other.inode
    }
}

private struct SubjectIsolationNativeMaskManifest: Encodable {
    let schemaVersion = 1
    let isolationModeVersion = 1
    let sourcePlyDigest: String
    let inputDigest: String
    let geometryDigest: String
    let selectedFramesDigest: String
    let trainingManifestDigest: String
    let selectedImageOrder: [String]
    let views: [View]

    struct View: Encodable {
        let imageIdentity: String
        let cameraIndex: Int
        let role: String
        let relativeMaskPath: String
        let maskSHA256: String
        let width: Int
        let height: Int

        enum CodingKeys: String, CodingKey {
            case imageIdentity = "image_identity"
            case cameraIndex = "camera_index"
            case role
            case relativeMaskPath = "relative_mask_path"
            case maskSHA256 = "mask_sha256"
            case width
            case height
        }
    }

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case isolationModeVersion = "isolation_mode_version"
        case sourcePlyDigest = "source_ply_digest"
        case inputDigest = "input_digest"
        case geometryDigest = "geometry_digest"
        case selectedFramesDigest = "selected_frames_digest"
        case trainingManifestDigest = "training_manifest_digest"
        case selectedImageOrder = "selected_image_order"
        case views
    }
}

private func writeNativeMaskManifest(
    to url: URL,
    orderedViews: [SubjectIsolationSampledView],
    masks: [SubjectIsolationAcquiredMask],
    workIdentities: Set<String>,
    digests: SubjectIsolationNativeDigests
) throws {
    guard orderedViews.count == masks.count,
          zip(orderedViews, masks).allSatisfy({
              $0.imageIdentity == $1.imageIdentity
          }) else {
        throw SubjectIsolationCoordinatorError.invalidProject
    }
    let manifest = SubjectIsolationNativeMaskManifest(
        sourcePlyDigest: digests.sourcePly,
        inputDigest: digests.input,
        geometryDigest: digests.geometry,
        selectedFramesDigest: digests.selectedFrames,
        trainingManifestDigest: digests.trainingManifest,
        selectedImageOrder: orderedViews.map(\.imageIdentity),
        views: zip(orderedViews, masks).map { view, mask in
            SubjectIsolationNativeMaskManifest.View(
                imageIdentity: view.imageIdentity,
                cameraIndex: view.nativeCameraIndex,
                role: workIdentities.contains(view.imageIdentity)
                    ? "work"
                    : "held_out",
                relativeMaskPath: "masks/\(mask.fileURL.lastPathComponent)",
                maskSHA256: mask.maskSHA256,
                width: mask.pixelWidth,
                height: mask.pixelHeight
            )
        }
    )
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    try encoder.encode(manifest).write(to: url, options: [.atomic])
}
