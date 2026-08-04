import Foundation

private struct SelectedTrainingFrameBinding: Equatable {
    let byteCount: UInt64
    let sha256: String
    let pixelSHA256: String
}

private struct SelectedTrainingFrameSnapshot: Equatable {
    let digest: String
    let bindingsByName: [String: SelectedTrainingFrameBinding]
}

extension PipelineRunner {
    func prepareMsplatDataset(
        paths: ProjectPaths,
        maxImageSize: Int,
        geometryArtifact: GeometryArtifact,
        progress: (Double, String) -> Void
    ) async throws -> PreparedMsplatDataset {
        let selectedFrameSnapshot = try selectedTrainingFrameSnapshot(
            paths: paths,
            geometryArtifact: geometryArtifact,
            maximumImageDimension: maxImageSize
        )
        let sourceGeometryManifestSHA256 = try GeometryArtifactStore.manifestDigest(
            matching: geometryArtifact,
            at: paths.geometryManifestURL
        )
        let (sourceSparse, sourceSnapshot) = try verifiedGeometrySource(
            geometryArtifact,
            paths: paths
        )
        let canonicalRegisteredImageNames = try ColmapResidualAnalyzer.analyze(
            modelDirectory: sourceSparse
        ).registeredImageNames
        let preparationKind: MsplatDatasetPreparationKind
        let prepared: (
            url: URL,
            identity: MsplatDatasetIdentity,
            registeredImageNames: [String]
        )
        if try MsplatCameraCompatibility.requiresUndistortion(modelDirectory: sourceSparse) {
            preparationKind = .undistorted
            prepared = try await prepareUndistortedMsplatDataset(
                paths: paths,
                sourceSparse: sourceSparse,
                sourceSnapshot: sourceSnapshot,
                maxImageSize: maxImageSize,
                geometryArtifact: geometryArtifact,
                sourceGeometryManifestSHA256: sourceGeometryManifestSHA256,
                selectedFrameSnapshot: selectedFrameSnapshot,
                progress: progress
            )
        } else {
            preparationKind = .direct
            prepared = try prepareDirectMsplatDataset(
                paths: paths,
                sourceSparse: sourceSparse,
                sourceSnapshot: sourceSnapshot,
                maxImageSize: maxImageSize,
                geometryArtifact: geometryArtifact,
                sourceGeometryManifestSHA256: sourceGeometryManifestSHA256,
                selectedFrameSnapshot: selectedFrameSnapshot,
                progress: progress
            )
        }
        guard try GeometryArtifactStore.manifestDigest(
            matching: geometryArtifact,
            at: paths.geometryManifestURL
        ) == sourceGeometryManifestSHA256,
              prepared.registeredImageNames.count == canonicalRegisteredImageNames.count,
              Set(prepared.registeredImageNames) == Set(canonicalRegisteredImageNames) else {
            throw GeometryArtifactStore.Error.artifactDigestMismatch("geometry manifest")
        }
        let derivation = makeMsplatDatasetDerivation(
            geometryArtifact: geometryArtifact,
            sourceGeometryManifestSHA256: sourceGeometryManifestSHA256,
            preparationKind: preparationKind,
            maxImageSize: maxImageSize,
            registeredImageNames: prepared.registeredImageNames,
            datasetIdentity: prepared.identity
        )
        return PreparedMsplatDataset(
            url: prepared.url,
            identity: prepared.identity,
            derivation: derivation
        )
    }

    private func selectedTrainingFrameSnapshot(
        paths: ProjectPaths,
        geometryArtifact: GeometryArtifact,
        maximumImageDimension: Int
    ) throws -> SelectedTrainingFrameSnapshot {
        let maximumFrameBytes: UInt64 = 512 * 1_024 * 1_024
        let maximumAggregateBytes: UInt64 = 64 * 1_024 * 1_024 * 1_024
        guard maximumImageDimension > 0,
              !geometryArtifact.orderedImageNames.isEmpty,
              geometryArtifact.orderedImageNames.count <= 3_000 else {
            throw GeometryArtifactStore.Error.artifactDigestMismatch("selected frames")
        }
        let initialDigest = try GeometryArtifactStore.selectedFramesDigest(
            orderedImageNames: geometryArtifact.orderedImageNames,
            projectPaths: paths
        )
        guard initialDigest == geometryArtifact.selectedFramesDigest else {
            throw GeometryArtifactStore.Error.artifactDigestMismatch("selected frames")
        }

        var aggregateBytes: UInt64 = 0
        var bindings: [String: SelectedTrainingFrameBinding] = [:]
        bindings.reserveCapacity(geometryArtifact.orderedImageNames.count)
        for name in geometryArtifact.orderedImageNames {
            try Task.checkCancellation()
            let image = try paths.resolveProjectRelativePath("Frames/selected/\(name)")
            let identity = try Self.selectedFrameContentIdentity(
                at: image,
                maximumBytes: maximumFrameBytes,
                maximumPixelDimension: maximumImageDimension
            )
            guard identity.byteCount <= maximumAggregateBytes - aggregateBytes else {
                throw GeometryArtifactStore.Error.artifactDigestMismatch("selected frames")
            }
            aggregateBytes += identity.byteCount
            bindings[name] = SelectedTrainingFrameBinding(
                byteCount: identity.byteCount,
                sha256: identity.sha256,
                pixelSHA256: identity.pixelSHA256
            )
        }
        guard try GeometryArtifactStore.selectedFramesDigest(
            orderedImageNames: geometryArtifact.orderedImageNames,
            projectPaths: paths
        ) == initialDigest else {
            throw GeometryArtifactStore.Error.artifactDigestMismatch("selected frames")
        }
        return SelectedTrainingFrameSnapshot(
            digest: initialDigest,
            bindingsByName: bindings
        )
    }

    private func validateDirectMsplatImages(
        in dataset: URL,
        registeredImageNames: [String],
        selectedFrameSnapshot: SelectedTrainingFrameSnapshot,
        maximumImageDimension: Int
    ) throws {
        let maximumFrameBytes: UInt64 = 512 * 1_024 * 1_024
        let images = dataset.appendingPathComponent("images", isDirectory: true)
        for name in registeredImageNames {
            try Task.checkCancellation()
            guard let source = selectedFrameSnapshot.bindingsByName[name] else {
                throw GeometryArtifactStore.Error.artifactDigestMismatch("selected frames")
            }
            let retained = images.appendingPathComponent(name)
            let identity = try Self.selectedFrameContentIdentity(
                at: retained,
                maximumBytes: maximumFrameBytes,
                maximumPixelDimension: maximumImageDimension
            )
            guard identity.byteCount == source.byteCount,
                  identity.sha256 == source.sha256,
                  identity.pixelSHA256 == source.pixelSHA256 else {
                throw GeometryArtifactStore.Error.artifactDigestMismatch("training images")
            }
        }
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
        sourceGeometryManifestSHA256: String,
        selectedFrameSnapshot: SelectedTrainingFrameSnapshot,
        progress: (Double, String) -> Void
    ) async throws -> (
        url: URL,
        identity: MsplatDatasetIdentity,
        registeredImageNames: [String]
    ) {
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
        for name in ["cameras.bin", "images.bin", "points3D.bin"] {
            try Task.checkCancellation()
            try fm.moveItem(
                at: workspaceSparse.appendingPathComponent(name),
                to: candidateSparse.appendingPathComponent(name)
            )
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
        for name in ["cameras.txt", "images.txt", "points3D.txt"] {
            let file = candidateSparse.appendingPathComponent(name)
            if fm.fileExists(atPath: file.path) {
                try fm.removeItem(at: file)
            }
        }
        let registeredImageNames = try registeredMsplatImageNames(
            paths: paths,
            sparseDirectory: candidateSparse,
            geometryArtifact: geometryArtifact
        )
        guard registeredImageNames.count == geometryArtifact.registeredViewCount,
              correctedImages.map(\.lastPathComponent).sorted()
                == registeredImageNames.sorted() else {
            throw PipelineError.outputMissing
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
            sourceSnapshot: sourceSnapshot,
            geometryArtifact: geometryArtifact,
            sourceGeometryManifestSHA256: sourceGeometryManifestSHA256,
            selectedFrameSnapshot: selectedFrameSnapshot,
            maximumImageDimension: maxImageSize,
            preparationKind: .undistorted,
            registeredImageNames: registeredImageNames,
            expectedIdentity: identity
        )
        progress(1.0, "Corrected lens images are ready")
        return (dataset, identity, registeredImageNames)
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

    func currentMsplatDatasetDerivation(
        paths: ProjectPaths,
        geometryArtifact: GeometryArtifact,
        maxImageSize: Int
    ) throws -> MsplatDatasetDerivationArtifact {
        let selectedFrameSnapshot = try selectedTrainingFrameSnapshot(
            paths: paths,
            geometryArtifact: geometryArtifact,
            maximumImageDimension: maxImageSize
        )
        let sourceSparse = try paths.resolveProjectRelativePath(
            geometryArtifact.sourceModelPath
        )
        let preparationKind: MsplatDatasetPreparationKind = try
            MsplatCameraCompatibility.requiresUndistortion(modelDirectory: sourceSparse)
                ? .undistorted
                : .direct
        let dataset = paths.trainingURL.appendingPathComponent(
            "msplat_dataset",
            isDirectory: true
        )
        let images = dataset.appendingPathComponent("images", isDirectory: true)
        let sparse = dataset.appendingPathComponent("sparse/0", isDirectory: true)
        let registeredImageNames = try registeredMsplatImageNames(
            paths: paths,
            sparseDirectory: sparse,
            geometryArtifact: geometryArtifact
        )
        guard registeredImageNames.count == geometryArtifact.registeredViewCount,
              try FileManager.default.contentsOfDirectory(atPath: images.path).sorted()
                == registeredImageNames.sorted() else {
            throw PipelineError.outputMissing
        }
        if preparationKind == .direct {
            try validateDirectMsplatImages(
                in: dataset,
                registeredImageNames: registeredImageNames,
                selectedFrameSnapshot: selectedFrameSnapshot,
                maximumImageDimension: maxImageSize
            )
        }
        let identity = try msplatDatasetIdentity(at: dataset)
        return makeMsplatDatasetDerivation(
            geometryArtifact: geometryArtifact,
            sourceGeometryManifestSHA256: try GeometryArtifactStore.manifestDigest(
                matching: geometryArtifact,
                at: paths.geometryManifestURL
            ),
            preparationKind: preparationKind,
            maxImageSize: maxImageSize,
            registeredImageNames: registeredImageNames,
            datasetIdentity: identity
        )
    }

    private func makeMsplatDatasetDerivation(
        geometryArtifact: GeometryArtifact,
        sourceGeometryManifestSHA256: String,
        preparationKind: MsplatDatasetPreparationKind,
        maxImageSize: Int,
        registeredImageNames: [String],
        datasetIdentity: MsplatDatasetIdentity
    ) -> MsplatDatasetDerivationArtifact {
        MsplatDatasetDerivationArtifact(
            sourceGeometryManifestSHA256: sourceGeometryManifestSHA256,
            sourceSelectedFramesDigest: geometryArtifact.selectedFramesDigest,
            preparationKind: preparationKind,
            maximumImageDimension: maxImageSize,
            toolchainVersion: geometryArtifact.provenance.toolchainVersion,
            colmapProvenance: geometryArtifact.provenance.solver,
            registeredImageNames: registeredImageNames,
            datasetInputDigest: datasetIdentity.inputDigest,
            datasetGeometryDigest: datasetIdentity.geometryDigest
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
        maxImageSize: Int,
        geometryArtifact: GeometryArtifact,
        sourceGeometryManifestSHA256: String,
        selectedFrameSnapshot: SelectedTrainingFrameSnapshot,
        progress: (Double, String) -> Void
    ) throws -> (
        url: URL,
        identity: MsplatDatasetIdentity,
        registeredImageNames: [String]
    ) {
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
        for name in ["cameras.txt", "images.txt", "points3D.txt"] {
            try fm.removeItem(at: sparse.appendingPathComponent(name))
        }
        let registeredImageNames = try registeredMsplatImageNames(
            paths: paths,
            sparseDirectory: sparse,
            geometryArtifact: geometryArtifact
        )
        guard registeredImageNames.count == geometryArtifact.registeredViewCount else {
            throw PipelineError.outputMissing
        }
        let registeredSet = Set(registeredImageNames)
        for image in imageFiles where !registeredSet.contains(image.lastPathComponent) {
            try fm.removeItem(at: images.appendingPathComponent(image.lastPathComponent))
        }
        guard try fm.contentsOfDirectory(atPath: images.path).sorted()
                == registeredImageNames.sorted() else {
            throw PipelineError.outputMissing
        }
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
            sourceSnapshot: sourceSnapshot,
            geometryArtifact: geometryArtifact,
            sourceGeometryManifestSHA256: sourceGeometryManifestSHA256,
            selectedFrameSnapshot: selectedFrameSnapshot,
            maximumImageDimension: maxImageSize,
            preparationKind: .direct,
            registeredImageNames: registeredImageNames,
            expectedIdentity: identity
        )
        progress(1.0, "Preparing msplat dataset: ready.")
        return (dataset, identity, registeredImageNames)
    }

    private func registeredMsplatImageNames(
        paths: ProjectPaths,
        sparseDirectory: URL,
        geometryArtifact: GeometryArtifact
    ) throws -> [String] {
        // Imported geometry has no COLMAP feature database to attest membership
        // against; the registered images are read directly from the adopted
        // model (text or binary), which the caller cross-checks against the
        // canonical analysis of the source model.
        if geometryArtifact.resolvedSource == .imported {
            let (model, _) = try ColmapModelReader.read(modelDirectory: sparseDirectory)
            return model.images.map(\.name).sorted()
        }
        return try ColmapSparseModelMembershipReader(
            databaseURL: paths.colmapDatabaseURL,
            selectedImageNames: geometryArtifact.orderedImageNames
        ).registeredImageNames(
            in: sparseDirectory,
            checkCancellation: { try Task.checkCancellation() }
        )
    }

    private func publishMsplatDatasetCandidate(
        _ candidate: URL,
        paths: ProjectPaths,
        sourceSparse: URL,
        sourceSnapshot: GeometryModelSnapshot.Verified,
        geometryArtifact: GeometryArtifact,
        sourceGeometryManifestSHA256: String,
        selectedFrameSnapshot: SelectedTrainingFrameSnapshot,
        maximumImageDimension: Int,
        preparationKind: MsplatDatasetPreparationKind,
        registeredImageNames: [String],
        expectedIdentity: MsplatDatasetIdentity
    ) throws -> URL {
        let fm = FileManager.default
        let dataset = paths.trainingURL.appendingPathComponent("msplat_dataset", isDirectory: true)
        let backup = paths.trainingURL.appendingPathComponent(
            ".msplat-dataset-backup",
            isDirectory: true
        )
        try GeometryModelSnapshot.validate(sourceSnapshot, at: sourceSparse)
        guard try GeometryArtifactStore.manifestDigest(
            matching: geometryArtifact,
            at: paths.geometryManifestURL
        ) == sourceGeometryManifestSHA256 else {
            throw GeometryArtifactStore.Error.artifactDigestMismatch("geometry manifest")
        }
        func validatePublishedInputs(at datasetURL: URL) throws {
            guard try selectedTrainingFrameSnapshot(
                paths: paths,
                geometryArtifact: geometryArtifact,
                maximumImageDimension: maximumImageDimension
            ) == selectedFrameSnapshot,
            try msplatDatasetIdentity(at: datasetURL) == expectedIdentity else {
                throw GeometryArtifactStore.Error.artifactDigestMismatch("selected frames")
            }
            if preparationKind == .direct {
                try validateDirectMsplatImages(
                    in: datasetURL,
                    registeredImageNames: registeredImageNames,
                    selectedFrameSnapshot: selectedFrameSnapshot,
                    maximumImageDimension: maximumImageDimension
                )
            }
        }
        try validatePublishedInputs(at: candidate)
        try removeItemIfPresent(backup)
        if entryExists(at: dataset) {
            try fm.moveItem(at: dataset, to: backup)
        }
        do {
            try fm.moveItem(at: candidate, to: dataset)
            try validatePublishedInputs(at: dataset)
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

    func msplatMetallibPath() -> URL {
        config.toolchain.metallib
    }

    func msplatResumeURL(
        paths: ProjectPaths,
        profile: DetailProfile,
        cameraOrderSeed: UInt64,
        resolvedPlan: ResolvedRunPlan,
        datasetIdentity: MsplatDatasetIdentity,
        datasetDerivation: MsplatDatasetDerivationArtifact
    ) throws -> URL? {
        guard FileManager.default.fileExists(atPath: paths.trainingManifestURL.path) else {
            return nil
        }
        let artifact = try TrainingArtifactStore.load(
            from: paths.trainingManifestURL,
            projectPaths: paths
        )
        guard artifact.completionStatus == .checkpointed,
              artifact.detailProfile == profile,
              artifact.iterationLimit == resolvedPlan.trainerIterationLimit,
              artifact.plateauWindow == resolvedPlan.plateauWindow,
              artifact.memoryBudgetBytes > 0,
              artifact.memoryBudgetBytes <= resolvedPlan.trainerMemoryBudgetBytes,
              artifact.cameraOrderSeed == cameraOrderSeed,
              artifact.checkpointPath == "Training/checkpoints/msplat" else {
            throw MsplatCheckpointValidationError(
                "saved training state does not match the resolved training plan"
            )
        }
        do {
            guard artifact.inputDigest == datasetIdentity.inputDigest,
                  artifact.geometryDigest == datasetIdentity.geometryDigest,
                  artifact.datasetDerivation == datasetDerivation else {
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
        resourceAdmission: TrainingResourceAdmission,
        datasetIdentity: MsplatDatasetIdentity,
        datasetDerivation: MsplatDatasetDerivationArtifact,
        paths: ProjectPaths
    ) throws -> TrainingArtifact {
        guard receipt.inputDigest == datasetIdentity.inputDigest,
              receipt.geometryDigest == datasetIdentity.geometryDigest,
              datasetDerivation.datasetInputDigest == datasetIdentity.inputDigest,
              datasetDerivation.datasetGeometryDigest == datasetIdentity.geometryDigest,
              receipt.memoryBudgetBytes > 0,
              receipt.memoryBudgetBytes <= resolvedPlan.trainerMemoryBudgetBytes,
              UInt64(exactly: receipt.memoryBudgetBytes).map({
                  $0 <= resourceAdmission.allowedTrainerBytes
              }) == true,
              TrainingMemoryBudget.isValid(resourceAdmission),
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
            datasetDerivation: datasetDerivation,
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
            resourceAdmission: resourceAdmission,
            rasterFallbackCount: receipt.rasterFallbackCount,
            rasterExactFallbackElapsedSeconds: receipt.rasterExactFallbackElapsedSeconds,
            rasterExactBufferGrowthCount: receipt.rasterExactBufferGrowthCount,
            rasterExactBufferBytesAdded: receipt.rasterExactBufferBytesAdded,
            rasterReplayElapsedSeconds: receipt.rasterReplayElapsedSeconds,
            rasterPeakExactIntersectionCapacity: receipt.rasterPeakExactIntersectionCapacity,
            droppedIntersectionCount: receipt.droppedIntersectionCount,
            completionStatus: .checkpointed
        )
        try TrainingArtifactStore.persist(artifact, paths: paths)
        return artifact
    }

    @discardableResult
    func persistMsplatCompletion(
        _ result: MsplatTrainingResult,
        profile: DetailProfile,
        cameraOrderSeed: UInt64,
        resolvedPlan: ResolvedRunPlan,
        resourceAdmission: TrainingResourceAdmission,
        datasetIdentity: MsplatDatasetIdentity,
        datasetDerivation: MsplatDatasetDerivationArtifact,
        paths: ProjectPaths
    ) throws -> TrainingArtifact {
        guard result.inputDigest == datasetIdentity.inputDigest,
              result.geometryDigest == datasetIdentity.geometryDigest,
              datasetDerivation.datasetInputDigest == datasetIdentity.inputDigest,
              datasetDerivation.datasetGeometryDigest == datasetIdentity.geometryDigest else {
            throw PipelineError.outputMissing
        }
        let outputURL = paths.msplatOutputURL
        let outputEvidence: ValidatedPlyArtifactEvidence
        do {
            outputEvidence = try ProjectArtifactValidator.validatedPlyEvidence(at: outputURL)
        } catch {
            throw PipelineError.outputMissing
        }
        guard result.memoryBudgetBytes > 0,
              result.memoryBudgetBytes <= resolvedPlan.trainerMemoryBudgetBytes,
              UInt64(exactly: result.memoryBudgetBytes).map({
                  $0 <= resourceAdmission.allowedTrainerBytes
              }) == true,
              TrainingMemoryBudget.isValid(resourceAdmission),
              result.droppedIntersectionCount == 0,
              outputEvidence.vertexCount == result.gaussianCount else {
            throw PipelineError.outputMissing
        }
        let artifact = TrainingArtifact(
            trainerVersion: "1.1.3 (git 106499b)",
            runtimeVersion: "native-metal-cli-v2",
            trainerBuildDigest: result.trainerBuildDigest,
            inputDigest: result.inputDigest,
            geometryDigest: result.geometryDigest,
            datasetDerivation: datasetDerivation,
            detailProfile: profile,
            iterationLimit: result.iterationLimit,
            plateauWindow: result.plateauWindow,
            cameraOrderSeed: cameraOrderSeed,
            completedIteration: result.completedIteration,
            checkpointPath: nil,
            checkpointDigest: nil,
            outputPath: "Training/msplat/splat.ply",
            outputSHA256: outputEvidence.sha256,
            outputBytes: Int64(outputEvidence.byteCount),
            gaussianCount: result.gaussianCount,
            elapsedSeconds: result.elapsedSeconds,
            peakMemoryBytes: result.peakMemoryBytes,
            memoryBudgetBytes: result.memoryBudgetBytes,
            resourceAdmission: resourceAdmission,
            rasterFallbackCount: result.rasterFallbackCount,
            rasterExactFallbackElapsedSeconds: result.rasterExactFallbackElapsedSeconds,
            rasterExactBufferGrowthCount: result.rasterExactBufferGrowthCount,
            rasterExactBufferBytesAdded: result.rasterExactBufferBytesAdded,
            rasterReplayElapsedSeconds: result.rasterReplayElapsedSeconds,
            rasterPeakExactIntersectionCapacity: result.rasterPeakExactIntersectionCapacity,
            droppedIntersectionCount: result.droppedIntersectionCount,
            sceneBounds: outputEvidence.sceneBounds,
            completionStatus: .completed
        )
        try TrainingArtifactStore.persist(artifact, paths: paths)
        return artifact
    }

    /// Rebinds a completed training receipt to the validated public PLY. The trainer's
    /// private output remains available until the run is durably marked done, so a
    /// crash during export can still resume without retraining.
    static func promoteMsplatCompletionToPublicOutput(
        paths: ProjectPaths
    ) throws -> CanonicalSplatPublication {
        guard var artifact = try? TrainingArtifactStore.load(
            from: paths.trainingManifestURL,
            projectPaths: paths
        ), artifact.completionStatus == .completed else {
            throw PipelineError.outputMissing
        }
        if artifact.outputPath == "Output/splat.ply" {
            try TrainingArtifactStore.validateCompletedOutput(
                artifact,
                at: paths.outputURL.appendingPathComponent("splat.ply")
            )
            return try SubjectIsolationArtifactStore.captureCanonicalPublication(
                paths: paths
            )
        }
        guard artifact.outputPath == "Training/msplat/splat.ply" else {
            throw PipelineError.outputMissing
        }

        artifact.outputPath = "Output/splat.ply"
        try TrainingArtifactStore.persist(artifact, paths: paths)
        return try SubjectIsolationArtifactStore.captureCanonicalPublication(
            paths: paths
        )
    }

    /// Finished projects retain the exact dataset consumed by the trainer so release
    /// verification can independently recompute its input and geometry identities.
    /// Only the trainer-private duplicate PLY is disposable after public output is
    /// durably authenticated.
    func removeDisposableCompletedTrainingPayload(paths: ProjectPaths) throws {
        let fileManager = FileManager.default
        let disposableOutput = try paths.resolveProjectRelativePath(
            "Training/msplat/splat.ply"
        )
        if fileManager.fileExists(atPath: disposableOutput.path)
            || (try? fileManager.destinationOfSymbolicLink(atPath: disposableOutput.path)) != nil {
            try fileManager.removeItem(at: disposableOutput)
        }
        try removeTrainingPreviewPayload(paths: paths)
    }

    /// Removes the preview and any temporary a crashed publication left behind.
    /// The preview is a display cache tied to a live run: keeping ~26 MB per
    /// finished project to describe a model that has since been superseded is pure
    /// accumulation. Safe to call when nothing is present.
    func removeTrainingPreviewPayload(paths: ProjectPaths) throws {
        let fileManager = FileManager.default
        let preview = try paths.resolveProjectRelativePath("Training/msplat/preview.ply")
        try removeRegularFileIfPresent(preview)

        // Publication temporaries are ".preview.ply.preview.tmp.<pid>.ply" beside the
        // preview. A crash between create and rename strands one, and the next run
        // only replaces the canonical name.
        let directory = preview.deletingLastPathComponent()
        let prefix = ".\(preview.lastPathComponent).preview.tmp."
        guard let entries = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ) else {
            return
        }
        for entry in entries {
            let name = entry.lastPathComponent
            guard name.hasPrefix(prefix), name.hasSuffix(".ply") else { continue }
            // The producer writes exactly one decimal pid between the fixed affixes.
            // Anything else in that slot is not ours to delete.
            let pid = name.dropFirst(prefix.count).dropLast(".ply".count)
            guard !pid.isEmpty, pid.allSatisfy({ $0.isASCII && $0.isNumber }) else { continue }
            // Resolve through the project's own containment check so a symlinked
            // entry cannot walk the delete outside the bundle.
            guard let relative = try? paths.projectRelativePath(for: entry),
                  let resolved = try? paths.resolveProjectRelativePath(relative) else {
                continue
            }
            try? removeRegularFileIfPresent(resolved)
        }
    }

    /// Deletes only an ordinary file. `removeItem` is recursive, so a directory or
    /// symlink wearing a preview's name would otherwise take its contents with it.
    private func removeRegularFileIfPresent(_ url: URL) throws {
        var status = stat()
        guard lstat(url.path, &status) == 0 else { return }
        guard status.st_mode & S_IFMT == S_IFREG else { return }
        try FileManager.default.removeItem(at: url)
    }
}
