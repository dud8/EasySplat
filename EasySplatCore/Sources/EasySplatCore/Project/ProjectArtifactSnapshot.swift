import Foundation

/// One authenticated read of a project's lifecycle metadata and durable artifact
/// manifests. Artifacts are never copied into `project.json`; callers keep this
/// value in memory for the lifetime of one UI or pipeline decision.
public struct ProjectArtifactSnapshot: Sendable {
    public let metadata: ProjectMetadata
    public let geometryArtifact: GeometryArtifact?
    public let trainingArtifact: TrainingArtifact?

    public var viewerPreferences: ViewerPreferences {
        guard geometryArtifact?.allowsViewOnlyUprightFlip == true else {
            return ViewerPreferences(isUprightFlipActive: false)
        }
        return metadata.viewerPreferences
    }
}

public enum ProjectArtifactSnapshotError: Error, LocalizedError, Equatable {
    case artifactWithoutResolvedPlan
    case geometryRequiredByLifecycle
    case trainingRequiredByLifecycle
    case trainingWithoutGeometry
    case geometryPlanMismatch
    case trainingPlanMismatch
    case trainingGeometryMismatch
    case invalidFinishedTraining

    public var errorDescription: String? {
        switch self {
        case .artifactWithoutResolvedPlan:
            "Project artifacts have no resolved run plan."
        case .geometryRequiredByLifecycle:
            "Project metadata claims completed geometry, but its geometry manifest is unavailable."
        case .trainingRequiredByLifecycle:
            "Project metadata claims completed training, but its training manifest is unavailable."
        case .trainingWithoutGeometry:
            "The training manifest has no authenticated geometry manifest."
        case .geometryPlanMismatch:
            "The geometry manifest does not match the resolved run plan."
        case .trainingPlanMismatch:
            "The training manifest does not match the resolved run plan."
        case .trainingGeometryMismatch:
            "The training manifest does not match the geometry manifest."
        case .invalidFinishedTraining:
            "The finished project does not have a validated public training result."
        }
    }
}

public enum ProjectArtifactSnapshotStore {
    public enum ValidationDepth: Sendable {
        case quick
        case full
    }

    public static func load(
        projectURL: URL,
        validationDepth: ValidationDepth = .full
    ) throws -> ProjectArtifactSnapshot {
        let paths = ProjectPaths(root: projectURL)
        let metadata = try ProjectMetadataStore.load(from: paths.metadataURL)
        let geometry = try loadGeometryIfPresent(
            paths: paths,
            input: metadata.input,
            validationDepth: validationDepth
        )
        let training = try loadTrainingIfPresent(
            paths: paths,
            validationDepth: validationDepth
        )

        if geometry != nil || training != nil {
            guard let plan = metadata.resolvedRunPlan else {
                throw ProjectArtifactSnapshotError.artifactWithoutResolvedPlan
            }
            if let geometry {
                do {
                    try GeometryArtifactStore.requireRunPlanBinding(geometry, plan: plan)
                } catch {
                    throw ProjectArtifactSnapshotError.geometryPlanMismatch
                }
            }
            if let training {
                guard let geometry else {
                    throw ProjectArtifactSnapshotError.trainingWithoutGeometry
                }
                guard training.detailProfile == metadata.requestedRunOptions.detailProfile,
                      training.matchesResolvedTrainingPlan(
                          plan,
                          resourcePolicy: metadata.requestedRunOptions.resourcePolicy
                      ) else {
                    throw ProjectArtifactSnapshotError.trainingPlanMismatch
                }
                guard training.datasetDerivation.sourceSelectedFramesDigest
                        == geometry.selectedFramesDigest,
                      training.datasetDerivation.sourceGeometryManifestSHA256
                        == (try GeometryArtifactStore.manifestDigest(
                            matching: geometry,
                            at: paths.geometryManifestURL
                        )) else {
                    throw ProjectArtifactSnapshotError.trainingGeometryMismatch
                }
            }
        }

        let lifecycleClaimsCompletion = metadata.state.lastError == nil
        if lifecycleClaimsCompletion,
           stage(metadata.state.stage, isAtLeast: .sfmMapping),
           geometry == nil {
            throw ProjectArtifactSnapshotError.geometryRequiredByLifecycle
        }
        if lifecycleClaimsCompletion,
           stage(metadata.state.stage, isAtLeast: .trainSplat),
           training == nil {
            throw ProjectArtifactSnapshotError.trainingRequiredByLifecycle
        }
        if lifecycleClaimsCompletion, metadata.state.stage == .done {
            guard metadata.checkpoint == nil,
                  metadata.lastRunStartedAt == nil,
                  training?.completionStatus == .completed,
                  training?.outputPath == "Output/splat.ply" else {
                throw ProjectArtifactSnapshotError.invalidFinishedTraining
            }
        }

        return ProjectArtifactSnapshot(
            metadata: metadata,
            geometryArtifact: geometry,
            trainingArtifact: training
        )
    }

    private static func loadGeometryIfPresent(
        paths: ProjectPaths,
        input: InputSpec,
        validationDepth: ValidationDepth
    ) throws -> GeometryArtifact? {
        do {
            switch validationDepth {
            case .quick:
                return try GeometryArtifactStore.loadManifest(
                    from: paths.geometryManifestURL,
                    projectPaths: paths
                )
            case .full:
                return try GeometryArtifactStore.load(
                    from: paths.geometryManifestURL,
                    projectPaths: paths,
                    expectedInput: input
                )
            }
        } catch where BoundedFileReader.isMissingFileError(error) {
            return nil
        }
    }

    private static func loadTrainingIfPresent(
        paths: ProjectPaths,
        validationDepth: ValidationDepth
    ) throws -> TrainingArtifact? {
        do {
            switch validationDepth {
            case .quick:
                return try TrainingArtifactStore.loadManifest(
                    from: paths.trainingManifestURL,
                    projectPaths: paths
                )
            case .full:
                return try TrainingArtifactStore.load(
                    from: paths.trainingManifestURL,
                    projectPaths: paths
                )
            }
        } catch where BoundedFileReader.isMissingFileError(error) {
            return nil
        }
    }

    private static func stage(_ lhs: PipelineStage, isAtLeast rhs: PipelineStage) -> Bool {
        guard let lhsIndex = PipelineStage.allCases.firstIndex(of: lhs),
              let rhsIndex = PipelineStage.allCases.firstIndex(of: rhs) else {
            return false
        }
        return lhsIndex >= rhsIndex
    }
}
