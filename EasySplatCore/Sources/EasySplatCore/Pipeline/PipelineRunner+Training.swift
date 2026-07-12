import Foundation

extension PipelineRunner {
    func prepareMsplatDataset(
        paths: ProjectPaths,
        maxImageSize: Int,
        learnedPointInitializer: LearnedPointInitializerArtifact?,
        progress: (Double, String) -> Void
    ) async throws -> URL {
        let sourceSparseRoot = paths.colmapSparseURL.appendingPathComponent("0", isDirectory: true)
        let sourceSparse = try resolveSparseModelDirectory(at: sourceSparseRoot)
        if try MsplatCameraCompatibility.requiresUndistortion(modelDirectory: sourceSparse) {
            return try await prepareUndistortedMsplatDataset(
                paths: paths,
                sourceSparse: sourceSparse,
                maxImageSize: maxImageSize,
                learnedPointInitializer: learnedPointInitializer,
                progress: progress
            )
        }

        return try prepareTrainingDataset(
            paths: paths,
            datasetName: "msplat_dataset",
            progressName: "msplat",
            sparseEnsureMessage: "ensuring binary model files",
            requiredSparseFiles: ["cameras.bin", "images.bin", "points3D.bin"],
            prepareSourceSparse: { _ = try regenerateBinarySparseModelFiles(at: $0) },
            ensureCopiedSparse: { try requireBinarySparseModelFiles(at: $0); return false },
            finalizeCopiedSparse: { sparse in
                guard let learnedPointInitializer else { return }
                try mergeLearnedPointInitializer(
                    learnedPointInitializer,
                    paths: paths,
                    into: sparse.appendingPathComponent("points3D.txt")
                )
                _ = try regenerateBinarySparseModelFiles(at: sparse)
            },
            progress: progress
        )
    }

    private func prepareUndistortedMsplatDataset(
        paths: ProjectPaths,
        sourceSparse: URL,
        maxImageSize: Int,
        learnedPointInitializer: LearnedPointInitializerArtifact?,
        progress: (Double, String) -> Void
    ) async throws -> URL {
        let fm = FileManager.default
        try requireTextSparseModelFiles(at: sourceSparse)

        let stagingRoot = paths.trainingURL.appendingPathComponent(
            ".msplat-undistort-\(UUID().uuidString)",
            isDirectory: true
        )
        let workspace = stagingRoot.appendingPathComponent("workspace", isDirectory: true)
        let candidate = stagingRoot.appendingPathComponent("candidate", isDirectory: true)
        try fm.createDirectory(at: workspace, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: stagingRoot) }

        progress(0.05, "Preparing corrected lens images")
        try await tooling.colmap.runImageUndistorter(
            colmapPath: config.toolchain.colmap,
            imagePath: paths.framesSelectedURL,
            inputPath: sourceSparse,
            outputPath: workspace,
            maxImageSize: maxImageSize,
            environment: colmapOptionsForMatching().environment,
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
        if let learnedPointInitializer {
            _ = try ensureTextSparseModelFiles(at: candidateSparse)
            try mergeLearnedPointInitializer(
                learnedPointInitializer,
                paths: paths,
                into: candidateSparse.appendingPathComponent("points3D.txt")
            )
            _ = try regenerateBinarySparseModelFiles(at: candidateSparse)
        }
        _ = try msplatDatasetIdentity(at: candidate)

        let dataset = paths.trainingURL.appendingPathComponent("msplat_dataset", isDirectory: true)
        let backup = paths.trainingURL.appendingPathComponent(".msplat-dataset-backup", isDirectory: true)
        if fm.fileExists(atPath: backup.path) { try fm.removeItem(at: backup) }
        if fm.fileExists(atPath: dataset.path) { try fm.moveItem(at: dataset, to: backup) }
        do {
            try fm.moveItem(at: candidate, to: dataset)
            if fm.fileExists(atPath: backup.path) { try fm.removeItem(at: backup) }
        } catch {
            if fm.fileExists(atPath: dataset.path) { try? fm.removeItem(at: dataset) }
            if fm.fileExists(atPath: backup.path) { try? fm.moveItem(at: backup, to: dataset) }
            throw error
        }
        progress(1.0, "Corrected lens images are ready")
        return dataset
    }

    private func mergeLearnedPointInitializer(
        _ initializer: LearnedPointInitializerArtifact,
        paths: ProjectPaths,
        into canonicalPointsURL: URL
    ) throws {
        let initializerURL = try paths.resolveProjectRelativePath(initializer.path)
        try Da3LearnedPointInitializer.merge(
            learnedPointsURL: initializerURL,
            into: canonicalPointsURL,
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
        let imageFiles = try FileManager.default.contentsOfDirectory(
            at: images,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ).filter { supportedImageExtensions.contains($0.pathExtension.lowercased()) }
        return try MsplatDatasetIdentity.compute(
            imageFiles: imageFiles,
            sparseDirectory: sparse
        )
    }

    private func prepareTrainingDataset(
        paths: ProjectPaths,
        datasetName: String,
        progressName: String,
        sparseEnsureMessage: String,
        requiredSparseFiles: [String],
        prepareSourceSparse: (URL) throws -> Void,
        ensureCopiedSparse: (URL) throws -> Bool,
        finalizeCopiedSparse: (URL) throws -> Void,
        progress: (Double, String) -> Void
    ) throws -> URL {
        let fm = FileManager.default
        let dataset = paths.trainingURL.appendingPathComponent(datasetName, isDirectory: true)
        let images = dataset.appendingPathComponent("images", isDirectory: true)
        let sparse = dataset.appendingPathComponent("sparse/0", isDirectory: true)
        try resetDirectory(images)
        try resetDirectory(sparse)

        let selected = try fm.contentsOfDirectory(at: paths.framesSelectedURL, includingPropertiesForKeys: nil)
        let imageFiles = selected.filter { supportedImageExtensions.contains($0.pathExtension.lowercased()) }
        guard !imageFiles.isEmpty else { throw PipelineError.invalidInput }
        let imageProgressScale = 0.7
        let imageTotal = max(1, imageFiles.count)
        for (index, url) in imageFiles.enumerated() {
            let dest = images.appendingPathComponent(url.lastPathComponent)
            if fm.fileExists(atPath: dest.path) { try fm.removeItem(at: dest) }
            try fm.copyItem(at: url, to: dest)
            if index % 5 == 0 || index + 1 == imageFiles.count {
                let fraction = imageProgressScale * (Double(index + 1) / Double(imageTotal))
                progress(fraction, "Preparing \(progressName) dataset (images) \(index + 1)/\(imageTotal)")
            }
        }

        let sourceSparseRoot = paths.colmapSparseURL.appendingPathComponent("0", isDirectory: true)
        let sourceSparse = try resolveSparseModelDirectory(at: sourceSparseRoot)
        guard sparseModelFilesExist(at: sourceSparse) else { throw PipelineError.outputMissing }
        try prepareSourceSparse(sourceSparse)
        let files = try fm.contentsOfDirectory(
            at: sourceSparse,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        )
        let fileItems = files.filter { url in
            (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) ?? false
        }
        let sparseProgressScale = 1.0 - imageProgressScale
        let sparseTotal = max(1, fileItems.count)
        for (index, file) in fileItems.enumerated() {
            let dest = sparse.appendingPathComponent(file.lastPathComponent)
            if fm.fileExists(atPath: dest.path) { try fm.removeItem(at: dest) }
            try fm.copyItem(at: file, to: dest)
            let fraction = imageProgressScale + sparseProgressScale * (Double(index + 1) / Double(sparseTotal))
            progress(fraction, "Preparing \(progressName) dataset (sparse) \(index + 1)/\(sparseTotal)")
        }

        progress(0.98, "Preparing \(progressName) dataset (sparse): \(sparseEnsureMessage).")
        let converted = try ensureCopiedSparse(sparse)
        if converted {
            progress(0.99, "Preparing \(progressName) dataset (sparse): conversion complete.")
        }

        for name in requiredSparseFiles {
            let fileURL = sparse.appendingPathComponent(name)
            guard fm.fileExists(atPath: fileURL.path) else { throw PipelineError.outputMissing }
            let size = (try? fm.attributesOfItem(atPath: fileURL.path)[.size] as? NSNumber)?.int64Value ?? 0
            guard size > 0 else { throw PipelineError.outputMissing }
        }
        try finalizeCopiedSparse(sparse)
        return dataset
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

    /// The geometry manifest authenticates the canonical text model. Always derive the
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

        let converterOptions = colmapOptionsForMatching()
        try tooling.colmap.runModelConverter(
            colmapPath: config.toolchain.colmap,
            inputPath: textInput,
            outputPath: binaryOutput,
            outputType: "BIN",
            environment: converterOptions.environment,
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
        seed: UInt64,
        resolvedPlan: ResolvedRunPlan,
        datasetIdentity: MsplatDatasetIdentity
    ) throws -> URL? {
        guard let artifact = metadata.trainingArtifact else { return nil }
        guard artifact.completionStatus == .checkpointed,
              artifact.detailProfile == profile,
              artifact.iterationLimit == resolvedPlan.trainerIterationLimit,
              artifact.plateauWindow == resolvedPlan.plateauWindow,
              artifact.deterministicSeed == seed,
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
        seed: UInt64,
        resolvedPlan: ResolvedRunPlan,
        datasetIdentity: MsplatDatasetIdentity,
        paths: ProjectPaths
    ) throws -> TrainingArtifact {
        guard receipt.inputDigest == datasetIdentity.inputDigest,
              receipt.geometryDigest == datasetIdentity.geometryDigest else {
            throw MsplatCheckpointValidationError(
                "native checkpoint identity does not match the prepared dataset"
            )
        }
        let artifact = TrainingArtifact(
            trainerVersion: "1.1.3 (git 106499b)",
            runtimeVersion: "native-metal-cli-v1",
            trainerBuildDigest: receipt.trainerBuildDigest,
            inputDigest: receipt.inputDigest,
            geometryDigest: receipt.geometryDigest,
            detailProfile: profile,
            iterationLimit: resolvedPlan.trainerIterationLimit,
            plateauWindow: resolvedPlan.plateauWindow,
            deterministicSeed: seed,
            completedIteration: receipt.iteration,
            checkpointPath: "Training/checkpoints/msplat",
            checkpointDigest: receipt.payloadSHA256,
            outputPath: nil,
            gaussianCount: receipt.gaussianCount,
            elapsedSeconds: nil,
            peakMemoryBytes: receipt.peakMemoryBytes,
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
        seed: UInt64,
        resolvedPlan: ResolvedRunPlan,
        paths: ProjectPaths
    ) throws -> TrainingArtifact {
        let outputURL = paths.msplatOutputURL
        guard ProjectArtifactValidator.validatePlyFile(at: outputURL) == .valid,
              let header = ProjectArtifactValidator.readPlyHeader(at: outputURL),
              header.vertexCount == result.gaussianCount,
              let size = try? outputURL.resourceValues(forKeys: [.fileSizeKey]).fileSize else {
            throw PipelineError.outputMissing
        }
        let artifact = TrainingArtifact(
            trainerVersion: "1.1.3 (git 106499b)",
            runtimeVersion: "native-metal-cli-v1",
            trainerBuildDigest: result.trainerBuildDigest,
            inputDigest: result.inputDigest,
            geometryDigest: result.geometryDigest,
            detailProfile: profile,
            iterationLimit: result.iterationLimit,
            plateauWindow: result.plateauWindow,
            deterministicSeed: seed,
            completedIteration: result.completedIteration,
            checkpointPath: nil,
            checkpointDigest: nil,
            outputPath: "Training/msplat/splat.ply",
            outputSHA256: try GeometryArtifactStore.sha256(of: outputURL),
            outputBytes: Int64(size),
            gaussianCount: result.gaussianCount,
            elapsedSeconds: result.elapsedSeconds,
            peakMemoryBytes: result.peakMemoryBytes,
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

    /// Finished projects retain canonical geometry, the training manifest, and one
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
