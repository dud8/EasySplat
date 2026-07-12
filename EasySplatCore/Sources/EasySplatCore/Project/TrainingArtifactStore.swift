import Foundation

public enum TrainingArtifactStore {
    private static let maximumBytes = 1_048_576

    public static func load(from url: URL, projectPaths: ProjectPaths) throws -> TrainingArtifact {
        try validateManifestLocation(url, projectPaths: projectPaths)
        let data = try BoundedFileReader.readRegularFile(at: url, maximumBytes: maximumBytes)
        guard !data.isEmpty else {
            throw TrainingArtifactStoreError.invalidManifest
        }
        let artifact = try JSONDecoder().decode(
            TrainingArtifact.self,
            from: data
        )
        try validateArtifact(artifact, projectPaths: projectPaths)
        return artifact
    }

    public static func save(_ artifact: TrainingArtifact, to url: URL, projectPaths: ProjectPaths) throws {
        try validateManifestLocation(url, projectPaths: projectPaths)
        try validateArtifact(artifact, projectPaths: projectPaths)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(artifact)
        guard !data.isEmpty, data.count <= maximumBytes else {
            throw TrainingArtifactStoreError.invalidManifest
        }
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: url, options: [.atomic])
    }

    public static func persist(
        _ artifact: TrainingArtifact,
        metadata: inout ProjectMetadata,
        paths: ProjectPaths
    ) throws {
        try save(artifact, to: paths.trainingManifestURL, projectPaths: paths)
        metadata.trainingArtifact = artifact
        try ProjectMetadataStore.savePreservingUserEditableFields(metadata, to: paths.metadataURL)
    }

    @discardableResult
    public static func reconcile(metadata: inout ProjectMetadata, paths: ProjectPaths) throws -> Bool {
        guard FileManager.default.fileExists(atPath: paths.trainingManifestURL.path) else {
            return false
        }
        let artifact = try load(from: paths.trainingManifestURL, projectPaths: paths)
        guard metadata.trainingArtifact != artifact else { return false }
        metadata.trainingArtifact = artifact
        try ProjectMetadataStore.savePreservingUserEditableFields(metadata, to: paths.metadataURL)
        return true
    }

    public static func discardCheckpointedArtifact(
        metadata: inout ProjectMetadata,
        paths: ProjectPaths
    ) throws {
        if metadata.trainingArtifact?.completionStatus == .checkpointed {
            metadata.trainingArtifact = nil
        }
        let fileManager = FileManager.default
        let trainingDirectory = try paths.resolveProjectRelativePath("Training")
        let manifestURL = trainingDirectory.appendingPathComponent("training_manifest.json")
        let manifestIsSymlink = (try? fileManager.destinationOfSymbolicLink(
            atPath: manifestURL.path
        )) != nil
        if manifestIsSymlink {
            try fileManager.removeItem(at: manifestURL)
        } else if fileManager.fileExists(atPath: manifestURL.path) {
            try validateManifestLocation(manifestURL, projectPaths: paths)
            let values = try manifestURL.resourceValues(
                forKeys: [.isRegularFileKey, .isSymbolicLinkKey]
            )
            guard values.isRegularFile == true, values.isSymbolicLink != true else {
                throw TrainingArtifactStoreError.invalidManifest
            }
            if let persisted = try? load(
                from: manifestURL,
                projectPaths: paths
            ), persisted.completionStatus == .checkpointed {
                try fileManager.removeItem(at: manifestURL)
            }
        }
        let checkpointParent = try paths.resolveProjectRelativePath("Training/checkpoints")
        let checkpointURL = checkpointParent.appendingPathComponent("msplat", isDirectory: true)
        if fileManager.fileExists(atPath: checkpointURL.path)
            || (try? fileManager.destinationOfSymbolicLink(atPath: checkpointURL.path)) != nil {
            try fileManager.removeItem(at: checkpointURL)
        }
        try ProjectMetadataStore.savePreservingUserEditableFields(metadata, to: paths.metadataURL)
    }

    public static func discardCompletedArtifact(
        metadata: inout ProjectMetadata,
        paths: ProjectPaths
    ) throws {
        guard metadata.trainingArtifact?.completionStatus == .completed else {
            return
        }
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: paths.trainingURL.path)
            || (try? fileManager.destinationOfSymbolicLink(atPath: paths.trainingURL.path)) != nil {
            try fileManager.removeItem(at: paths.trainingURL)
        }
        metadata.trainingArtifact = nil
        try ProjectMetadataStore.savePreservingUserEditableFields(metadata, to: paths.metadataURL)
    }

    static func validateArtifact(_ artifact: TrainingArtifact, projectPaths: ProjectPaths) throws {
        let expectedBudget: (iterationLimit: Int, plateauWindow: Int) = switch artifact.detailProfile {
        case .fast: (3_000, 400)
        case .balanced: (7_000, 800)
        case .highDetail: (15_000, 1_500)
        }
        guard artifact.schemaVersion == 1,
              !artifact.trainerVersion.isEmpty,
              !artifact.runtimeVersion.isEmpty,
              isSHA256(artifact.trainerBuildDigest),
              isSHA256(artifact.inputDigest),
              isSHA256(artifact.geometryDigest),
              artifact.iterationLimit == expectedBudget.iterationLimit,
              artifact.plateauWindow == expectedBudget.plateauWindow,
              artifact.completedIteration >= 0,
              artifact.completedIteration <= artifact.iterationLimit,
              artifact.gaussianCount > 0,
              artifact.elapsedSeconds.map({ $0.isFinite && $0 >= 0 }) ?? true,
              artifact.peakMemoryBytes.map({ $0 >= 0 }) ?? true else {
            throw TrainingArtifactStoreError.invalidManifest
        }

        switch artifact.completionStatus {
        case .checkpointed:
            guard let path = artifact.checkpointPath,
                  path == "Training/checkpoints/msplat",
                  let digest = artifact.checkpointDigest,
                  isSHA256(digest),
                  artifact.completedIteration < artifact.iterationLimit,
                  artifact.outputPath == nil else {
                throw TrainingArtifactStoreError.invalidManifest
            }
            _ = try projectPaths.resolveProjectRelativePath(path)
        case .completed:
            guard let path = artifact.outputPath,
                  path == "Training/msplat/splat.ply" || path == "Output/splat.ply",
                  artifact.completedIteration > 0,
                  artifact.checkpointPath == nil,
                  artifact.checkpointDigest == nil else {
                throw TrainingArtifactStoreError.invalidManifest
            }
            _ = try projectPaths.resolveProjectRelativePath(path)
        }
    }

    private static func validateManifestLocation(_ url: URL, projectPaths: ProjectPaths) throws {
        let expected = try projectPaths.resolveProjectRelativePath("Training/training_manifest.json")
        guard expected.standardizedFileURL == url.standardizedFileURL else {
            throw TrainingArtifactStoreError.invalidManifest
        }
    }

    private static func isSHA256(_ value: String) -> Bool {
        value.count == 64 && value.utf8.allSatisfy { byte in
            (48...57).contains(byte) || (97...102).contains(byte)
        }
    }
}

public enum TrainingArtifactStoreError: Error, LocalizedError {
    case invalidManifest

    public var errorDescription: String? {
        "Training manifest is invalid or incompatible with this run."
    }
}
