import Foundation

extension PipelineRunner {
    func prepareMsplatDataset(
        paths: ProjectPaths,
        maxImageSize: Int,
        geometryArtifact: GeometryArtifact,
        progress: (Double, String) -> Void
    ) async throws -> (url: URL, identity: MsplatDatasetIdentity) {
        let (sourceSparse, sourceSnapshot) = try verifiedGeometrySource(
            geometryArtifact,
            paths: paths
        )
        if try MsplatCameraCompatibility.requiresUndistortion(modelDirectory: sourceSparse) {
            return try await prepareUndistortedMsplatDataset(
                paths: paths,
                sourceSparse: sourceSparse,
                sourceSnapshot: sourceSnapshot,
                maxImageSize: maxImageSize,
                geometryArtifact: geometryArtifact,
                progress: progress
            )
        }

        return try prepareDirectMsplatDataset(
            paths: paths,
            sourceSparse: sourceSparse,
            sourceSnapshot: sourceSnapshot,
            geometryArtifact: geometryArtifact,
            progress: progress
        )
    }

    private func verifiedGeometrySource(
        _ geometryArtifact: GeometryArtifact,
        paths: ProjectPaths
    ) throws -> (URL, GeometryModelSnapshot.Verified) {
        guard geometryArtifact.schemaVersion == GeometryArtifact.currentSchemaVersion else {
            throw GeometryArtifactStore.Error.invalidSchema(geometryArtifact.schemaVersion)
        }
        let sourceSparse = try paths.resolveProjectRelativePath(geometryArtifact.sourceModelPath)
        let sourceSnapshot = try GeometryModelSnapshot.capture(in: sourceSparse)
        let requiredNames = ["cameras.txt", "images.txt", "points3D.txt"]
        guard Set(geometryArtifact.modelHashes.keys) == Set(requiredNames) else {
            throw GeometryArtifactStore.Error.invalidDigest("model")
        }
        for name in requiredNames {
            guard geometryArtifact.modelHashes[name] == sourceSnapshot.modelHashes[name] else {
                throw GeometryArtifactStore.Error.modelHashMismatch(name)
            }
        }
        return (sourceSparse, sourceSnapshot)
    }

    private func prepareUndistortedMsplatDataset(
        paths: ProjectPaths,
        sourceSparse: URL,
        sourceSnapshot: GeometryModelSnapshot.Verified,
        maxImageSize: Int,
        geometryArtifact: GeometryArtifact,
        progress: (Double, String) -> Void
    ) async throws -> (url: URL, identity: MsplatDatasetIdentity) {
        let fm = FileManager.default
        try requireTextSparseModelFiles(at: sourceSparse)

        let stagingRoot = paths.trainingURL.appendingPathComponent(
            ".msplat-undistort-\(UUID().uuidString)",
            isDirectory: true
        )
        let undistorterInput = stagingRoot.appendingPathComponent(
            "verified-source",
            isDirectory: true
        )
        let workspace = stagingRoot.appendingPathComponent("workspace", isDirectory: true)
        let candidate = stagingRoot.appendingPathComponent("candidate", isDirectory: true)
        try fm.createDirectory(at: undistorterInput, withIntermediateDirectories: true)
        try fm.createDirectory(at: workspace, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: stagingRoot) }

        progress(0.05, "Preparing corrected lens images")
        for name in ["cameras.txt", "images.txt", "points3D.txt"] {
            try fm.copyItem(
                at: sourceSparse.appendingPathComponent(name),
                to: undistorterInput.appendingPathComponent(name)
            )
        }
        _ = try regenerateBinarySparseModelFiles(at: undistorterInput)
        try requireBinarySparseModelFiles(at: undistorterInput)
        try Task.checkCancellation()
        try await tooling.colmap.runImageUndistorter(
            colmapPath: config.toolchain.colmap,
            imagePath: paths.framesSelectedURL,
            inputPath: undistorterInput,
            outputPath: workspace,
            maxImageSize: maxImageSize,
            environment: colmapUtilityEnvironment(),
            onLog: { _, _ in }
        )
        try Task.checkCancellation()

        let workspaceImages = workspace.appendingPathComponent("images", isDirectory: true)
        let workspaceSparse = workspace.appendingPathComponent("sparse", isDirectory: true)
        try requireBinarySparseModelFiles(at: workspaceSparse)
        let correctedImages = try fm.contentsOfDirectory(
            at: workspaceImages,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ).filter { supportedImageExtensions.contains($0.pathExtension.lowercased()) }
        guard !correctedImages.isEmpty else { throw PipelineError.outputMissing }

        let candidateSparseRoot = candidate.appendingPathComponent("sparse", isDirectory: true)
        let candidateSparse = candidateSparseRoot.appendingPathComponent("0", isDirectory: true)
        try fm.createDirectory(at: candidateSparse, withIntermediateDirectories: true)
        try fm.moveItem(
            at: workspaceImages,
            to: candidate.appendingPathComponent("images", isDirectory: true)
        )
        for file in try fm.contentsOfDirectory(
            at: workspaceSparse,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) {
            try Task.checkCancellation()
            let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true else { continue }
            try fm.moveItem(at: file, to: candidateSparse.appendingPathComponent(file.lastPathComponent))
        }
        try requireBinarySparseModelFiles(at: candidateSparse)
        if let learnedPointInitializer = geometryArtifact.learnedPointInitializer {
            _ = try ensureTextSparseModelFiles(at: candidateSparse)
            try mergeLearnedPointInitializer(
                learnedPointInitializer,
                paths: paths,
                into: candidateSparse.appendingPathComponent("points3D.txt")
            )
            _ = try regenerateBinarySparseModelFiles(at: candidateSparse)
        }
        try Task.checkCancellation()
        try MsplatOrientationOverlay.write(
            geometryArtifact.canonicalOrientation,
            to: candidateSparse
        )
        let identity = try msplatDatasetIdentity(at: candidate)
        try Task.checkCancellation()

        let dataset = try publishMsplatDatasetCandidate(
            candidate,
            paths: paths,
            sourceSparse: sourceSparse,
            sourceSnapshot: sourceSnapshot
        )
        progress(1.0, "Corrected lens images are ready")
        return (dataset, identity)
    }

    private func mergeLearnedPointInitializer(
        _ initializer: LearnedPointInitializerArtifact,
        paths: ProjectPaths,
        into pointsURL: URL
    ) throws {
        let initializerURL = try paths.resolveProjectRelativePath(initializer.path)
        try Da3LearnedPointInitializer.merge(
            learnedPointsURL: initializerURL,
            into: pointsURL,
            expectedPointCount: initializer.pointCount,
            maximumPointCount: initializer.pointCount,
            expectedSHA256: initializer.sha256
        )
    }

    func currentMsplatDatasetIdentity(paths: ProjectPaths) throws -> MsplatDatasetIdentity {
        try msplatDatasetIdentity(
            at: paths.trainingURL.appendingPathComponent("msplat_dataset", isDirectory: true)
        )
    }

    func msplatDatasetIdentity(at datasetURL: URL) throws -> MsplatDatasetIdentity {
        let images = datasetURL.appendingPathComponent("images", isDirectory: true)
        let sparse = datasetURL.appendingPathComponent("sparse/0", isDirectory: true)
        return try MsplatDatasetIdentity.compute(
            imageDirectory: images,
            sparseDirectory: sparse
        )
    }

    private func prepareDirectMsplatDataset(
        paths: ProjectPaths,
        sourceSparse: URL,
        sourceSnapshot: GeometryModelSnapshot.Verified,
        geometryArtifact: GeometryArtifact,
        progress: (Double, String) -> Void
    ) throws -> (url: URL, identity: MsplatDatasetIdentity) {
        let fm = FileManager.default
        let stagingRoot = paths.trainingURL.appendingPathComponent(
            ".msplat-prepare-\(UUID().uuidString)",
            isDirectory: true
        )
        let candidate = stagingRoot.appendingPathComponent("candidate", isDirectory: true)
        let images = candidate.appendingPathComponent("images", isDirectory: true)
        let sparse = candidate.appendingPathComponent("sparse/0", isDirectory: true)
        try fm.createDirectory(at: images, withIntermediateDirectories: true)
        try fm.createDirectory(at: sparse, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: stagingRoot) }

        let selected = try fm.contentsOfDirectory(at: paths.framesSelectedURL, includingPropertiesForKeys: nil)
        let imageFiles = selected.filter { supportedImageExtensions.contains($0.pathExtension.lowercased()) }
        guard !imageFiles.isEmpty else { throw PipelineError.invalidInput }
        let imageProgressScale = 0.7
        let imageTotal = max(1, imageFiles.count)
        for (index, url) in imageFiles.enumerated() {
            try Task.checkCancellation()
            let dest = images.appendingPathComponent(url.lastPathComponent)
            if fm.fileExists(atPath: dest.path) { try fm.removeItem(at: dest) }
            try fm.copyItem(at: url, to: dest)
            if index % 5 == 0 || index + 1 == imageFiles.count {
                let fraction = imageProgressScale * (Double(index + 1) / Double(imageTotal))
                progress(fraction, "Preparing msplat dataset (images) \(index + 1)/\(imageTotal)")
            }
        }

        guard sparseModelFilesExist(at: sourceSparse) else { throw PipelineError.outputMissing }
        try requireTextSparseModelFiles(at: sourceSparse)
        let files = try fm.contentsOfDirectory(
            at: sourceSparse,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        )
        let authenticatedTextFiles = Set(["cameras.txt", "images.txt", "points3D.txt"])
        let fileItems = files.filter { url in
            authenticatedTextFiles.contains(url.lastPathComponent)
                && ((try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) ?? false)
        }
        // Leave the final five percent for model conversion, verification, and
        // publication so progress never moves backward after the file copies finish.
        let sparseProgressScale = 0.25
        let sparseTotal = max(1, fileItems.count)
        for (index, file) in fileItems.enumerated() {
            try Task.checkCancellation()
            let dest = sparse.appendingPathComponent(file.lastPathComponent)
            if fm.fileExists(atPath: dest.path) { try fm.removeItem(at: dest) }
            try fm.copyItem(at: file, to: dest)
            let fraction = imageProgressScale + sparseProgressScale * (Double(index + 1) / Double(sparseTotal))
            progress(fraction, "Preparing msplat dataset (sparse) \(index + 1)/\(sparseTotal)")
        }

        progress(0.98, "Preparing msplat dataset (sparse): ensuring binary model files.")
        if let learnedPointInitializer = geometryArtifact.learnedPointInitializer {
            try mergeLearnedPointInitializer(
                learnedPointInitializer,
                paths: paths,
                into: sparse.appendingPathComponent("points3D.txt")
            )
        }
        _ = try regenerateBinarySparseModelFiles(at: sparse)
        try requireBinarySparseModelFiles(at: sparse)
        progress(0.99, "Preparing msplat dataset (sparse): conversion complete.")
        try MsplatOrientationOverlay.write(
            geometryArtifact.canonicalOrientation,
            to: sparse
        )
        let identity = try msplatDatasetIdentity(at: candidate)
        try Task.checkCancellation()
        let dataset = try publishMsplatDatasetCandidate(
            candidate,
            paths: paths,
            sourceSparse: sourceSparse,
            sourceSnapshot: sourceSnapshot
        )
        progress(1.0, "Preparing msplat dataset: ready.")
        return (dataset, identity)
    }

    private func publishMsplatDatasetCandidate(
        _ candidate: URL,
        paths: ProjectPaths,
        sourceSparse: URL,
        sourceSnapshot: GeometryModelSnapshot.Verified
    ) throws -> URL {
        let fm = FileManager.default
        let dataset = paths.trainingURL.appendingPathComponent("msplat_dataset", isDirectory: true)
        let backup = paths.trainingURL.appendingPathComponent(
            ".msplat-dataset-backup",
            isDirectory: true
        )
        try GeometryModelSnapshot.validate(sourceSnapshot, at: sourceSparse)
        try removeItemIfPresent(backup)
        if entryExists(at: dataset) {
            try fm.moveItem(at: dataset, to: backup)
        }
        do {
            try fm.moveItem(at: candidate, to: dataset)
            try removeItemIfPresent(backup)
            return dataset
        } catch {
            try? removeItemIfPresent(dataset)
            if entryExists(at: backup) {
                try? fm.moveItem(at: backup, to: dataset)
            }
            throw error
        }
    }

    private func entryExists(at url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
            || ((try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)) != nil)
    }

    func requireTextSparseModelFiles(at url: URL) throws {
        let fm = FileManager.default
        let txtFiles = ["cameras.txt", "images.txt", "points3D.txt"]
        guard txtFiles.allSatisfy({ fm.fileExists(atPath: url.appendingPathComponent($0).path) }) else {
            throw PipelineError.outputMissing
        }
    }

    func requireBinarySparseModelFiles(at url: URL) throws {
        let fm = FileManager.default
        for name in ["cameras.bin", "images.bin", "points3D.bin"] {
            let file = url.appendingPathComponent(name)
            let values = try file.resourceValues(forKeys: [
                .isRegularFileKey,
                .isSymbolicLinkKey,
                .fileSizeKey,
            ])
            guard fm.fileExists(atPath: file.path),
                  values.isRegularFile == true,
                  values.isSymbolicLink != true,
                  (values.fileSize ?? 0) > 0 else {
                throw PipelineError.outputMissing
            }
        }
    }

    /// The geometry manifest authenticates the accepted text model. Always derive the
    /// trainer's binary model from that verified source so stale binaries from an older
    /// training attempt can never bypass the geometry gate.
    func regenerateBinarySparseModelFiles(at url: URL) throws -> Bool {
        try requireTextSparseModelFiles(at: url)
        let fm = FileManager.default
        let binFiles = ["cameras.bin", "images.bin", "points3D.bin"]
        let stagingRoot = url.deletingLastPathComponent().appendingPathComponent(
            ".binary-model-\(UUID().uuidString)",
            isDirectory: true
        )
        let textInput = stagingRoot.appendingPathComponent("text", isDirectory: true)
        let binaryOutput = stagingRoot.appendingPathComponent("binary", isDirectory: true)
        try fm.createDirectory(at: textInput, withIntermediateDirectories: true)
        try fm.createDirectory(at: binaryOutput, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: stagingRoot) }
        for name in ["cameras.txt", "images.txt", "points3D.txt"] {
            try fm.copyItem(
                at: url.appendingPathComponent(name),
                to: textInput.appendingPathComponent(name)
            )
        }

        try tooling.colmap.runModelConverter(
            colmapPath: config.toolchain.colmap,
            inputPath: textInput,
            outputPath: binaryOutput,
            outputType: "BIN",
            environment: colmapUtilityEnvironment(),
            onLog: { _, _ in }
        )

        for name in binFiles {
            let source = binaryOutput.appendingPathComponent(name)
            let values = try source.resourceValues(forKeys: [
                .isRegularFileKey,
                .isSymbolicLinkKey,
                .fileSizeKey,
            ])
            guard values.isRegularFile == true,
                  values.isSymbolicLink != true,
                  (values.fileSize ?? 0) > 0 else {
                throw PipelineError.outputMissing
            }
            let destination = url.appendingPathComponent(name)
            if fm.fileExists(atPath: destination.path) {
                _ = try fm.replaceItemAt(destination, withItemAt: source)
            } else {
                try fm.moveItem(at: source, to: destination)
            }
        }
        return true
    }

    func msplatToolPath() -> URL {
        config.toolchain.msplat
    }

    func msplatResumeURL(
        metadata: ProjectMetadata,
        paths: ProjectPaths,
        profile: DetailProfile,
        cameraOrderSeed: UInt64,
        resolvedPlan: ResolvedRunPlan,
        datasetIdentity: MsplatDatasetIdentity
    ) throws -> URL? {
        guard let artifact = metadata.trainingArtifact else { return nil }
        guard artifact.completionStatus == .checkpointed,
              artifact.detailProfile == profile,
              artifact.iterationLimit == resolvedPlan.trainerIterationLimit,
              artifact.plateauWindow == resolvedPlan.plateauWindow,
              artifact.memoryBudgetBytes == resolvedPlan.trainerMemoryBudgetBytes,
              artifact.cameraOrderSeed == cameraOrderSeed,
              artifact.checkpointPath == "Training/checkpoints/msplat" else {
            throw MsplatCheckpointValidationError(
                "saved training state does not match the resolved training plan"
            )
        }
        do {
            guard artifact.inputDigest == datasetIdentity.inputDigest,
                  artifact.geometryDigest == datasetIdentity.geometryDigest else {
                throw MsplatCheckpointValidationError(
                    "saved training state does not match the current input or geometry"
                )
            }
            let checkpointParent = try paths.resolveProjectRelativePath("Training/checkpoints")
            let checkpointURL = checkpointParent.appendingPathComponent("msplat", isDirectory: true)
            _ = try MsplatCheckpointValidator.validateResume(
                checkpointURL: checkpointURL,
                artifact: artifact
            )
            return checkpointURL
        } catch let error as MsplatCheckpointValidationError {
            throw error
        } catch {
            throw MsplatCheckpointValidationError(error.localizedDescription)
        }
    }

    @discardableResult
    func persistMsplatCheckpoint(
        _ receipt: MsplatCheckpointReceipt,
        profile: DetailProfile,
        cameraOrderSeed: UInt64,
        resolvedPlan: ResolvedRunPlan,
        datasetIdentity: MsplatDatasetIdentity,
        paths: ProjectPaths
    ) throws -> TrainingArtifact {
        guard receipt.inputDigest == datasetIdentity.inputDigest,
              receipt.geometryDigest == datasetIdentity.geometryDigest,
              receipt.memoryBudgetBytes == resolvedPlan.trainerMemoryBudgetBytes,
              receipt.droppedIntersectionCount == 0 else {
            throw MsplatCheckpointValidationError(
                "native checkpoint identity does not match the prepared dataset"
            )
        }
        let artifact = TrainingArtifact(
            trainerVersion: "1.1.3 (git 106499b)",
            runtimeVersion: "native-metal-cli-v2",
            trainerBuildDigest: receipt.trainerBuildDigest,
            inputDigest: receipt.inputDigest,
            geometryDigest: receipt.geometryDigest,
            detailProfile: profile,
            iterationLimit: resolvedPlan.trainerIterationLimit,
            plateauWindow: resolvedPlan.plateauWindow,
            cameraOrderSeed: cameraOrderSeed,
            completedIteration: receipt.iteration,
            checkpointPath: "Training/checkpoints/msplat",
            checkpointDigest: receipt.payloadSHA256,
            outputPath: nil,
            gaussianCount: receipt.gaussianCount,
            elapsedSeconds: nil,
            peakMemoryBytes: receipt.peakMemoryBytes,
            memoryBudgetBytes: receipt.memoryBudgetBytes,
            rasterFallbackCount: receipt.rasterFallbackCount,
            rasterExactFallbackElapsedSeconds: receipt.rasterExactFallbackElapsedSeconds,
            rasterExactBufferGrowthCount: receipt.rasterExactBufferGrowthCount,
            rasterExactBufferBytesAdded: receipt.rasterExactBufferBytesAdded,
            rasterReplayElapsedSeconds: receipt.rasterReplayElapsedSeconds,
            rasterPeakExactIntersectionCapacity: receipt.rasterPeakExactIntersectionCapacity,
            droppedIntersectionCount: receipt.droppedIntersectionCount,
            completionStatus: .checkpointed
        )
        var currentMetadata = try ProjectMetadataStore.load(from: paths.metadataURL)
        try TrainingArtifactStore.persist(artifact, metadata: &currentMetadata, paths: paths)
        return artifact
    }

    @discardableResult
    func persistMsplatCompletion(
        _ result: MsplatTrainingResult,
        profile: DetailProfile,
        cameraOrderSeed: UInt64,
        resolvedPlan: ResolvedRunPlan,
        datasetIdentity: MsplatDatasetIdentity,
        paths: ProjectPaths
    ) throws -> TrainingArtifact {
        guard result.inputDigest == datasetIdentity.inputDigest,
              result.geometryDigest == datasetIdentity.geometryDigest else {
            throw PipelineError.outputMissing
        }
        let outputURL = paths.msplatOutputURL
        guard result.memoryBudgetBytes == resolvedPlan.trainerMemoryBudgetBytes,
              result.droppedIntersectionCount == 0,
              ProjectArtifactValidator.validatePlyFile(at: outputURL) == .valid,
              let header = ProjectArtifactValidator.readPlyHeader(at: outputURL),
              header.vertexCount == result.gaussianCount,
              let size = try? outputURL.resourceValues(forKeys: [.fileSizeKey]).fileSize else {
            throw PipelineError.outputMissing
        }
        let artifact = TrainingArtifact(
            trainerVersion: "1.1.3 (git 106499b)",
            runtimeVersion: "native-metal-cli-v2",
            trainerBuildDigest: result.trainerBuildDigest,
            inputDigest: result.inputDigest,
            geometryDigest: result.geometryDigest,
            detailProfile: profile,
            iterationLimit: result.iterationLimit,
            plateauWindow: result.plateauWindow,
            cameraOrderSeed: cameraOrderSeed,
            completedIteration: result.completedIteration,
            checkpointPath: nil,
            checkpointDigest: nil,
            outputPath: "Training/msplat/splat.ply",
            outputSHA256: try GeometryArtifactStore.sha256(of: outputURL),
            outputBytes: Int64(size),
            gaussianCount: result.gaussianCount,
            elapsedSeconds: result.elapsedSeconds,
            peakMemoryBytes: result.peakMemoryBytes,
            memoryBudgetBytes: result.memoryBudgetBytes,
            rasterFallbackCount: result.rasterFallbackCount,
            rasterExactFallbackElapsedSeconds: result.rasterExactFallbackElapsedSeconds,
            rasterExactBufferGrowthCount: result.rasterExactBufferGrowthCount,
            rasterExactBufferBytesAdded: result.rasterExactBufferBytesAdded,
            rasterReplayElapsedSeconds: result.rasterReplayElapsedSeconds,
            rasterPeakExactIntersectionCapacity: result.rasterPeakExactIntersectionCapacity,
            droppedIntersectionCount: result.droppedIntersectionCount,
            sceneBounds: result.sceneBounds,
            completionStatus: .completed
        )
        var currentMetadata = try ProjectMetadataStore.load(from: paths.metadataURL)
        try TrainingArtifactStore.persist(artifact, metadata: &currentMetadata, paths: paths)
        return artifact
    }

    /// Rebinds a completed training receipt to the validated public PLY. The trainer's
    /// private output remains available until the run is durably marked done, so a
    /// crash during export can still resume without retraining.
    func promoteMsplatCompletionToPublicOutput(paths: ProjectPaths) throws -> TrainingArtifact {
        var metadata = try ProjectMetadataStore.load(from: paths.metadataURL)
        guard var artifact = metadata.trainingArtifact,
              artifact.completionStatus == .completed else {
            throw PipelineError.outputMissing
        }
        if artifact.outputPath == "Output/splat.ply" {
            try TrainingArtifactStore.validateCompletedOutput(
                artifact,
                at: paths.outputURL.appendingPathComponent("splat.ply")
            )
            return artifact
        }
        guard artifact.outputPath == "Training/msplat/splat.ply" else {
            throw PipelineError.outputMissing
        }

        artifact.outputPath = "Output/splat.ply"
        try TrainingArtifactStore.persist(artifact, metadata: &metadata, paths: paths)
        return artifact
    }

    /// Finished projects retain accepted geometry, the training manifest, and one
    /// authenticated public PLY. The copied image dataset and trainer-private PLY are
    /// rebuildable payloads, not user artifacts.
    func removeDisposableCompletedTrainingPayload(paths: ProjectPaths) throws {
        let fileManager = FileManager.default
        let disposableURLs = [
            try paths.resolveProjectRelativePath("Training/msplat_dataset"),
            try paths.resolveProjectRelativePath("Training/msplat/splat.ply"),
        ]
        for url in disposableURLs where fileManager.fileExists(atPath: url.path)
            || (try? fileManager.destinationOfSymbolicLink(atPath: url.path)) != nil {
            try fileManager.removeItem(at: url)
        }
    }
}
