import Darwin
import Foundation

public struct FinishedProjectAuthenticatedToolchain: Sendable {
    public let root: URL
    public let installation: ToolchainInstallationEvidence

    public init(root: URL, installation: ToolchainInstallationEvidence) {
        self.root = root
        self.installation = installation
    }
}

extension ProjectArtifactValidator {
    /// The release-only finished-project gate. In addition to rederiving selected
    /// video frames, this reruns the exact training-dataset preparation with the
    /// signed COLMAP executable and compares the complete reproduced closure.
    public static func validateFinishedProject(
        at projectURL: URL,
        expectedInput: FinishedProjectExpectedInput,
        context: FinishedProjectValidationContext = .currentReleaseHost(),
        authenticatedToolchain: FinishedProjectAuthenticatedToolchain
    ) async throws -> FinishedProjectArtifactEvidence {
        let initialInputSnapshot = try captureExpectedInputSnapshot(expectedInput)
        let initial = try await validateFinishedProject(
            at: projectURL,
            expectedInput: expectedInput,
            context: context,
            independentlyRederiveVideoFrames: true
        )
        try validateToolchainBinding(
            finishedProject: initial,
            installation: authenticatedToolchain.installation
        )
        let colmap = try authenticatedColmapURL(
            context: authenticatedToolchain,
            geometry: initial.geometryArtifact
        )
        try await reproduceRetainedTrainingDataset(
            projectURL: projectURL,
            geometryArtifact: initial.geometryArtifact,
            expectedDerivation: initial.trainingArtifact.datasetDerivation,
            expectedIdentity: MsplatDatasetIdentity(
                inputDigest: initial.trainingArtifact.inputDigest,
                geometryDigest: initial.trainingArtifact.geometryDigest
            ),
            resolvedRunPlan: initial.resolvedRunPlan,
            colmapURL: colmap,
            tooling: .init()
        )
        guard try ColmapRunner().captureRuntimeClosure(colmapPath: colmap)
                == initial.geometryArtifact.workerExecution.colmapRuntimeClosure else {
            throw finishedDatasetError("the signed COLMAP runtime changed during replay")
        }

        let final = try await validateFinishedProject(
            at: projectURL,
            expectedInput: expectedInput,
            context: context,
            independentlyRederiveVideoFrames: true
        )
        try validateToolchainBinding(
            finishedProject: final,
            installation: authenticatedToolchain.installation
        )
        try requireExpectedInputSnapshotUnchanged(
            initialInputSnapshot,
            expectedInput: expectedInput
        )
        guard try canonicalMetadataData(final.metadata)
                == canonicalMetadataData(initial.metadata),
              final.requestedRunOptions == initial.requestedRunOptions,
              final.resolvedRunPlan == initial.resolvedRunPlan,
              final.toolchainRequest == initial.toolchainRequest,
              final.geometryArtifact == initial.geometryArtifact,
              final.trainingArtifact == initial.trainingArtifact,
              final.outputURL.standardizedFileURL == initial.outputURL.standardizedFileURL,
              final.outputEvidence == initial.outputEvidence else {
            throw finishedDatasetError(
                "the finished project changed during signed dataset replay"
            )
        }
        return final
    }

#if DEBUG
    static func test_requireExpectedInputSnapshotUnchanged(
        _ initial: FinishedProjectExpectedInputContinuitySnapshot,
        expectedInput: FinishedProjectExpectedInput
    ) throws {
        try requireExpectedInputSnapshotUnchanged(
            initial,
            expectedInput: expectedInput
        )
    }

    static func test_reproduceRetainedTrainingDataset(
        projectURL: URL,
        geometryArtifact: GeometryArtifact,
        expectedDerivation: MsplatDatasetDerivationArtifact,
        expectedIdentity: MsplatDatasetIdentity,
        resolvedRunPlan: ResolvedRunPlan,
        colmapURL: URL,
        tooling: PipelineRunner.Tooling
    ) async throws {
        try await reproduceRetainedTrainingDataset(
            projectURL: projectURL,
            geometryArtifact: geometryArtifact,
            expectedDerivation: expectedDerivation,
            expectedIdentity: expectedIdentity,
            resolvedRunPlan: resolvedRunPlan,
            colmapURL: colmapURL,
            tooling: tooling
        )
    }
#endif

    private static func requireExpectedInputSnapshotUnchanged(
        _ initial: FinishedProjectExpectedInputContinuitySnapshot,
        expectedInput: FinishedProjectExpectedInput
    ) throws {
        let current: FinishedProjectExpectedInputContinuitySnapshot
        do {
            current = try captureExpectedInputSnapshot(expectedInput)
        } catch {
            throw finishedDatasetError(
                "the expected release input changed during signed dataset replay"
            )
        }
        guard current == initial else {
            throw finishedDatasetError(
                "the expected release input changed during signed dataset replay"
            )
        }
    }

    private static func authenticatedColmapURL(
        context: FinishedProjectAuthenticatedToolchain,
        geometry: GeometryArtifact
    ) throws -> URL {
        let root = context.root.standardizedFileURL.resolvingSymlinksInPath()
        let colmap = root.appendingPathComponent("bin/colmap").standardizedFileURL
        let runtimeClosure = geometry.workerExecution.colmapRuntimeClosure
        guard context.installation.toolchainVersion == geometry.provenance.toolchainVersion,
              context.installation.installedCriticalFileSHA256["bin/colmap"]
                == runtimeClosure.sha256(for: "bin/colmap"),
              FileManager.default.isExecutableFile(atPath: colmap.path),
              try GeometryArtifactStore.sha256(of: colmap)
                == runtimeClosure.sha256(for: "bin/colmap"),
              try ColmapRunner().captureRuntimeClosure(colmapPath: colmap)
                == runtimeClosure else {
            throw finishedDatasetError(
                "the dataset replay executable is not the signed geometry solver"
            )
        }
        return colmap
    }

    private static func reproduceRetainedTrainingDataset(
        projectURL: URL,
        geometryArtifact: GeometryArtifact,
        expectedDerivation: MsplatDatasetDerivationArtifact,
        expectedIdentity: MsplatDatasetIdentity,
        resolvedRunPlan: ResolvedRunPlan,
        colmapURL: URL,
        tooling: PipelineRunner.Tooling
    ) async throws {
        let sourcePaths = ProjectPaths(root: projectURL)
        let scratchParent = FileManager.default.temporaryDirectory.appendingPathComponent(
            "EasySplat-finished-dataset-replay-\(UUID().uuidString)",
            isDirectory: true
        )
        let scratchRoot = scratchParent.appendingPathComponent(
            "Replay.easysplatproj",
            isDirectory: true
        )
        let scratchPaths = ProjectPaths(root: scratchRoot)
        try FileManager.default.createDirectory(
            at: scratchParent,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        defer { try? FileManager.default.removeItem(at: scratchParent) }
        try scratchPaths.ensureDirectories()

        try copyStableFile(
            from: sourcePaths.geometryManifestURL,
            to: scratchPaths.geometryManifestURL
        )
        try copyStableFile(
            from: sourcePaths.colmapDatabaseURL,
            to: scratchPaths.colmapDatabaseURL
        )
        let sourceModel = try sourcePaths.resolveProjectRelativePath(
            geometryArtifact.sourceModelPath
        )
        let scratchModel = try scratchPaths.resolveProjectRelativePath(
            geometryArtifact.sourceModelPath
        )
        try FileManager.default.createDirectory(
            at: scratchModel,
            withIntermediateDirectories: true
        )
        for name in ["cameras.txt", "images.txt", "points3D.txt"] {
            try copyStableFile(
                from: sourceModel.appendingPathComponent(name),
                to: scratchModel.appendingPathComponent(name),
                expectedSHA256: geometryArtifact.modelHashes[name]
            )
        }
        for name in geometryArtifact.orderedImageNames {
            try copyStableFile(
                from: sourcePaths.framesSelectedURL.appendingPathComponent(name),
                to: scratchPaths.framesSelectedURL.appendingPathComponent(name)
            )
        }
        if let initializer = geometryArtifact.learnedPointInitializer {
            let source = try sourcePaths.resolveProjectRelativePath(initializer.path)
            let destination = try scratchPaths.resolveProjectRelativePath(initializer.path)
            try FileManager.default.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try copyStableFile(
                from: source,
                to: destination,
                expectedSHA256: initializer.sha256
            )
        }

        let root = colmapURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let da3Root = root.appendingPathComponent("da3", isDirectory: true)
        let replayToolchain = ToolchainPaths(
            root: root,
            authenticatedVersion: geometryArtifact.provenance.toolchainVersion,
            colmap: colmapURL,
            msplat: root.appendingPathComponent("bin/easysplat-train"),
            da3: Da3Toolchain(
                root: da3Root,
                sfmTool: da3Root.appendingPathComponent("bin/da3-sfm"),
                python: da3Root.appendingPathComponent("bin/python3"),
                models: da3Root.appendingPathComponent("models", isDirectory: true),
                modelBundle: da3Root.appendingPathComponent("models/da3-base"),
                smallModelBundle: da3Root.appendingPathComponent("models/da3-small")
            )
        )
        let runner = PipelineRunner(
            projectURL: scratchRoot,
            config: .init(
                toolchain: replayToolchain,
                developmentOverrides: DevelopmentOverrides(benchmarkSeed: 42),
                resolvedRunPlan: resolvedRunPlan
            ),
            tooling: tooling
        )
        let reproduced = try await runner.prepareMsplatDataset(
            paths: scratchPaths,
            maxImageSize: resolvedRunPlan.maximumImageDimension,
            geometryArtifact: geometryArtifact,
            progress: { _, _ in }
        )
        guard reproduced.identity == expectedIdentity,
              reproduced.derivation == expectedDerivation else {
            throw finishedDatasetError(
                "the retained training dataset cannot be reproduced by signed COLMAP"
            )
        }

        let retained = try sourcePaths.resolveProjectRelativePath(
            "Training/msplat_dataset"
        )
        let names = expectedDerivation.registeredImageNames
        for name in names {
            try requireMatchingFile(
                retained.appendingPathComponent("images/\(name)"),
                reproduced.url.appendingPathComponent("images/\(name)")
            )
        }
        for name in [
            "cameras.bin",
            "images.bin",
            "points3D.bin",
            MsplatOrientationOverlay.fileName,
        ] {
            try requireMatchingFile(
                retained.appendingPathComponent("sparse/0/\(name)"),
                reproduced.url.appendingPathComponent("sparse/0/\(name)")
            )
        }
    }

    private static func requireMatchingFile(_ lhs: URL, _ rhs: URL) throws {
        guard try GeometryArtifactStore.sha256(of: lhs)
                == GeometryArtifactStore.sha256(of: rhs) else {
            throw finishedDatasetError(
                "the retained file \(lhs.lastPathComponent) differs from signed replay"
            )
        }
    }

    private static func canonicalMetadataData(_ metadata: ProjectMetadata) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(metadata)
    }

    private static func copyStableFile(
        from source: URL,
        to destination: URL,
        expectedSHA256: String? = nil
    ) throws {
        let sourceDescriptor = Darwin.open(
            source.path,
            O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC
        )
        guard sourceDescriptor >= 0 else {
            throw finishedDatasetError("a replay source file is unavailable")
        }
        defer { Darwin.close(sourceDescriptor) }
        var initial = stat()
        guard fstat(sourceDescriptor, &initial) == 0,
              (initial.st_mode & S_IFMT) == S_IFREG,
              initial.st_nlink == 1,
              initial.st_size > 0 else {
            throw finishedDatasetError("a replay source file is unsafe")
        }
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let destinationDescriptor = Darwin.open(
            destination.path,
            O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC,
            mode_t(S_IRUSR | S_IWUSR)
        )
        guard destinationDescriptor >= 0 else {
            throw finishedDatasetError("a replay destination file cannot be created")
        }
        var copySucceeded = false
        defer {
            Darwin.close(destinationDescriptor)
            if !copySucceeded { try? FileManager.default.removeItem(at: destination) }
        }
        var buffer = [UInt8](repeating: 0, count: 1_048_576)
        var copied: off_t = 0
        while true {
            let count = buffer.withUnsafeMutableBytes {
                Darwin.read(sourceDescriptor, $0.baseAddress, $0.count)
            }
            if count < 0 && errno == EINTR { continue }
            guard count >= 0 else {
                throw finishedDatasetError("a replay source file cannot be read")
            }
            if count == 0 { break }
            var offset = 0
            while offset < count {
                let written = buffer.withUnsafeBytes {
                    Darwin.write(
                        destinationDescriptor,
                        $0.baseAddress?.advanced(by: offset),
                        count - offset
                    )
                }
                if written < 0 && errno == EINTR { continue }
                guard written > 0 else {
                    throw finishedDatasetError("a replay destination file cannot be written")
                }
                offset += written
            }
            copied += off_t(count)
        }
        var final = stat()
        var pathState = stat()
        guard copied == initial.st_size,
              fstat(sourceDescriptor, &final) == 0,
              lstat(source.path, &pathState) == 0,
              final.st_dev == initial.st_dev,
              final.st_ino == initial.st_ino,
              final.st_size == initial.st_size,
              final.st_mtimespec.tv_sec == initial.st_mtimespec.tv_sec,
              final.st_mtimespec.tv_nsec == initial.st_mtimespec.tv_nsec,
              final.st_ctimespec.tv_sec == initial.st_ctimespec.tv_sec,
              final.st_ctimespec.tv_nsec == initial.st_ctimespec.tv_nsec,
              pathState.st_dev == initial.st_dev,
              pathState.st_ino == initial.st_ino,
              pathState.st_size == initial.st_size,
              fsync(destinationDescriptor) == 0 else {
            throw finishedDatasetError("a replay source file changed during copy")
        }
        copySucceeded = true
        if let expectedSHA256,
           try GeometryArtifactStore.sha256(of: destination) != expectedSHA256 {
            throw finishedDatasetError("a replay source digest is not authenticated")
        }
    }

    private static func finishedDatasetError(
        _ reason: String
    ) -> FinishedProjectArtifactValidationError {
        .invalidProject(reason)
    }
}
