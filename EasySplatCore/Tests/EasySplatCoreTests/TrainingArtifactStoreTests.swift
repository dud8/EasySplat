import XCTest
@testable import EasySplatCore

final class TrainingArtifactStoreTests: XCTestCase {
    func testCheckpointedArtifactPersistsAndRepairsStaleProjectMetadata() throws {
        let context = try makeContext()
        defer { context.cleanup() }
        let artifact = makeCheckpointedArtifact()
        var metadata = context.metadata

        try TrainingArtifactStore.persist(artifact, metadata: &metadata, paths: context.paths)

        XCTAssertEqual(metadata.trainingArtifact, artifact)
        XCTAssertEqual(
            try TrainingArtifactStore.load(
                from: context.paths.trainingManifestURL,
                projectPaths: context.paths
            ),
            artifact
        )

        metadata.trainingArtifact = nil
        try ProjectMetadataStore.save(metadata, to: context.paths.metadataURL)
        var staleMetadata = try ProjectMetadataStore.load(from: context.paths.metadataURL)

        XCTAssertTrue(try TrainingArtifactStore.reconcile(metadata: &staleMetadata, paths: context.paths))
        XCTAssertEqual(staleMetadata.trainingArtifact, artifact)
        XCTAssertEqual(
            try ProjectMetadataStore.load(from: context.paths.metadataURL).trainingArtifact,
            artifact
        )
    }

    func testCompletedArtifactRequiresOutputWithoutCheckpointFields() throws {
        let context = try makeContext()
        defer { context.cleanup() }
        let completed = try makeCompletedArtifact(in: context)

        try TrainingArtifactStore.save(
            completed,
            to: context.paths.trainingManifestURL,
            projectPaths: context.paths
        )
        XCTAssertEqual(
            try TrainingArtifactStore.load(
                from: context.paths.trainingManifestURL,
                projectPaths: context.paths
            ),
            completed
        )

        var invalid = completed
        invalid.checkpointPath = "Training/checkpoints/msplat"
        invalid.checkpointDigest = String(repeating: "d", count: 64)
        XCTAssertThrowsError(
            try TrainingArtifactStore.save(
                invalid,
                to: context.paths.trainingManifestURL,
                projectPaths: context.paths
            )
        )
    }

    func testSaveRequiresMeasuredPeakMemoryForNewArtifacts() throws {
        let context = try makeContext()
        defer { context.cleanup() }

        for prototype in [makeCheckpointedArtifact(), try makeCompletedArtifact(in: context)] {
            var artifact = prototype
            artifact.peakMemoryBytes = 0
            XCTAssertThrowsError(
                try TrainingArtifactStore.save(
                    artifact,
                    to: context.paths.trainingManifestURL,
                    projectPaths: context.paths
                )
            )
            var metadata = context.metadata
            XCTAssertThrowsError(
                try TrainingArtifactStore.persist(
                    artifact,
                    metadata: &metadata,
                    paths: context.paths
                )
            )
        }
    }

    func testLoadRejectsArtifactWithoutPeakMemory() throws {
        let context = try makeContext()
        defer { context.cleanup() }
        let encoder = JSONEncoder()
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoder.encode(makeCheckpointedArtifact()))
                as? [String: Any]
        )
        object.removeValue(forKey: "peakMemoryBytes")
        try JSONSerialization.data(withJSONObject: object)
            .write(to: context.paths.trainingManifestURL)

        XCTAssertThrowsError(
            try TrainingArtifactStore.load(
                from: context.paths.trainingManifestURL,
                projectPaths: context.paths
            )
        )
    }

    func testProjectMetadataRejectsInvalidEmbeddedTrainingArtifact() throws {
        let context = try makeContext()
        defer { context.cleanup() }

        var invalidSchema = makeCheckpointedArtifact()
        invalidSchema.schemaVersion = 99
        var metadata = context.metadata
        metadata.trainingArtifact = invalidSchema
        XCTAssertThrowsError(
            try ProjectMetadataStore.save(metadata, to: context.paths.metadataURL)
        )

        var mismatchedProfile = makeCheckpointedArtifact()
        mismatchedProfile.detailProfile = .highDetail
        mismatchedProfile.iterationLimit = 15_000
        mismatchedProfile.plateauWindow = 1_500
        metadata.trainingArtifact = mismatchedProfile
        XCTAssertThrowsError(
            try ProjectMetadataStore.save(metadata, to: context.paths.metadataURL)
        )
    }

    func testCompletedArtifactBindsPromotedPublicPlyBytes() throws {
        let context = try makeContext()
        defer { context.cleanup() }
        let artifact = try makeCompletedArtifact(in: context)
        var metadata = context.metadata
        try TrainingArtifactStore.persist(artifact, metadata: &metadata, paths: context.paths)

        let publicOutput = context.paths.outputURL.appendingPathComponent("splat.ply")
        try FileManager.default.copyItem(at: context.paths.msplatOutputURL, to: publicOutput)
        var promotedArtifact = artifact
        promotedArtifact.outputPath = "Output/splat.ply"
        try TrainingArtifactStore.persist(
            promotedArtifact,
            metadata: &metadata,
            paths: context.paths
        )
        metadata.outputs = OutputSpec(
            splatPlyPath: "Output/splat.ply",
            colmapModelPath: "SfM/colmap/sparse/0"
        )
        try ProjectMetadataStore.save(metadata, to: context.paths.metadataURL)

        let original = try String(contentsOf: publicOutput, encoding: .utf8)
        let replaced = original.replacingOccurrences(
            of: "0 0 0 1 1 1",
            with: "1 0 0 1 1 1"
        )
        XCTAssertEqual(replaced.utf8.count, original.utf8.count)
        try replaced.write(to: publicOutput, atomically: true, encoding: .utf8)
        XCTAssertEqual(ProjectArtifactValidator.validatePlyFile(at: publicOutput), .valid)

        let loaded = try ProjectMetadataStore.load(from: context.paths.metadataURL)
        let loadedArtifact = try XCTUnwrap(loaded.trainingArtifact)
        XCTAssertThrowsError(
            try TrainingArtifactStore.validateCompletedOutput(
                loadedArtifact,
                at: publicOutput
            )
        )
    }

    func testCheckpointedArtifactRequiresExactCheckpointNamespaceAndNoOutput() throws {
        let context = try makeContext()
        defer { context.cleanup() }

        var invalidPath = makeCheckpointedArtifact()
        invalidPath.checkpointPath = "Training/checkpoints/msplat/older"
        XCTAssertThrowsError(
            try TrainingArtifactStore.save(
                invalidPath,
                to: context.paths.trainingManifestURL,
                projectPaths: context.paths
            )
        )

        var invalidOutput = makeCheckpointedArtifact()
        invalidOutput.outputPath = "Output/splat.ply"
        XCTAssertThrowsError(
            try TrainingArtifactStore.save(
                invalidOutput,
                to: context.paths.trainingManifestURL,
                projectPaths: context.paths
            )
        )
    }

    func testDiscardRemovesOnlyCheckpointedResumeRecord() throws {
        let context = try makeContext()
        defer { context.cleanup() }
        var metadata = context.metadata
        try TrainingArtifactStore.persist(
            makeCheckpointedArtifact(),
            metadata: &metadata,
            paths: context.paths
        )

        try TrainingArtifactStore.discardCheckpointedArtifact(
            metadata: &metadata,
            paths: context.paths
        )

        XCTAssertNil(metadata.trainingArtifact)
        XCTAssertFalse(FileManager.default.fileExists(atPath: context.paths.trainingManifestURL.path))
        XCTAssertNil(try ProjectMetadataStore.load(from: context.paths.metadataURL).trainingArtifact)
    }

    func testLoadRejectsOversizedAndEscapingManifestFiles() throws {
        let context = try makeContext()
        defer { context.cleanup() }

        try Data(repeating: 0x20, count: 1_048_577).write(to: context.paths.trainingManifestURL)
        XCTAssertThrowsError(
            try TrainingArtifactStore.load(
                from: context.paths.trainingManifestURL,
                projectPaths: context.paths
            )
        )

        try FileManager.default.removeItem(at: context.paths.trainingURL)
        let outside = context.root.deletingLastPathComponent()
            .appendingPathComponent("outside-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: outside) }
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: context.paths.trainingURL,
            withDestinationURL: outside
        )
        try JSONEncoder().encode(makeCheckpointedArtifact())
            .write(to: outside.appendingPathComponent("training_manifest.json"))

        XCTAssertThrowsError(
            try TrainingArtifactStore.load(
                from: context.paths.trainingManifestURL,
                projectPaths: context.paths
            )
        )
    }

    func testDiscardRemovesReservedCheckpointSymlinkWithoutTouchingTarget() throws {
        let context = try makeContext()
        defer { context.cleanup() }
        let outside = context.root.deletingLastPathComponent()
            .appendingPathComponent("outside-checkpoint-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: outside) }
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let sentinel = outside.appendingPathComponent("keep.txt")
        try Data("keep".utf8).write(to: sentinel)
        var metadata = context.metadata
        try TrainingArtifactStore.persist(
            makeCheckpointedArtifact(),
            metadata: &metadata,
            paths: context.paths
        )
        // Simulate a project being tampered with after its secured directory layout
        // was created. The production setup now creates this checkpoint directory.
        try FileManager.default.removeItem(at: context.paths.msplatCheckpointURL)
        try FileManager.default.createSymbolicLink(
            at: context.paths.msplatCheckpointURL,
            withDestinationURL: outside
        )

        try TrainingArtifactStore.discardCheckpointedArtifact(
            metadata: &metadata,
            paths: context.paths
        )

        XCTAssertFalse(
            FileManager.default.fileExists(atPath: context.paths.msplatCheckpointURL.path)
        )
        XCTAssertEqual(try Data(contentsOf: sentinel), Data("keep".utf8))
        XCTAssertNil(metadata.trainingArtifact)
    }

    func testDiscardRemovesReservedManifestSymlinkWithoutTouchingTarget() throws {
        let context = try makeContext()
        defer { context.cleanup() }
        var metadata = context.metadata
        try TrainingArtifactStore.persist(
            makeCheckpointedArtifact(),
            metadata: &metadata,
            paths: context.paths
        )
        try FileManager.default.removeItem(at: context.paths.trainingManifestURL)

        let outside = context.root.deletingLastPathComponent()
            .appendingPathComponent("outside-manifest-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: outside) }
        let sentinel = Data("keep outside manifest".utf8)
        try sentinel.write(to: outside)
        try FileManager.default.createSymbolicLink(
            at: context.paths.trainingManifestURL,
            withDestinationURL: outside
        )

        try TrainingArtifactStore.discardCheckpointedArtifact(
            metadata: &metadata,
            paths: context.paths
        )

        XCTAssertNil(metadata.trainingArtifact)
        XCTAssertNil(
            try? FileManager.default.destinationOfSymbolicLink(
                atPath: context.paths.trainingManifestURL.path
            )
        )
        XCTAssertEqual(try Data(contentsOf: outside), sentinel)
    }

    func testDiscardCompletedArtifactPreservesPublicOutputAndDoesNotFollowTrainingSymlink() throws {
        let context = try makeContext()
        defer { context.cleanup() }
        var metadata = context.metadata
        try TrainingArtifactStore.persist(
            try makeCompletedArtifact(in: context),
            metadata: &metadata,
            paths: context.paths
        )
        let publicOutput = context.paths.outputURL.appendingPathComponent("splat.ply")
        let publicBytes = Data("validated public output".utf8)
        try publicBytes.write(to: publicOutput)

        try FileManager.default.removeItem(at: context.paths.trainingURL)
        let outside = context.root.deletingLastPathComponent()
            .appendingPathComponent("outside-training-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: outside) }
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let sentinel = outside.appendingPathComponent("keep.txt")
        try Data("keep".utf8).write(to: sentinel)
        try FileManager.default.createSymbolicLink(
            at: context.paths.trainingURL,
            withDestinationURL: outside
        )

        try TrainingArtifactStore.discardCompletedArtifact(
            metadata: &metadata,
            paths: context.paths
        )

        XCTAssertNil(metadata.trainingArtifact)
        XCTAssertNil(try ProjectMetadataStore.load(from: context.paths.metadataURL).trainingArtifact)
        XCTAssertNil(
            try? FileManager.default.destinationOfSymbolicLink(
                atPath: context.paths.trainingURL.path
            )
        )
        XCTAssertEqual(try Data(contentsOf: sentinel), Data("keep".utf8))
        XCTAssertEqual(try Data(contentsOf: publicOutput), publicBytes)
    }

    private func makeContext() throws -> ArtifactStoreTestContext {
        let root = try TestFileBuilder.makeTempDir()
            .appendingPathComponent("Artifact.easysplatproj", isDirectory: true)
        let paths = ProjectPaths(root: root)
        try paths.ensureDirectories()
        let metadata = ProjectMetadata(
            title: "Artifact",
            input: .photos(folder: "/tmp/photos"),
            requestedRunOptions: RequestedRunOptions(capturePath: .orbit, detailProfile: .balanced)
        )
        try ProjectMetadataStore.save(metadata, to: paths.metadataURL)
        return ArtifactStoreTestContext(root: root, paths: paths, metadata: metadata)
    }

    private func makeCheckpointedArtifact() -> TrainingArtifact {
        TrainingArtifact(
            trainerVersion: "1.1.3 (git 106499b)",
            runtimeVersion: "native-metal-cli-v1",
            trainerBuildDigest: String(repeating: "a", count: 64),
            inputDigest: String(repeating: "b", count: 64),
            geometryDigest: String(repeating: "c", count: 64),
            detailProfile: .balanced,
            iterationLimit: 7_000,
            plateauWindow: 800,
            deterministicSeed: 42,
            completedIteration: 500,
            checkpointPath: "Training/checkpoints/msplat",
            checkpointDigest: String(repeating: "d", count: 64),
            outputPath: nil,
            gaussianCount: 1_250,
            elapsedSeconds: 12.5,
            peakMemoryBytes: 2_147_483_648,
            completionStatus: .checkpointed
        )
    }

    private func makeCompletedArtifact(in context: ArtifactStoreTestContext) throws -> TrainingArtifact {
        try TestFileBuilder.writeMinimalPly(at: context.paths.msplatOutputURL)
        var artifact = makeCheckpointedArtifact()
        artifact.completedIteration = artifact.iterationLimit
        artifact.checkpointPath = nil
        artifact.checkpointDigest = nil
        artifact.outputPath = "Training/msplat/splat.ply"
        artifact.outputSHA256 = try GeometryArtifactStore.sha256(
            of: context.paths.msplatOutputURL
        )
        artifact.outputBytes = Int64(
            try XCTUnwrap(
                context.paths.msplatOutputURL.resourceValues(forKeys: [.fileSizeKey]).fileSize
            )
        )
        artifact.gaussianCount = 1
        artifact.completionStatus = .completed
        return artifact
    }
}

private struct ArtifactStoreTestContext {
    let root: URL
    let paths: ProjectPaths
    let metadata: ProjectMetadata

    func cleanup() {
        try? FileManager.default.removeItem(at: root.deletingLastPathComponent())
    }
}
