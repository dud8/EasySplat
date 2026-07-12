import Foundation

extension PipelineRunner {
    func prepareMsplatDataset(
        paths: ProjectPaths,
        progress: (Double, String) -> Void
    ) throws -> URL {
        try prepareTrainingDataset(
            paths: paths,
            datasetName: "msplat_dataset",
            progressName: "msplat",
            sparseEnsureMessage: "ensuring binary model files",
            requiredSparseFiles: ["cameras.bin", "images.bin", "points3D.bin"],
            prepareSourceSparse: { _ = try regenerateBinarySparseModelFiles(at: $0) },
            ensureCopiedSparse: { try requireBinarySparseModelFiles(at: $0); return false },
            finalizeCopiedSparse: { _ in },
            progress: progress
        )
    }

    func currentMsplatDatasetIdentity(paths: ProjectPaths) throws -> MsplatDatasetIdentity {
        let selected = try FileManager.default.contentsOfDirectory(
            at: paths.framesSelectedURL,
            includingPropertiesForKeys: nil
        )
        let imageFiles = selected.filter {
            supportedImageExtensions.contains($0.pathExtension.lowercased())
        }
        let sparseRoot = paths.colmapSparseURL.appendingPathComponent("0", isDirectory: true)
        let sparse = try resolveSparseModelDirectory(at: sparseRoot)
        return try MsplatDatasetIdentity.compute(
            imageFiles: imageFiles,
            sparseDirectory: sparse
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
        let staging = url.deletingLastPathComponent().appendingPathComponent(
            ".binary-model-\(UUID().uuidString)",
            isDirectory: true
        )
        try fm.createDirectory(at: staging, withIntermediateDirectories: false)
        defer { try? fm.removeItem(at: staging) }

        let converterOptions = colmapOptionsForMatching()
        try tooling.colmap.runModelConverter(
            colmapPath: config.toolchain.colmap,
            inputPath: url,
            outputPath: staging,
            outputType: "BIN",
            environment: converterOptions.environment,
            onLog: { _, _ in }
        )

        for name in binFiles {
            let source = staging.appendingPathComponent(name)
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
            peakMemoryBytes: nil,
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
            gaussianCount: result.gaussianCount,
            elapsedSeconds: result.elapsedSeconds,
            peakMemoryBytes: nil,
            completionStatus: .completed
        )
        var currentMetadata = try ProjectMetadataStore.load(from: paths.metadataURL)
        try TrainingArtifactStore.persist(artifact, metadata: &currentMetadata, paths: paths)
        return artifact
    }
}
