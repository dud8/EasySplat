import XCTest
import UniformTypeIdentifiers
@testable import EasySplatCore

final class PipelineRunnerRetryTests: XCTestCase {
    func testPipelineStageDecodingRejectsUnknownStage() throws {
        let unknown = try JSONEncoder().encode("unknownStage")

        XCTAssertThrowsError(try JSONDecoder().decode(PipelineStage.self, from: unknown)) { error in
            guard case DecodingError.dataCorrupted = error else {
                return XCTFail("Expected dataCorrupted, got \(error)")
            }
        }
    }

    func testIsStageCompleteImportInput() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = ProjectPaths(root: root)
        try paths.ensureDirectories()

        let photosFolder = "/tmp/Photos"
        let dest = paths.originalsURL.appendingPathComponent("Photos", isDirectory: true)
        try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
        XCTAssertTrue(try TestFileBuilder.writeGrayscaleImage(
            url: dest.appendingPathComponent("img001.jpg"),
            size: 16,
            value: 10,
            utType: .jpeg
        ))

        let metadata = ProjectMetadata(title: "Test", input: .photos(folder: photosFolder))
        let runner = makeRunner(projectURL: root)
        XCTAssertTrue(runner.test_isStageComplete(.importInput, paths: paths, metadata: metadata))
    }

    func testIsStageCompleteSelectFrames() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = ProjectPaths(root: root)
        try paths.ensureDirectories()

        let metadata = ProjectMetadata(title: "Test", input: .photos(folder: "/tmp/Photos"))
        let runner = makeRunner(projectURL: root)
        XCTAssertFalse(runner.test_isStageComplete(.selectFrames, paths: paths, metadata: metadata))

        let file = paths.framesSelectedURL.appendingPathComponent("frame_000000.jpg")
        TestFileBuilder.createFile(at: file, data: Data([0x00]))
        let manifest = [TestSelectedFrameMapping(
            outputFileName: "frame_000000.jpg",
            groupId: "photos",
            isVideo: false
        )]
        let data = try JSONEncoder().encode(manifest)
        try data.write(to: paths.framesSelectedManifestURL, options: [.atomic])
        XCTAssertTrue(runner.test_isStageComplete(.selectFrames, paths: paths, metadata: metadata))
    }

    func testSfmMappingWithoutGeometryArtifactIsIncomplete() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = ProjectPaths(root: root)
        try paths.ensureDirectories()
        let sparse = paths.colmapSparseURL.appendingPathComponent("0", isDirectory: true)
        try FileManager.default.createDirectory(at: sparse, withIntermediateDirectories: true)
        try """
        # cameras
        1 SIMPLE_PINHOLE 640 480 500 320 240
        """.write(to: sparse.appendingPathComponent("cameras.txt"), atomically: true, encoding: .utf8)
        try """
        # images
        1 1 0 0 0 0 0 0 1 frame_000000.jpg
        0 0 -1
        """.write(to: sparse.appendingPathComponent("images.txt"), atomically: true, encoding: .utf8)
        try """
        # points
        1 0 0 1 128 128 128 1.0 1 0
        """.write(to: sparse.appendingPathComponent("points3D.txt"), atomically: true, encoding: .utf8)

        let metadata = ProjectMetadata(title: "Test", input: .photos(folder: "/tmp/Photos"))
        let runner = makeRunner(projectURL: root)
        XCTAssertFalse(runner.test_isStageComplete(.sfmMapping, paths: paths, metadata: metadata))
    }

    func testValidateStageOutputRejectsSparseModelWithoutPoints() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = ProjectPaths(root: root)
        try paths.ensureDirectories()
        let sparse = paths.colmapSparseURL.appendingPathComponent("0", isDirectory: true)
        try FileManager.default.createDirectory(at: sparse, withIntermediateDirectories: true)
        try "1 SIMPLE_PINHOLE 640 480 500 320 240\n"
            .write(to: sparse.appendingPathComponent("cameras.txt"), atomically: true, encoding: .utf8)
        try """
        1 1 0 0 0 0 0 0 1 frame_000000.jpg
        0 0 -1
        """.write(to: sparse.appendingPathComponent("images.txt"), atomically: true, encoding: .utf8)
        try "# points\n"
            .write(to: sparse.appendingPathComponent("points3D.txt"), atomically: true, encoding: .utf8)

        let metadata = ProjectMetadata(title: "Test", input: .photos(folder: "/tmp/Photos"))
        let runner = makeRunner(projectURL: root)
        XCTAssertEqual(try runner.test_validateStageOutput(.sfmMapping, paths: paths, metadata: metadata), .corrupt)
    }

    func testValidateStageOutputRejectsUnboundMsplatTrainingExport() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = ProjectPaths(root: root)
        try paths.ensureDirectories()
        let msplatDirectory = paths.trainingURL.appendingPathComponent("msplat", isDirectory: true)
        try FileManager.default.createDirectory(at: msplatDirectory, withIntermediateDirectories: true)
        let msplatExport = msplatDirectory.appendingPathComponent("splat.ply")
        try TestFileBuilder.writeMinimalPly(at: msplatExport)
        let runStartedAt = Date()
        try FileManager.default.setAttributes(
            [.modificationDate: runStartedAt.addingTimeInterval(5)],
            ofItemAtPath: msplatExport.path
        )

        let metadata = ProjectMetadata(
            title: "Test",
            input: .photos(folder: "/tmp/Photos"),
            requestedRunOptions: RequestedRunOptions(capturePath: .orbit, detailProfile: .fast),
            lastRunStartedAt: runStartedAt
        )
        let runner = makeRunner(projectURL: root)
        XCTAssertEqual(try runner.test_validateStageOutput(.trainSplat, paths: paths, metadata: metadata), .missing)
    }

    func testCompletedTrainingArtifactMustMatchRequestedDetailProfile() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = ProjectPaths(root: root)
        try paths.ensureDirectories()
        var artifact = makeTrainingArtifact(outputPath: "Training/msplat/splat.ply")
        artifact.detailProfile = .highDetail
        artifact.iterationLimit = 15_000
        artifact.plateauWindow = 1_500
        let metadata = ProjectMetadata(
            title: "Wrong detail",
            input: .photos(folder: "/tmp/Photos"),
            requestedRunOptions: RequestedRunOptions(detailProfile: .balanced),
            trainingArtifact: artifact
        )

        XCTAssertEqual(
            try makeRunner(projectURL: root).test_validateStageOutput(
                .trainSplat,
                paths: paths,
                metadata: metadata
            ),
            .corrupt
        )
    }

    func testCheckpointedTrainingArtifactCannotBeMaskedByStalePly() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = ProjectPaths(root: root)
        try paths.ensureDirectories()
        try TestFileBuilder.writeMinimalPly(
            at: paths.trainingURL.appendingPathComponent("stale-output.ply")
        )
        var checkpointed = makeTrainingArtifact(
            checkpointPath: "Training/checkpoints/msplat",
            outputPath: nil,
            completionStatus: .checkpointed
        )
        checkpointed.completedIteration = 500
        let metadata = ProjectMetadata(
            title: "Checkpointed",
            input: .photos(folder: "/tmp/Photos"),
            requestedRunOptions: RequestedRunOptions(capturePath: .orbit, detailProfile: .balanced),
            trainingArtifact: checkpointed
        )

        XCTAssertEqual(
            try makeRunner(projectURL: root).test_validateStageOutput(
                .trainSplat,
                paths: paths,
                metadata: metadata
            ),
            .missing
        )
    }

    func testCompletedTrainingArtifactCannotBeMaskedByUnrelatedPly() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = ProjectPaths(root: root)
        try paths.ensureDirectories()
        try TestFileBuilder.writeMinimalPly(
            at: paths.trainingURL.appendingPathComponent("stale-output.ply")
        )
        let metadata = ProjectMetadata(
            title: "Completed",
            input: .photos(folder: "/tmp/Photos"),
            requestedRunOptions: RequestedRunOptions(detailProfile: .highDetail),
            trainingArtifact: makeTrainingArtifact(
                outputPath: "Training/msplat/splat.ply"
            )
        )

        XCTAssertEqual(
            try makeRunner(projectURL: root).test_validateStageOutput(
                .trainSplat,
                paths: paths,
                metadata: metadata
            ),
            .corrupt
        )
    }

    func testCompletedTrainingArtifactMustMatchCurrentInputAndGeometry() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = ProjectPaths(root: root)
        try paths.ensureDirectories()
        try Data("selected".utf8).write(
            to: paths.framesSelectedURL.appendingPathComponent("frame_000001.jpg")
        )
        let sparse = paths.colmapSparseURL.appendingPathComponent("0", isDirectory: true)
        try FileManager.default.createDirectory(at: sparse, withIntermediateDirectories: true)
        for name in ["cameras.bin", "images.bin", "points3D.bin"] {
            try Data(name.utf8).write(to: sparse.appendingPathComponent(name))
        }
        try FileManager.default.createDirectory(
            at: paths.msplatOutputURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try TestFileBuilder.writeMinimalPly(at: paths.msplatOutputURL)
        let metadata = ProjectMetadata(
            title: "Stale training",
            input: .photos(folder: "/tmp/Photos"),
            requestedRunOptions: RequestedRunOptions(detailProfile: .highDetail),
            trainingArtifact: makeTrainingArtifact(
                outputPath: "Training/msplat/splat.ply"
            )
        )

        XCTAssertEqual(
            try makeRunner(projectURL: root).test_validateStageOutput(
                .trainSplat,
                paths: paths,
                metadata: metadata
            ),
            .corrupt
        )
    }

    func testValidateStageOutputDetectsCorruptDatabase() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = ProjectPaths(root: root)
        try paths.ensureDirectories()
        TestFileBuilder.createFile(at: paths.colmapDatabaseURL, data: Data())

        let metadata = ProjectMetadata(title: "Test", input: .photos(folder: "/tmp/Photos"))
        let runner = makeRunner(projectURL: root)
        let status = try runner.test_validateStageOutput(.sfmFeatures, paths: paths, metadata: metadata)
        XCTAssertEqual(status, .corrupt)
    }

    func testValidateStageOutputRejectsEmptyDatabaseSparseTextWithoutDa3Manifest() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = ProjectPaths(root: root)
        try paths.ensureDirectories()
        FileManager.default.createFile(atPath: paths.colmapDatabaseURL.path, contents: Data())
        let sparse = paths.colmapSparseURL.appendingPathComponent("0", isDirectory: true)
        try FileManager.default.createDirectory(at: sparse, withIntermediateDirectories: true)
        try "1 SIMPLE_PINHOLE 640 480 500 320 240\n"
            .write(to: sparse.appendingPathComponent("cameras.txt"), atomically: true, encoding: .utf8)
        try """
        # images
        1 1 0 0 0 0 0 0 1 frame_000000.jpg
        0 0 1
        """.write(to: sparse.appendingPathComponent("images.txt"), atomically: true, encoding: .utf8)
        try """
        # points
        1 0 0 1 128 128 128 1.0 1 0
        """.write(to: sparse.appendingPathComponent("points3D.txt"), atomically: true, encoding: .utf8)

        let metadata = ProjectMetadata(title: "Test", input: .photos(folder: "/tmp/Photos"))
        let runner = makeRunner(projectURL: root)
        let status = try runner.test_validateStageOutput(.sfmFeatures, paths: paths, metadata: metadata)
        XCTAssertEqual(status, .corrupt)
    }

    func testValidateStageOutputExtractFramesAllowsLowFrameCount() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = ProjectPaths(root: root)
        try paths.ensureDirectories()

        let metadata = ProjectMetadata(
            title: "Test",
            input: .video(files: ["/tmp/video.mp4"]),
            requestedRunOptions: RequestedRunOptions(capturePath: .orbit, detailProfile: .fast)
        )

        let rawDir = paths.framesRawURL.appendingPathComponent("video_000", isDirectory: true)
        try FileManager.default.createDirectory(at: rawDir, withIntermediateDirectories: true)
        XCTAssertTrue(
            try TestFileBuilder.writeGrayscaleImage(
                url: rawDir.appendingPathComponent("frame_000000.jpg"),
                size: 16,
                value: 64,
                utType: .jpeg
            )
        )

        let runner = makeRunner(projectURL: root)
        let status = try runner.test_validateStageOutput(.extractFrames, paths: paths, metadata: metadata)
        XCTAssertEqual(status, .valid)
    }

    func testValidateStageOutputDetectsCorruptPly() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = ProjectPaths(root: root)
        try paths.ensureDirectories()
        TestFileBuilder.createFile(at: paths.outputURL.appendingPathComponent("splat.ply"), data: Data("ply".utf8))

        let metadata = ProjectMetadata(title: "Test", input: .photos(folder: "/tmp/Photos"))
        let runner = makeRunner(projectURL: root)
        let status = try runner.test_validateStageOutput(.exportSplat, paths: paths, metadata: metadata)
        XCTAssertEqual(status, .corrupt)
    }

    func testCleanForRetrySelectFrames() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = ProjectPaths(root: root)
        try paths.ensureDirectories()

        TestFileBuilder.createFile(at: paths.framesSelectedManifestURL, data: Data([0x01]))
        TestFileBuilder.createFile(at: paths.colmapDatabaseURL, data: Data([0x03]))

        let runner = makeRunner(projectURL: root)
        try runner.test_cleanForRetry(failedStage: .selectFrames, paths: paths)

        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.framesSelectedManifestURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.colmapDatabaseURL.path))
    }

    func testCleanForRetryRemovesDanglingDatabaseSymlink() throws {
        let parent = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: parent) }
        let root = parent.appendingPathComponent("Project.easysplatproj", isDirectory: true)
        let paths = ProjectPaths(root: root)
        try paths.ensureDirectories()
        let outside = parent.appendingPathComponent("outside-database.db")
        try FileManager.default.createSymbolicLink(
            at: paths.colmapDatabaseURL,
            withDestinationURL: outside
        )

        try makeRunner(projectURL: root).test_cleanForRetry(
            failedStage: .selectFrames,
            paths: paths
        )

        XCTAssertThrowsError(
            try FileManager.default.destinationOfSymbolicLink(
                atPath: paths.colmapDatabaseURL.path
            )
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: outside.path))
    }

    func testCleanForRetryTrainingPreservesCheckpointAndPublishedOutput() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = ProjectPaths(root: root)
        try paths.ensureDirectories()
        try FileManager.default.createDirectory(
            at: paths.msplatCheckpointURL,
            withIntermediateDirectories: true
        )
        let checkpointSentinel = paths.msplatCheckpointURL.appendingPathComponent("CURRENT")
        try Data("checkpoint\n".utf8).write(to: checkpointSentinel)
        let output = paths.outputURL.appendingPathComponent("splat.ply")
        try TestFileBuilder.writeMinimalPly(at: output)

        try makeRunner(projectURL: root).test_cleanForRetry(
            failedStage: .trainSplat,
            paths: paths
        )

        XCTAssertTrue(FileManager.default.fileExists(atPath: checkpointSentinel.path))
        XCTAssertEqual(ProjectArtifactValidator.validatePlyFile(at: output), .valid)
    }

    func testCleanForRetryUpstreamInvalidatesTrainingButPreservesPublishedOutput() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = ProjectPaths(root: root)
        try paths.ensureDirectories()
        let trainingSentinel = paths.trainingURL.appendingPathComponent("stale.txt")
        try Data("stale".utf8).write(to: trainingSentinel)
        let output = paths.outputURL.appendingPathComponent("splat.ply")
        try TestFileBuilder.writeMinimalPly(at: output)

        try makeRunner(projectURL: root).test_cleanForRetry(
            failedStage: .sfmMapping,
            paths: paths
        )

        XCTAssertFalse(FileManager.default.fileExists(atPath: trainingSentinel.path))
        XCTAssertEqual(ProjectArtifactValidator.validatePlyFile(at: output), .valid)
    }

    private func makeRunner(projectURL: URL) -> PipelineRunner {
        let toolchain = TestToolchains.toolchainPaths(root: projectURL)
        let config = PipelineRunner.PipelineConfig(toolchain: toolchain)
        return PipelineRunner(projectURL: projectURL, config: config)
    }

}
