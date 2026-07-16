import XCTest
import UniformTypeIdentifiers
import SQLite3
@testable import EasySplatCore

final class PipelineRunnerRetryTests: XCTestCase {
    func testTargetedExactEscalatesOnlyRecoverableGeometryFailures() {
        XCTAssertTrue(PipelineRunner.shouldEscalateTargetedExact(
            after: PipelineRunner.PipelineError.outputMissing
        ))
        XCTAssertTrue(PipelineRunner.shouldEscalateTargetedExact(
            after: PipelineRunner.PipelineError.geometryResidualCoverageTooLow(
                measured: 12,
                total: 60
            )
        ))
        XCTAssertTrue(PipelineRunner.shouldEscalateTargetedExact(
            after: PipelineRunner.PipelineError.geometryResidualsTooHigh(
                median: 2,
                p90: 4
            )
        ))
        XCTAssertFalse(PipelineRunner.shouldEscalateTargetedExact(
            after: PipelineRunner.PipelineError.geometryProvenanceUnavailable("missing")
        ))
        XCTAssertFalse(PipelineRunner.shouldEscalateTargetedExact(
            after: ColmapRunnerError.failed(
                command: "mapper",
                exitCode: 1,
                terminationReason: .exit,
                stdoutTail: "",
                stderrTail: "fatal"
            )
        ))
    }

    func testFragmentedMappingUsesOnlyThePairGraphRecoveryPath() {
        let fragmentation = PipelineRunner.PipelineError.fragmentedReconstruction(
            MappingFragmentationEvidence(
                selectedModelOrder: 0,
                selectedRegisteredViewCount: 226,
                credibleUnionRegisteredViewCount: 249,
                omittedRecoverableViewCount: 23,
                totalSelectedViewCount: 250
            )
        )

        XCTAssertTrue(PipelineRunner.shouldRecoverPairGraph(after: fragmentation))
        XCTAssertTrue(PipelineRunner.shouldEscalateTargetedExact(after: fragmentation))
        XCTAssertTrue(PipelineRunner.shouldRecoverPairGraph(
            after: PipelineRunner.PipelineError.lowQualityReconstruction(
                ReconstructionScore(
                    registeredImages: 80,
                    totalImages: 100,
                    meanReprojectionError: 1
                ),
                mapper: "colmap"
            )
        ))
        XCTAssertFalse(PipelineRunner.shouldRecoverPairGraph(
            after: PipelineRunner.PipelineError.geometryResidualsTooHigh(
                median: 2,
                p90: 4
            )
        ))
    }

    func testConservativeCadenceRetriesOnlyMeasuredGeometryRejections() {
        let lowQuality = PipelineRunner.PipelineError.lowQualityReconstruction(
            ReconstructionScore(
                registeredImages: 80,
                totalImages: 100,
                meanReprojectionError: 1
            ),
            mapper: "colmap"
        )
        let fragmentation = PipelineRunner.PipelineError.fragmentedReconstruction(
            MappingFragmentationEvidence(
                selectedModelOrder: 0,
                selectedRegisteredViewCount: 80,
                credibleUnionRegisteredViewCount: 95,
                omittedRecoverableViewCount: 15,
                totalSelectedViewCount: 100
            )
        )

        XCTAssertNotNil(PipelineRunner.conservativeCadenceFallbackReason(after: lowQuality))
        XCTAssertNotNil(PipelineRunner.conservativeCadenceFallbackReason(after: fragmentation))
        XCTAssertNotNil(PipelineRunner.conservativeCadenceFallbackReason(
            after: PipelineRunner.PipelineError.geometryCoverageTooLow(
                registered: 80,
                total: 100
            )
        ))
        XCTAssertNotNil(PipelineRunner.conservativeCadenceFallbackReason(
            after: PipelineRunner.PipelineError.geometryResidualCoverageTooLow(
                measured: 80,
                total: 100
            )
        ))
        XCTAssertNotNil(PipelineRunner.conservativeCadenceFallbackReason(
            after: PipelineRunner.PipelineError.geometryResidualsTooHigh(
                median: 2,
                p90: 4
            )
        ))

        XCTAssertNil(PipelineRunner.conservativeCadenceFallbackReason(
            after: CancellationError()
        ))
        XCTAssertNil(PipelineRunner.conservativeCadenceFallbackReason(
            after: PipelineRunner.PipelineError.invalidInput
        ))
        XCTAssertNil(PipelineRunner.conservativeCadenceFallbackReason(
            after: PipelineRunner.PipelineError.geometryRegisteredImagesMismatch
        ))
        XCTAssertNil(PipelineRunner.conservativeCadenceFallbackReason(
            after: PipelineRunner.PipelineError.geometryResidualsUnavailable("parse failed")
        ))
        XCTAssertNil(PipelineRunner.conservativeCadenceFallbackReason(
            after: PipelineRunner.PipelineError.geometryProvenanceUnavailable("missing")
        ))
        XCTAssertNil(PipelineRunner.conservativeCadenceFallbackReason(
            after: PipelineRunner.PipelineError.outputMissing
        ))
        XCTAssertNil(PipelineRunner.conservativeCadenceFallbackReason(
            after: ColmapRunnerError.failed(
                command: "mapper",
                exitCode: 1,
                terminationReason: .exit,
                stdoutTail: "",
                stderrTail: "fatal"
            )
        ))
    }

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
        XCTAssertTrue(try TestFileBuilder.writeGrayscaleImage(
            url: file,
            size: 16,
            value: 64,
            utType: .jpeg
        ))
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

    func testClassicalMatchingResumeRequiresExactDurableEvidence() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try writeMatchingResumeFixture(at: root, route: .colmap)

        XCTAssertEqual(
            try makeRunner(projectURL: root).test_validateStageOutput(
                .sfmMatching,
                paths: fixture.paths,
                metadata: fixture.metadata
            ),
            .valid
        )
    }

    func testClassicalMatchingResumeTreatsMissingEvidenceAsIncomplete() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try writeMatchingResumeFixture(at: root, route: .colmap)
        try FileManager.default.removeItem(at: fixture.paths.pairGraphEvidenceURL)

        XCTAssertEqual(
            try makeRunner(projectURL: root).test_validateStageOutput(
                .sfmMatching,
                paths: fixture.paths,
                metadata: fixture.metadata
            ),
            .missing
        )
    }

    func testClassicalMatchingResumeTreatsMissingSelectedManifestAsIncomplete() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try writeMatchingResumeFixture(at: root, route: .colmap)
        try FileManager.default.removeItem(at: fixture.paths.framesSelectedManifestURL)

        XCTAssertEqual(
            try makeRunner(projectURL: root).test_validateStageOutput(
                .sfmMatching,
                paths: fixture.paths,
                metadata: fixture.metadata
            ),
            .missing
        )
    }

    func testClassicalMatchingResumeRejectsChangedSelectedFrame() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try writeMatchingResumeFixture(at: root, route: .colmap)
        try Data("changed".utf8).write(
            to: fixture.paths.framesSelectedURL.appendingPathComponent("b.jpg")
        )

        XCTAssertEqual(
            try makeRunner(projectURL: root).test_validateStageOutput(
                .sfmMatching,
                paths: fixture.paths,
                metadata: fixture.metadata
            ),
            .corrupt
        )
    }

    func testClassicalFeatureResumeRejectsChangedSelectedFrameBytes() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try writeMatchingResumeFixture(at: root, route: .colmap)

        XCTAssertEqual(
            try makeRunner(projectURL: root).test_validateStageOutput(
                .sfmFeatures,
                paths: fixture.paths,
                metadata: fixture.metadata
            ),
            .valid
        )
        try Data("changed".utf8).write(
            to: fixture.paths.framesSelectedURL.appendingPathComponent("b.jpg")
        )
        XCTAssertEqual(
            try makeRunner(projectURL: root).test_validateStageOutput(
                .sfmFeatures,
                paths: fixture.paths,
                metadata: fixture.metadata
            ),
            .corrupt
        )
    }

    func testClassicalMatchingResumeRejectsChangedVerifiedPairs() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try writeMatchingResumeFixture(at: root, route: .colmap)
        var database: OpaquePointer?
        XCTAssertEqual(sqlite3_open(fixture.paths.colmapDatabaseURL.path, &database), SQLITE_OK)
        if let database {
            XCTAssertEqual(
                sqlite3_exec(
                    database,
                    "DELETE FROM two_view_geometries WHERE pair_id = 4294967297;",
                    nil,
                    nil,
                    nil
                ),
                SQLITE_OK
            )
            sqlite3_close(database)
        }

        XCTAssertEqual(
            try makeRunner(projectURL: root).test_validateStageOutput(
                .sfmMatching,
                paths: fixture.paths,
                metadata: fixture.metadata
            ),
            .corrupt
        )
    }

    func testClassicalMatchingResumeRejectsChangedCorrespondencePayload() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try writeMatchingResumeFixture(at: root, route: .colmap)
        var database: OpaquePointer?
        XCTAssertEqual(sqlite3_open(fixture.paths.colmapDatabaseURL.path, &database), SQLITE_OK)
        if let database {
            XCTAssertEqual(
                sqlite3_exec(
                    database,
                    "UPDATE two_view_geometries SET data = X'09', config = 7 WHERE pair_id = 2147483649;",
                    nil,
                    nil,
                    nil
                ),
                SQLITE_OK
            )
            sqlite3_close(database)
        }

        XCTAssertEqual(
            try makeRunner(projectURL: root).test_validateStageOutput(
                .sfmMatching,
                paths: fixture.paths,
                metadata: fixture.metadata
            ),
            .corrupt
        )
    }

    func testDa3MatchingResumeTemporarilyAllowsGenericMatchedDatabase() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try writeMatchingResumeFixture(at: root, route: .da3)
        try FileManager.default.removeItem(at: fixture.paths.pairGraphEvidenceURL)

        XCTAssertEqual(
            try makeRunner(projectURL: root).test_validateStageOutput(
                .sfmMatching,
                paths: fixture.paths,
                metadata: fixture.metadata
            ),
            .valid
        )
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

    func testValidateStageOutputExtractFramesRequiresCommittedManifest() throws {
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
        XCTAssertEqual(
            try runner.test_validateStageOutput(.extractFrames, paths: paths, metadata: metadata),
            .missing
        )

        _ = try ExtractedFrameManifestStore.persist(
            groups: [[rawDir.appendingPathComponent("frame_000000.jpg")]],
            targetCounts: [1],
            paths: paths
        )
        XCTAssertEqual(
            try runner.test_validateStageOutput(.extractFrames, paths: paths, metadata: metadata),
            .valid
        )

    }

    func testValidateStageOutputTreatsSelectedFramesAsDurableSuccessorToRawFrames() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = ProjectPaths(root: root)
        try paths.ensureDirectories()

        let selected = paths.framesSelectedURL.appendingPathComponent("frame_000000.jpg")
        XCTAssertTrue(try TestFileBuilder.writeGrayscaleImage(
            url: selected,
            size: 16,
            value: 64,
            utType: .jpeg
        ))
        try JSONEncoder().encode([
            PipelineRunner.SelectedFrameMapping(
                outputFileName: selected.lastPathComponent,
                groupId: "video_000",
                isVideo: true,
                timestampSeconds: 0,
                lowLightExposureEV: nil
            )
        ]).write(to: paths.framesSelectedManifestURL, options: [.atomic])

        var metadata = ProjectMetadata(
            title: "Test",
            input: .video(files: ["/tmp/video.mp4"]),
            requestedRunOptions: RequestedRunOptions(capturePath: .orbit, detailProfile: .fast)
        )
        metadata.state = PipelineState(stage: .sfmFeatures, lastError: nil)

        let runner = makeRunner(projectURL: root)
        XCTAssertEqual(
            try runner.test_validateStageOutput(.extractFrames, paths: paths, metadata: metadata),
            .valid
        )

        TestFileBuilder.createFile(
            at: paths.framesRawURL.appendingPathComponent("stale.jpg"),
            data: Data("stale".utf8)
        )
        TestFileBuilder.createFile(
            at: paths.framesRawManifestURL,
            data: Data("stale".utf8)
        )
        try runner.test_cleanupRawFramesAfterDurableSelection(
            paths: paths,
            metadata: metadata
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.framesRawURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.framesRawManifestURL.path))
    }

    func testRawCleanupFailurePreservesManifestForRetry() throws {
        let root = try TestFileBuilder.makeTempDir()
        let paths = ProjectPaths(root: root)
        try paths.ensureDirectories()
        let rawFrame = paths.framesRawURL.appendingPathComponent("keep.jpg")
        defer {
            _ = chflags(rawFrame.path, 0)
            try? FileManager.default.removeItem(at: root)
        }

        let selected = paths.framesSelectedURL.appendingPathComponent("frame_000000.jpg")
        XCTAssertTrue(try TestFileBuilder.writeGrayscaleImage(
            url: selected,
            size: 16,
            value: 64,
            utType: .jpeg
        ))
        try JSONEncoder().encode([
            PipelineRunner.SelectedFrameMapping(
                outputFileName: selected.lastPathComponent,
                groupId: "video_000",
                isVideo: true,
                timestampSeconds: 0
            )
        ]).write(to: paths.framesSelectedManifestURL, options: [.atomic])
        TestFileBuilder.createFile(at: rawFrame, data: Data("raw".utf8))
        TestFileBuilder.createFile(
            at: paths.framesRawManifestURL,
            data: Data("raw manifest".utf8)
        )
        XCTAssertEqual(chflags(rawFrame.path, UInt32(UF_IMMUTABLE)), 0)
        var metadata = ProjectMetadata(
            title: "Test",
            input: .video(files: ["/tmp/video.mp4"])
        )
        metadata.state = PipelineState(stage: .sfmFeatures, lastError: nil)
        let runner = makeRunner(projectURL: root)

        XCTAssertThrowsError(try runner.test_cleanupRawFramesAfterDurableSelection(
            paths: paths,
            metadata: metadata
        ))
        XCTAssertTrue(FileManager.default.fileExists(atPath: paths.framesRawURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: paths.framesRawManifestURL.path))
    }

    func testValidateStageOutputRejectsSelectedFrameLinks() throws {
        for hardLink in [false, true] {
            let root = try TestFileBuilder.makeTempDir()
            defer { try? FileManager.default.removeItem(at: root) }
            let paths = ProjectPaths(root: root)
            try paths.ensureDirectories()
            let outside = root.appendingPathComponent("outside.jpg")
            XCTAssertTrue(try TestFileBuilder.writeGrayscaleImage(
                url: outside,
                size: 16,
                value: 64,
                utType: .jpeg
            ))
            let selected = paths.framesSelectedURL.appendingPathComponent("frame_000000.jpg")
            if hardLink {
                try FileManager.default.linkItem(at: outside, to: selected)
            } else {
                try FileManager.default.createSymbolicLink(at: selected, withDestinationURL: outside)
            }
            try JSONEncoder().encode([
                PipelineRunner.SelectedFrameMapping(
                    outputFileName: selected.lastPathComponent,
                    groupId: "video_000",
                    isVideo: true,
                    timestampSeconds: 0,
                    lowLightExposureEV: nil
                )
            ]).write(to: paths.framesSelectedManifestURL, options: [.atomic])

            let metadata = ProjectMetadata(
                title: "Test",
                input: .video(files: ["/tmp/video.mp4"])
            )
            XCTAssertEqual(
                try makeRunner(projectURL: root).test_validateStageOutput(
                    .selectFrames,
                    paths: paths,
                    metadata: metadata
                ),
                .corrupt
            )
        }
    }

    func testInvalidSelectedSuccessorDoesNotDeleteRawFrames() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = ProjectPaths(root: root)
        try paths.ensureDirectories()
        let selected = (0..<2).map { index in
            paths.framesSelectedURL.appendingPathComponent(
                String(format: "frame_%06d.jpg", index)
            )
        }
        for (index, file) in selected.enumerated() {
            XCTAssertTrue(try TestFileBuilder.writeGrayscaleImage(
                url: file,
                size: 16,
                value: UInt8(64 + index),
                utType: .jpeg
            ))
        }
        try JSONEncoder().encode([
            PipelineRunner.SelectedFrameMapping(
                outputFileName: selected[0].lastPathComponent,
                groupId: "",
                isVideo: true,
                timestampSeconds: 0
            ),
            PipelineRunner.SelectedFrameMapping(
                outputFileName: selected[0].lastPathComponent,
                groupId: "",
                isVideo: true,
                timestampSeconds: 1
            ),
        ]).write(to: paths.framesSelectedManifestURL, options: [.atomic])
        TestFileBuilder.createFile(
            at: paths.framesRawURL.appendingPathComponent("keep.jpg"),
            data: Data("raw".utf8)
        )
        TestFileBuilder.createFile(
            at: paths.framesRawManifestURL,
            data: Data("raw manifest".utf8)
        )
        var metadata = ProjectMetadata(
            title: "Test",
            input: .video(files: ["/tmp/video.mp4"])
        )
        metadata.state = PipelineState(stage: .sfmFeatures, lastError: nil)
        let runner = makeRunner(projectURL: root)

        XCTAssertEqual(
            try runner.test_validateStageOutput(
                .selectFrames,
                paths: paths,
                metadata: metadata
            ),
            .corrupt
        )
        try runner.test_cleanupRawFramesAfterDurableSelection(
            paths: paths,
            metadata: metadata
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: paths.framesRawURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: paths.framesRawManifestURL.path))
    }

    func testUnreadableSelectedSuccessorDoesNotDeleteRawFrames() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = ProjectPaths(root: root)
        try paths.ensureDirectories()
        let selected = (0..<2).map { index in
            paths.framesSelectedURL.appendingPathComponent(
                String(format: "frame_%06d.jpg", index)
            )
        }
        for file in selected {
            TestFileBuilder.createFile(
                at: file,
                data: Data("regular file, not an image".utf8)
            )
        }
        try JSONEncoder().encode(selected.enumerated().map { index, file in
            PipelineRunner.SelectedFrameMapping(
                outputFileName: file.lastPathComponent,
                groupId: "video_000",
                isVideo: true,
                timestampSeconds: Double(index)
            )
        }).write(to: paths.framesSelectedManifestURL, options: [.atomic])
        TestFileBuilder.createFile(
            at: paths.framesRawURL.appendingPathComponent("keep.jpg"),
            data: Data("raw".utf8)
        )
        TestFileBuilder.createFile(
            at: paths.framesRawManifestURL,
            data: Data("raw manifest".utf8)
        )
        var metadata = ProjectMetadata(
            title: "Test",
            input: .video(files: ["/tmp/video.mp4"])
        )
        metadata.state = PipelineState(stage: .sfmFeatures, lastError: nil)
        let runner = makeRunner(projectURL: root)

        XCTAssertEqual(
            try runner.test_validateStageOutput(
                .selectFrames,
                paths: paths,
                metadata: metadata
            ),
            .corrupt
        )
        try runner.test_cleanupRawFramesAfterDurableSelection(
            paths: paths,
            metadata: metadata
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: paths.framesRawURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: paths.framesRawManifestURL.path))
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
        TestFileBuilder.createFile(at: paths.pairGraphEvidenceURL, data: Data([0x04]))
        TestFileBuilder.createFile(at: paths.pairGraphRecoveryURL, data: Data([0x05]))

        let runner = makeRunner(projectURL: root)
        try runner.test_cleanForRetry(failedStage: .selectFrames, paths: paths)

        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.framesSelectedManifestURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.colmapDatabaseURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.pairGraphEvidenceURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.pairGraphRecoveryURL.path))
    }

    func testCleanForRetryStopsWhenAnInvalidatedArtifactCannotBeRemoved() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = ProjectPaths(root: root)
        try paths.ensureDirectories()
        let selectedSentinel = paths.framesSelectedURL.appendingPathComponent("stale.jpg")
        try Data("stale".utf8).write(to: selectedSentinel)
        try FileManager.default.setAttributes(
            [.immutable: true],
            ofItemAtPath: selectedSentinel.path
        )
        defer {
            try? FileManager.default.setAttributes(
                [.immutable: false],
                ofItemAtPath: selectedSentinel.path
            )
        }

        XCTAssertThrowsError(
            try makeRunner(projectURL: root).test_cleanForRetry(
                failedStage: .selectFrames,
                paths: paths
            )
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: selectedSentinel.path))
    }

    func testCleanForRetryExtractFramesRemovesRawManifest() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = ProjectPaths(root: root)
        try paths.ensureDirectories()
        TestFileBuilder.createFile(at: paths.framesRawManifestURL, data: Data("{}".utf8))
        TestFileBuilder.createFile(at: paths.pairGraphRecoveryURL, data: Data("{}".utf8))

        try makeRunner(projectURL: root).test_cleanForRetry(
            failedStage: .extractFrames,
            paths: paths
        )

        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.framesRawManifestURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.pairGraphRecoveryURL.path))
    }

    func testCleanForRetryFeaturesRemovesRecoveryState() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = ProjectPaths(root: root)
        try paths.ensureDirectories()
        TestFileBuilder.createFile(at: paths.pairGraphRecoveryURL, data: Data("{}".utf8))

        try makeRunner(projectURL: root).test_cleanForRetry(
            failedStage: .sfmFeatures,
            paths: paths
        )

        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.pairGraphRecoveryURL.path))
    }

    func testCleanForRetryImportInvalidatesAcceptedGeometryButPreservesPublishedOutput() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = ProjectPaths(root: root)
        try paths.ensureDirectories()
        let sparseSentinel = paths.colmapSparseURL.appendingPathComponent("0/stale.txt")
        try FileManager.default.createDirectory(
            at: sparseSentinel.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("stale".utf8).write(to: sparseSentinel)
        try Data("stale".utf8).write(to: paths.geometryManifestURL)
        let trainingSentinel = paths.trainingURL.appendingPathComponent("stale.txt")
        try Data("stale".utf8).write(to: trainingSentinel)
        let output = paths.outputURL.appendingPathComponent("splat.ply")
        try TestFileBuilder.writeMinimalPly(at: output)

        try makeRunner(projectURL: root).test_cleanForRetry(
            failedStage: .importInput,
            paths: paths
        )

        XCTAssertFalse(FileManager.default.fileExists(atPath: sparseSentinel.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.geometryManifestURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: trainingSentinel.path))
        XCTAssertEqual(ProjectArtifactValidator.validatePlyFile(at: output), .valid)
    }

    func testCleanForMatchingRetryPreservesFeaturesAndLearnedSeed() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = ProjectPaths(root: root)
        try paths.ensureDirectories()
        try writeMatchedDatabase(at: paths.colmapDatabaseURL)
        try Data("stale".utf8).write(to: paths.pairGraphEvidenceURL)
        try Data("stale".utf8).write(to: paths.pairGraphRecoveryURL)
        try Data("stale".utf8).write(
            to: paths.colmapSeedURL.appendingPathComponent("stale.txt")
        )

        try makeRunner(projectURL: root).test_cleanForRetry(
            failedStage: .sfmMatching,
            paths: paths
        )

        XCTAssertTrue(FileManager.default.fileExists(atPath: paths.colmapDatabaseURL.path))
        XCTAssertEqual(try databaseRowCount("matches", at: paths.colmapDatabaseURL), 0)
        XCTAssertEqual(
            try databaseRowCount("two_view_geometries", at: paths.colmapDatabaseURL),
            0
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.pairGraphEvidenceURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.pairGraphRecoveryURL.path))
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: paths.colmapSeedURL.appendingPathComponent("stale.txt").path
            )
        )
    }

    func testCleanForMappingRetryRemovesPendingIntentButPreservesVerifiedGraph() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = ProjectPaths(root: root)
        try paths.ensureDirectories()
        try Data("verified".utf8).write(to: paths.pairGraphEvidenceURL)
        try Data("pending".utf8).write(to: paths.pairGraphRecoveryURL)

        try makeRunner(projectURL: root).test_cleanForRetry(
            failedStage: .sfmMapping,
            paths: paths
        )

        XCTAssertTrue(FileManager.default.fileExists(atPath: paths.pairGraphEvidenceURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.pairGraphRecoveryURL.path))
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
        let learnedInitializer = paths.colmapSeedModelURL.appendingPathComponent(
            "learned_points3D.txt"
        )
        try FileManager.default.createDirectory(
            at: learnedInitializer.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("stale".utf8).write(to: learnedInitializer)
        try Data("stale".utf8).write(to: paths.geometryManifestURL)
        let output = paths.outputURL.appendingPathComponent("splat.ply")
        try TestFileBuilder.writeMinimalPly(at: output)

        try makeRunner(projectURL: root).test_cleanForRetry(
            failedStage: .sfmMapping,
            paths: paths
        )

        XCTAssertFalse(FileManager.default.fileExists(atPath: trainingSentinel.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: learnedInitializer.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.geometryManifestURL.path))
        XCTAssertEqual(ProjectArtifactValidator.validatePlyFile(at: output), .valid)
    }

    func testGeometryRerunInvalidatesAcceptedMetadataAndPreservesPublishedOutput() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = ProjectPaths(root: root)
        try paths.ensureDirectories()
        var metadata = ProjectMetadata(
            title: "Geometry rerun",
            input: .photos(folder: "/tmp/Photos"),
            geometryArtifact: makeGeometryArtifact(
                sourceModelPath: "SfM/colmap/sparse/0"
            ),
            trainingArtifact: makeTrainingArtifact(),
            checkpoint: PipelineCheckpoint(stage: .sfmMapping),
            reconstruction: ReconstructionSummary(
                mapper: "colmap",
                capturedAt: Date(timeIntervalSince1970: 1),
                registeredImages: 2,
                totalImages: 2
            ),
            stageTimings: [
                StageTimingRecord(
                    stage: .sfmMatching,
                    startedAt: Date(timeIntervalSince1970: 1),
                    durationSeconds: 1
                ),
                StageTimingRecord(
                    stage: .sfmMapping,
                    startedAt: Date(timeIntervalSince1970: 2),
                    durationSeconds: 2
                ),
                StageTimingRecord(
                    stage: .trainSplat,
                    startedAt: Date(timeIntervalSince1970: 3),
                    durationSeconds: 3
                ),
            ]
        )
        try Data("stale".utf8).write(to: paths.geometryManifestURL)
        let sparseSentinel = paths.colmapSparseURL.appendingPathComponent("0/stale.txt")
        try FileManager.default.createDirectory(
            at: sparseSentinel.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("stale".utf8).write(to: sparseSentinel)
        let refinementSentinel = paths.colmapRefinementSeedModelURL
            .appendingPathComponent("stale.txt")
        try FileManager.default.createDirectory(
            at: refinementSentinel.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("stale".utf8).write(to: refinementSentinel)
        let trainingSentinel = paths.trainingURL.appendingPathComponent("stale.txt")
        try Data("stale".utf8).write(to: trainingSentinel)
        let output = paths.outputURL.appendingPathComponent("splat.ply")
        try TestFileBuilder.writeMinimalPly(at: output)

        try makeRunner(projectURL: root).test_invalidateAcceptedArtifactsForGeometryRerun(
            startingAt: .sfmMapping,
            metadata: &metadata,
            paths: paths
        )

        XCTAssertNil(metadata.reconstruction)
        XCTAssertNil(metadata.geometryArtifact)
        XCTAssertNil(metadata.trainingArtifact)
        XCTAssertNil(metadata.checkpoint)
        XCTAssertEqual(metadata.stageTimings?.map(\.stage), [.sfmMatching])
        XCTAssertFalse(FileManager.default.fileExists(atPath: sparseSentinel.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: refinementSentinel.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.geometryManifestURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: trainingSentinel.path))
        XCTAssertEqual(ProjectArtifactValidator.validatePlyFile(at: output), .valid)
        let persisted = try ProjectMetadataStore.load(from: paths.metadataURL)
        XCTAssertNil(persisted.reconstruction)
        XCTAssertNil(persisted.geometryArtifact)
        XCTAssertNil(persisted.trainingArtifact)
        XCTAssertNil(persisted.checkpoint)
        XCTAssertEqual(persisted.stageTimings?.map(\.stage), [.sfmMatching])
    }

    func testResolvedPlanChangePersistsDurableFeaturesBoundaryBeforeRelaunch() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = ProjectPaths(root: root)
        try paths.ensureDirectories()

        let options = RequestedRunOptions(inputOrdering: .unordered)
        let hardware = HardwareProfile(memoryGB: 48, cpuCount: 16, gpuWorkingSetGB: 36)
        var previousPlan = RunPlanResolver.resolve(
            requestedOptions: options,
            input: .photos(folder: "/tmp/Photos"),
            hardware: hardware,
            developmentOverrides: .none
        )
        previousPlan.baGlobalFramesRatio = 1.2
        let currentPlan = RunPlanResolver.resolve(
            requestedOptions: options,
            input: .photos(folder: "/tmp/Photos"),
            hardware: hardware,
            developmentOverrides: .none
        )
        var metadata = ProjectMetadata(
            title: "Durable plan change",
            input: .photos(folder: "/tmp/Photos"),
            resolvedRunPlan: previousPlan,
            state: PipelineState(stage: .sfmMapping, lastError: nil),
            checkpoint: PipelineCheckpoint(stage: .sfmMapping),
            lastRunStartedAt: Date()
        )
        try ProjectMetadataStore.save(metadata, to: paths.metadataURL)
        try writeMatchedDatabase(at: paths.colmapDatabaseURL)

        let sparseSentinel = paths.colmapSparseURL.appendingPathComponent("stale.txt")
        let trainingSentinel = paths.trainingURL.appendingPathComponent("stale.txt")
        try Data("stale".utf8).write(to: sparseSentinel)
        try Data("stale".utf8).write(to: trainingSentinel)
        try Data("stale".utf8).write(to: paths.geometryManifestURL)
        try Data("stale".utf8).write(to: paths.pairGraphEvidenceURL)
        try Data("stale".utf8).write(to: paths.pairGraphRecoveryURL)
        let publishedOutput = paths.outputURL.appendingPathComponent("splat.ply")
        try TestFileBuilder.writeMinimalPly(at: publishedOutput)

        try makeRunner(projectURL: root).test_persistResolvedPlanChange(
            currentPlan,
            completedBoundary: .sfmFeatures,
            metadata: &metadata,
            paths: paths
        )

        let persisted = try ProjectMetadataStore.load(from: paths.metadataURL)
        XCTAssertEqual(persisted.resolvedRunPlan, currentPlan)
        XCTAssertEqual(persisted.state.stage, .sfmFeatures)
        XCTAssertNil(persisted.state.lastError)
        XCTAssertNil(persisted.checkpoint)
        XCTAssertNil(persisted.lastRunStartedAt)
        XCTAssertNil(persisted.geometryArtifact)
        XCTAssertNil(persisted.trainingArtifact)
        XCTAssertEqual(try databaseRowCount("matches", at: paths.colmapDatabaseURL), 0)
        XCTAssertEqual(try databaseRowCount("two_view_geometries", at: paths.colmapDatabaseURL), 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: sparseSentinel.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.geometryManifestURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.pairGraphEvidenceURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.pairGraphRecoveryURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: trainingSentinel.path))
        XCTAssertEqual(ProjectArtifactValidator.validatePlyFile(at: publishedOutput), .valid)
    }

    private func writeMatchingResumeFixture(
        at root: URL,
        route: SfmBackend
    ) throws -> (paths: ProjectPaths, metadata: ProjectMetadata) {
        let paths = ProjectPaths(root: root)
        try paths.ensureDirectories()
        let imageNames = ["a.jpg", "b.jpg", "c.jpg"]
        for (index, imageName) in imageNames.enumerated() {
            try Data("frame-\(index)".utf8).write(
                to: paths.framesSelectedURL.appendingPathComponent(imageName)
            )
        }
        let manifest = imageNames.map {
            TestSelectedFrameMapping(
                outputFileName: $0,
                groupId: "photos",
                isVideo: false
            )
        }
        try JSONEncoder().encode(manifest).write(
            to: paths.framesSelectedManifestURL,
            options: .atomic
        )

        var database: OpaquePointer?
        guard sqlite3_open(paths.colmapDatabaseURL.path, &database) == SQLITE_OK,
              let database else {
            throw NSError(domain: "PipelineRunnerRetryTests", code: 1)
        }
        let firstPairID = ColmapPairGraphInspector.pairIDDivisor + 2
        let secondPairID = 2 * ColmapPairGraphInspector.pairIDDivisor + 3
        let sql = """
        CREATE TABLE cameras(camera_id INTEGER PRIMARY KEY);
        CREATE TABLE images(image_id INTEGER PRIMARY KEY, name TEXT NOT NULL UNIQUE, camera_id INTEGER NOT NULL);
        CREATE TABLE keypoints(image_id INTEGER PRIMARY KEY, rows INTEGER NOT NULL, cols INTEGER NOT NULL, data BLOB);
        CREATE TABLE descriptors(image_id INTEGER PRIMARY KEY, rows INTEGER NOT NULL, cols INTEGER NOT NULL, data BLOB);
        CREATE TABLE matches(pair_id INTEGER PRIMARY KEY, rows INTEGER NOT NULL, cols INTEGER NOT NULL, data BLOB);
        CREATE TABLE two_view_geometries(pair_id INTEGER PRIMARY KEY, rows INTEGER NOT NULL, cols INTEGER NOT NULL, data BLOB, config INTEGER NOT NULL);
        INSERT INTO cameras(camera_id) VALUES (1);
        INSERT INTO images(image_id, name, camera_id) VALUES (1, 'a.jpg', 1), (2, 'b.jpg', 1), (3, 'c.jpg', 1);
        INSERT INTO keypoints(image_id, rows, cols, data) VALUES (1, 64, 4, X'01'), (2, 64, 4, X'02'), (3, 64, 4, X'03');
        INSERT INTO descriptors(image_id, rows, cols, data) VALUES (1, 64, 128, X'01'), (2, 64, 128, X'02'), (3, 64, 128, X'03');
        INSERT INTO matches(pair_id, rows, cols, data) VALUES (\(firstPairID), 24, 2, X'01'), (\(secondPairID), 24, 2, X'02');
        INSERT INTO two_view_geometries(pair_id, rows, cols, data, config) VALUES (\(firstPairID), 18, 2, X'01', 2), (\(secondPairID), 18, 2, X'02', 2);
        """
        let sqliteResult = sqlite3_exec(database, sql, nil, nil, nil)
        sqlite3_close(database)
        guard sqliteResult == SQLITE_OK else {
            throw NSError(domain: "PipelineRunnerRetryTests", code: 2)
        }

        let featureEvidence = ColmapFeatureEvidence(
            selectedFramesDigest: try GeometryArtifactStore.selectedFramesDigest(
                orderedImageNames: imageNames,
                projectPaths: paths
            ),
            imageNames: imageNames,
            featureDatabaseDigest: try ColmapDatabaseDigester
                .digests(at: paths.colmapDatabaseURL).feature
        )
        try ColmapFeatureEvidenceStore.save(
            featureEvidence,
            to: paths.colmapFeatureEvidenceURL,
            projectPaths: paths
        )

        let plan = try ColmapPairPlan.temporal(
            groups: [ColmapPairGroup(imageNames: imageNames, isVideo: true)],
            offsets: [1]
        )
        let inspection = try ColmapPairGraphInspector(
            databaseURL: paths.colmapDatabaseURL
        ).inspect(
            schedule: ColmapPairSchedule(imageNames: imageNames, pairs: plan.pairs),
            completion: .succeeded
        )
        let attempt = PairGraphAttemptEvidence(
            artifact: PairMatchingAttemptArtifact(
                attemptNumber: 1,
                matcher: .faiss,
                recoveryLevel: .normal,
                outcome: .completed,
                scheduledPairCount: inspection.scheduledPairCount,
                attemptedPairCount: inspection.attemptedPairCount,
                rawMatchedPairCount: inspection.rawMatchedPairCount,
                spatiallyVerifiedPairCount: inspection.spatiallyVerifiedPairCount,
                durationSeconds: 0.01
            ),
            scheduledPairs: plan.pairs
        )
        let evidence = PairGraphEvidence(
            selectedFramesDigest: try GeometryArtifactStore.selectedFramesDigest(
                orderedImageNames: imageNames,
                projectPaths: paths
            ),
            imageNames: imageNames,
            attempts: [attempt],
            acceptedAttemptNumber: 1,
            acceptedInspection: inspection,
            matchingDurationSeconds: 0.01,
            fallbackReasons: []
        )
        try PairGraphEvidenceStore.save(
            evidence,
            to: paths.pairGraphEvidenceURL,
            projectPaths: paths
        )

        let input = InputSpec.photos(folder: "/tmp/Photos")
        let options = RequestedRunOptions(
            detailProfile: .fast,
            inputOrdering: .unordered,
            photoSelection: .useAllValidPhotos
        )
        let planForRoute = RunPlanResolver.resolve(
            requestedOptions: options,
            input: input,
            hardware: HardwareProfile(memoryGB: 48, cpuCount: 16, gpuWorkingSetGB: 36),
            developmentOverrides: DevelopmentOverrides(candidateRoute: route)
        )
        return (
            paths,
            ProjectMetadata(
                title: "Matching resume",
                input: input,
                requestedRunOptions: options,
                resolvedRunPlan: planForRoute
            )
        )
    }

    private func writeMatchedDatabase(at url: URL) throws {
        var database: OpaquePointer?
        defer { sqlite3_close(database) }
        XCTAssertEqual(sqlite3_open(url.path, &database), SQLITE_OK)
        guard let database else { return }
        let sql = """
        CREATE TABLE matches(pair_id INTEGER PRIMARY KEY, rows INTEGER, cols INTEGER, data BLOB);
        CREATE TABLE two_view_geometries(pair_id INTEGER PRIMARY KEY, rows INTEGER, cols INTEGER, data BLOB);
        INSERT INTO matches(pair_id, rows, cols, data) VALUES (1, 1, 2, X'0000');
        INSERT INTO two_view_geometries(pair_id, rows, cols, data) VALUES (1, 1, 2, X'0000');
        """
        XCTAssertEqual(sqlite3_exec(database, sql, nil, nil, nil), SQLITE_OK)
    }

    private func databaseRowCount(_ table: String, at url: URL) throws -> Int {
        var database: OpaquePointer?
        defer { sqlite3_close(database) }
        guard sqlite3_open_v2(url.path, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK,
              let database else { return -1 }
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(
            database,
            "SELECT COUNT(*) FROM \(table);",
            -1,
            &statement,
            nil
        ) == SQLITE_OK,
              sqlite3_step(statement) == SQLITE_ROW else { return -1 }
        return Int(sqlite3_column_int64(statement, 0))
    }

    private func makeRunner(projectURL: URL) -> PipelineRunner {
        let toolchain = TestToolchains.toolchainPaths(root: projectURL)
        let config = PipelineRunner.PipelineConfig(toolchain: toolchain)
        return PipelineRunner(projectURL: projectURL, config: config)
    }

}
