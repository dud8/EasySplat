import Foundation

public enum ProjectInputAdoptionError: Error, Equatable, Sendable {
    case unexpectedVideoInput
    case videoInputAlreadyAdopted
    case unexpectedPhotoInput
    case photoInputAlreadyAdopted
    case invalidPhotoSelectionEvidence
    case emptyPhotosRequireAdoptedMixedVideoInput
}

/// Converts immutable preflight snapshots into the project-relative input and receipt
/// contract consumed by the pipeline. Preflight remains outside this type so callers
/// keep ownership of progress, cancellation, and publication checkpoints.
public struct ProjectInputAdoption: Sendable {
    public private(set) var input: InputSpec
    public private(set) var videoInputReceipts: [VideoInputReceipt]?
    public private(set) var videoInputIntegrityHandoff: VideoInputIntegrityHandoff?
    public private(set) var photoInputReceipts: [PhotoInputReceipt]?
    public private(set) var photoSelectionReceipt: PhotoSelectionReceipt?

    public init(requestedInput: InputSpec) {
        input = requestedInput
        videoInputReceipts = nil
        videoInputIntegrityHandoff = nil
        photoInputReceipts = nil
        photoSelectionReceipt = nil
    }

    public mutating func adoptVideos(
        _ prepared: PreparedVideoInput,
        into paths: ProjectPaths
    ) throws {
        guard input.hasVideos else {
            throw ProjectInputAdoptionError.unexpectedVideoInput
        }
        guard videoInputReceipts == nil else {
            throw ProjectInputAdoptionError.videoInputAlreadyAdopted
        }
        let adopted = try prepared.adopt(into: paths.originalsURL)
        videoInputIntegrityHandoff = try prepared.takeIntegrityHandoff()
        try paths.ensureVideoFrameAnalysisDirectory()
        let receipts = try adopted.map { video -> VideoInputReceipt in
            let projectRelativePath = try paths.projectRelativePath(for: video.stagedURL)
            let analysisURL = paths.videoFrameAnalysisURL(index: video.index)
            let analysisArtifact = VideoFrameAnalysisArtifact(
                video: video,
                sourceProjectRelativePath: projectRelativePath
            )
            let analysisFile = try VideoFrameAnalysisArtifactStore.save(
                analysisArtifact,
                to: analysisURL,
                projectPaths: paths
            )
            return VideoInputReceipt(
                projectRelativePath: projectRelativePath,
                safeDisplayName: video.safeDisplayName,
                byteCount: video.byteCount,
                sha256: video.sha256,
                trackID: video.trackID,
                pixelWidth: video.pixelWidth,
                pixelHeight: video.pixelHeight,
                durationSeconds: video.durationSeconds,
                nominalFrameRate: video.nominalFrameRate,
                isHDR: video.isHDR,
                decodedFrameCount: video.decodedFrameCount,
                transformA: video.transformA,
                transformB: video.transformB,
                transformC: video.transformC,
                transformD: video.transformD,
                transformTX: video.transformTX,
                transformTY: video.transformTY,
                clipGroupID: video.clipGroupID,
                analysisPolicySHA256: video.analysisPolicy.sha256,
                analysisArtifactPath: try paths.projectRelativePath(for: analysisURL),
                analysisArtifactByteCount: analysisFile.byteCount,
                analysisArtifactSHA256: analysisFile.sha256
            )
        }
        input = replacingVideoFiles(in: input, with: receipts.map(\.projectRelativePath))
        videoInputReceipts = receipts
    }

    public mutating func adoptPhotos(
        _ prepared: PreparedPhotoInput,
        into paths: ProjectPaths
    ) throws {
        guard input.hasPhotos else {
            throw ProjectInputAdoptionError.unexpectedPhotoInput
        }
        guard photoInputReceipts == nil, photoSelectionReceipt == nil else {
            throw ProjectInputAdoptionError.photoInputAlreadyAdopted
        }
        let artifact = prepared.selectionArtifact
        do {
            try PhotoSelectionArtifactStore.validate(artifact)
        } catch {
            throw ProjectInputAdoptionError.invalidPhotoSelectionEvidence
        }
        let preparedSourceSHA256s = prepared.photos.map(\.analysisEvidence.sourceSHA256)
        let preparedRankBySourceSHA256 = Dictionary(
            uniqueKeysWithValues: prepared.photos.map {
                ($0.analysisEvidence.sourceSHA256, $0.retainedRank)
            }
        )
        let artifactCandidateBySourceSHA256 = Dictionary(
            uniqueKeysWithValues: artifact.candidates.map {
                ($0.evidence.sourceSHA256, $0)
            }
        )
        guard artifact.canonicalRetainedSourceSHA256s == preparedSourceSHA256s,
              prepared.photos.allSatisfy({ photo in
                  guard let candidate = artifactCandidateBySourceSHA256[
                    photo.analysisEvidence.sourceSHA256
                  ] else { return false }
                  return candidate.evidence == photo.analysisEvidence
                    && candidate.retainedRank == photo.retainedRank
              }),
              artifact.candidates.allSatisfy({ candidate in
                  preparedRankBySourceSHA256[candidate.evidence.sourceSHA256]
                    == candidate.retainedRank
              }) else {
            throw ProjectInputAdoptionError.invalidPhotoSelectionEvidence
        }
        let adopted = try prepared.adopt(into: paths.importedPhotosURL)
        let receipts = try adopted.map { photo -> PhotoInputReceipt in
            PhotoInputReceipt(
                projectRelativePath: try paths.projectRelativePath(for: photo.stagedURL),
                safeDisplayName: photo.safeDisplayName,
                byteCount: photo.byteCount,
                sha256: photo.sha256,
                pixelWidth: photo.pixelWidth,
                pixelHeight: photo.pixelHeight,
                orientation: photo.orientation,
                typeIdentifier: photo.typeIdentifier,
                source: photo.source,
                importMode: photo.importMode,
                analysisEvidence: photo.analysisEvidence,
                retainedRank: photo.retainedRank
            )
        }
        try paths.ensureVideoFrameAnalysisDirectory()
        let artifactFile = try PhotoSelectionArtifactStore.save(
            artifact,
            to: paths.photoSelectionArtifactURL,
            projectPaths: paths
        )
        let controlledFolder = try paths.projectRelativePath(for: paths.importedPhotosURL)
        input = replacingPhotosFolder(in: input, with: controlledFolder)
        photoInputReceipts = receipts
        photoSelectionReceipt = PhotoSelectionReceipt(
            projectRelativePath: PhotoSelectionReceipt.projectRelativePath,
            byteCount: artifactFile.byteCount,
            sha256: artifactFile.sha256,
            artifactSchemaVersion: artifact.schemaVersion,
            analysisRecipeVersion: artifact.analysisRecipeVersion,
            analysisRecipeSHA256: artifact.analysisRecipeSHA256,
            selectorPolicyVersion: artifact.selectorPolicyVersion,
            selectorPolicySHA256: artifact.selectorPolicySHA256
        )
    }

    public mutating func adoptEmptyMixedPhotoFolder(into paths: ProjectPaths) throws {
        guard case .mixed = input,
              videoInputReceipts?.isEmpty == false,
              photoInputReceipts == nil else {
            throw ProjectInputAdoptionError.emptyPhotosRequireAdoptedMixedVideoInput
        }
        try FileManager.default.createDirectory(
            at: paths.importedPhotosURL,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        let controlledFolder = try paths.projectRelativePath(for: paths.importedPhotosURL)
        input = replacingPhotosFolder(in: input, with: controlledFolder)
        photoInputReceipts = []
        photoSelectionReceipt = nil
    }

    private func replacingVideoFiles(in input: InputSpec, with files: [String]) -> InputSpec {
        switch input {
        case .video:
            .video(files: files)
        case .mixed(_, let photosFolder):
            .mixed(videos: files, photosFolder: photosFolder)
        case .photos:
            input
        }
    }

    private func replacingPhotosFolder(in input: InputSpec, with folder: String) -> InputSpec {
        switch input {
        case .photos:
            .photos(folder: folder)
        case .mixed(let videos, _):
            .mixed(videos: videos, photosFolder: folder)
        case .video:
            input
        }
    }
}
