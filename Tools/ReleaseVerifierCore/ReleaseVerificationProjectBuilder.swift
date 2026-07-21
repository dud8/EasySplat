import EasySplatCore
import Foundation

public struct PreparedReleaseVerificationProject {
    public let input: InputSpec
    public let publication: FreshProjectPublication
}

public enum ReleaseVerificationProjectBuilderError: Error, LocalizedError, Sendable {
    case photoInput(PhotoInputPreflightIssue)

    public var errorDescription: String? {
        switch self {
        case .photoInput(let issue):
            return "Release photo preflight failed: \(String(describing: issue))"
        }
    }
}

/// Publishes the verifier's external capture through the same receipt-bound project
/// boundary used by the app before handing the one-shot attestation to the pipeline.
public enum ReleaseVerificationProjectBuilder {
    public static func prepare(
        resolvedInput: ResolvedPackagedProjectInput,
        requestedOptions: RequestedRunOptions,
        resolvedRunPlan: ResolvedRunPlan,
        projectParent: URL,
        title: String
    ) async throws -> PreparedReleaseVerificationProject {
        let requestedInput = inputSpec(for: resolvedInput.expectedInput)
        var preparedVideoInput: PreparedVideoInput?
        var preparedPhotoInput: PreparedPhotoInput?
        var publication: ProjectPublicationTransaction?
        var emptyMixedPhotoInput = false
        defer { preparedVideoInput?.discard() }
        defer { preparedPhotoInput?.discard() }
        defer { try? publication?.abort() }

        let reserve = VideoInputPreflight.requiredAtomicWorkspaceReserveBytes(
            keyframeBudget: resolvedRunPlan.keyframeBudget,
            maximumImageDimension: resolvedRunPlan.maximumImageDimension,
            maximumFeatureCount: resolvedRunPlan.colmapMaximumFeatureCount,
            maximumMatchCount: resolvedRunPlan.colmapMaximumMatchCount,
            retrievalCandidateCount: resolvedRunPlan.retrievalCandidateCount
        )
        if let photosFolder = requestedInput.photosFolder {
            let reservedVideoFrames = RunPlanResolver.minimumReservedVideoFrameCount(
                keyframeBudget: resolvedRunPlan.keyframeBudget,
                videoCount: requestedInput.videoFiles.count
            )
            let photoBudget = resolvedRunPlan.photoSelection == .automatic
                ? resolvedRunPlan.keyframeBudget
                : max(1, resolvedRunPlan.keyframeBudget - reservedVideoFrames)
            do {
                preparedPhotoInput = try await PhotoInputPreflight.prepare(
                    folder: URL(fileURLWithPath: photosFolder, isDirectory: true),
                    stagingParent: projectParent,
                    photoSelection: resolvedRunPlan.photoSelection,
                    inputOrdering: resolvedRunPlan.inputOrdering,
                    keyframeBudget: photoBudget,
                    requiredAtomicWorkspaceReserveBytes: reserve,
                    limits: .init(
                        maximumDecodedDimension: min(
                            4_096,
                            resolvedRunPlan.maximumImageDimension
                        )
                    ),
                    progress: { _, _ in }
                )
            } catch let failure as PhotoInputPreflightFailure {
                if requestedInput.hasVideos && failure.issue == .noValidPhotos {
                    emptyMixedPhotoInput = true
                } else {
                    throw ReleaseVerificationProjectBuilderError.photoInput(failure.issue)
                }
            }
            try RunPlanResolver.validatePhotoSelection(
                validPhotoCount: preparedPhotoInput?.summary.validPhotoCount ?? 0,
                resolvedPlan: resolvedRunPlan,
                input: requestedInput
            )
        }
        if requestedInput.hasVideos {
            preparedVideoInput = try await VideoInputPreflight().prepare(
                videoURLs: requestedInput.videoFiles.map(URL.init(fileURLWithPath:)),
                stagingParent: projectParent,
                requiredAtomicWorkspaceReserveBytes: reserve,
                analysisPolicy: VideoFrameAnalysisPolicy(
                    resolvedRunPlan: resolvedRunPlan
                ),
                pairingPolicy: resolvedRunPlan.pairingPolicy,
                progress: { _, _ in }
            )
        }

        try Task.checkCancellation()
        let projectID = UUID()
        let transaction = try ProjectPublicationTransaction.begin(
            in: projectParent,
            title: title,
            projectID: projectID
        )
        publication = transaction
        let paths = ProjectPaths(root: transaction.bundleURL)
        var adoption = ProjectInputAdoption(requestedInput: requestedInput)
        defer { adoption.videoInputIntegrityHandoff?.discard() }
        if let preparedVideoInput {
            try adoption.adoptVideos(preparedVideoInput, into: paths)
            try transaction.reached(.videoAdopted)
        }
        if let preparedPhotoInput {
            try adoption.adoptPhotos(preparedPhotoInput, into: paths)
            try transaction.reached(.photosAdopted)
        } else if emptyMixedPhotoInput {
            try adoption.adoptEmptyMixedPhotoFolder(into: paths)
            try transaction.reached(.photosAdopted)
        }
        try paths.ensureDirectories()
        let metadata = ProjectMetadata(
            id: projectID,
            title: title,
            input: adoption.input,
            videoInputReceipts: adoption.videoInputReceipts,
            photoInputReceipts: adoption.photoInputReceipts,
            photoSelectionReceipt: adoption.photoSelectionReceipt,
            requestedRunOptions: requestedOptions,
            resolvedRunPlan: resolvedRunPlan,
            lastRunStartedAt: Date()
        )
        try ProjectMetadataStore.save(metadata, to: paths.metadataURL)
        try transaction.validateAndSeal(expectedMetadata: metadata)
        let freshPublication: FreshProjectPublication
        if adoption.input.hasVideos {
            guard let handoff = adoption.videoInputIntegrityHandoff else {
                throw VideoInputIntegrityHandoffError.unavailable
            }
            freshPublication = try transaction.publishWithFreshAttestation(
                videoInputIntegrityHandoff: handoff
            )
        } else {
            freshPublication = try transaction
                .publishWithFreshAttestationForProjectWithoutVideos()
        }
        publication = nil
        return PreparedReleaseVerificationProject(
            input: adoption.input,
            publication: freshPublication
        )
    }

    private static func inputSpec(
        for expectedInput: FinishedProjectExpectedInput
    ) -> InputSpec {
        switch expectedInput {
        case .videoFiles(let files):
            .video(files: files.map(\.path))
        case .photoFolder(let folder):
            .photos(folder: folder.path)
        case .mixed(let videoFiles, let photoFolder):
            .mixed(
                videos: videoFiles.map(\.path),
                photosFolder: photoFolder.path
            )
        }
    }
}
