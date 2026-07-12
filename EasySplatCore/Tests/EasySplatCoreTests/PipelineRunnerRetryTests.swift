import XCTest
import UniformTypeIdentifiers
@testable import EasySplatCore

final class PipelineRunnerRetryTests: XCTestCase {
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

        let metadata = ProjectMetadata(title: "Test", input: .photos(folder: photosFolder), preset: PresetSpec(mode: .object, quality: .draft))
        let runner = makeRunner(projectURL: root)
        XCTAssertTrue(runner.test_isStageComplete(.importInput, paths: paths, metadata: metadata))
    }

    func testIsStageCompleteSelectFrames() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = ProjectPaths(root: root)
        try paths.ensureDirectories()

        let metadata = ProjectMetadata(title: "Test", input: .photos(folder: "/tmp/Photos"), preset: PresetSpec(mode: .object, quality: .draft))
        let runner = makeRunner(projectURL: root)
        XCTAssertFalse(runner.test_isStageComplete(.selectFrames, paths: paths, metadata: metadata))

        let file = paths.framesSelectedURL.appendingPathComponent("frame_000000.jpg")
        TestFileBuilder.createFile(at: file, data: Data([0x00]))
        let manifest = [TestSelectedFrameMapping(
            outputFileName: "frame_000000.jpg",
            groupId: "photos",
            isVideo: false,
            sourcePath: "/tmp/Photos/img001.jpg"
        )]
        let data = try JSONEncoder().encode(manifest)
        try data.write(to: paths.framesSelectedManifestURL, options: [.atomic])
        XCTAssertTrue(runner.test_isStageComplete(.selectFrames, paths: paths, metadata: metadata))
    }

    func testIsStageCompleteSfmMapping() throws {
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

        let metadata = ProjectMetadata(title: "Test", input: .photos(folder: "/tmp/Photos"), preset: PresetSpec(mode: .object, quality: .draft))
        let runner = makeRunner(projectURL: root)
        XCTAssertTrue(runner.test_isStageComplete(.sfmMapping, paths: paths, metadata: metadata))
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

        let metadata = ProjectMetadata(title: "Test", input: .photos(folder: "/tmp/Photos"), preset: PresetSpec(mode: .object, quality: .draft))
        let runner = makeRunner(projectURL: root)
        XCTAssertEqual(try runner.test_validateStageOutput(.sfmMapping, paths: paths, metadata: metadata), .corrupt)
    }

    func testValidateStageOutputRejectsLegacyDa3SparseWithoutNativeExportProof() throws {
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
        0 0 1
        """.write(to: sparse.appendingPathComponent("images.txt"), atomically: true, encoding: .utf8)
        try "1 0 0 1 128 128 128 1.0 1 0\n"
            .write(to: sparse.appendingPathComponent("points3D.txt"), atomically: true, encoding: .utf8)
        try """
        {
          "mode": "direct",
          "requested_device": "mps",
          "selected_device": "mps",
          "model_subdir": "DA3-BASE",
          "fallback_model_subdir": "DA3-SMALL",
          "process_res": 504,
          "camera_type": "PINHOLE",
          "shared_camera": false,
          "max_points": 120000,
          "total_images": 1,
          "window_size": 2,
          "window_overlap": 0,
          "windows": [
            { "start": 0, "end": 1, "images": ["frame_000000.jpg"] }
          ],
          "raw_point_sample_count": 1,
          "fused_sparse_point_count": 1,
          "final_observation_count": 1,
          "mean_track_length": 1.0,
          "registered_image_count": 1
        }
        """.write(to: paths.da3CoverageManifestURL, atomically: true, encoding: .utf8)

        let metadata = ProjectMetadata(title: "Test", input: .photos(folder: "/tmp/Photos"), preset: PresetSpec(mode: .object, quality: .draft))
        let runner = makeRunner(projectURL: root)
        XCTAssertEqual(try runner.test_validateStageOutput(.sfmMapping, paths: paths, metadata: metadata), .corrupt)
    }

    func testValidateStageOutputAcceptsDa3SparseTextWhenTracksMatchImageRows() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = ProjectPaths(root: root)
        try paths.ensureDirectories()
        for index in 0..<2 {
            XCTAssertTrue(try TestFileBuilder.writeGrayscaleImage(
                url: paths.framesSelectedURL.appendingPathComponent("frame_00000\(index).jpg"),
                size: 16,
                value: UInt8(32 + index),
                utType: .jpeg
            ))
        }
        let sparse = paths.colmapSparseURL.appendingPathComponent("0", isDirectory: true)
        try FileManager.default.createDirectory(at: sparse, withIntermediateDirectories: true)
        try "1 SIMPLE_PINHOLE 640 480 500 320 240\n"
            .write(to: sparse.appendingPathComponent("cameras.txt"), atomically: true, encoding: .utf8)
        try """
        # images
        1 1 0 0 0 0 0 0 1 frame_000000.jpg
        0 0 1
        2 1 0 0 0 0 0 0 1 frame_000001.jpg
        0 0 1
        """.write(to: sparse.appendingPathComponent("images.txt"), atomically: true, encoding: .utf8)
        try """
        # points
        1 0 0 1 128 128 128 1.0 1 0 2 0
        """.write(to: sparse.appendingPathComponent("points3D.txt"), atomically: true, encoding: .utf8)
        try """
        {
          "mode": "direct",
          "requested_device": "mps",
          "selected_device": "mps",
          "model_subdir": "DA3-BASE",
          "fallback_model_subdir": "DA3-SMALL",
          "process_res": 504,
          "camera_type": "PINHOLE",
          "shared_camera": false,
          "max_points": 120000,
          "total_images": 2,
          "window_size": 2,
          "window_overlap": 0,
          "windows": [
            { "start": 0, "end": 2, "images": ["frame_000000.jpg", "frame_000001.jpg"] }
          ],
          "raw_point_sample_count": 1,
          "fused_sparse_point_count": 1,
          "final_observation_count": 2,
          "mean_track_length": 2.0,
          "registered_image_count": 2,
          "native_colmap_export": true,
          "export_strategy": "native_colmap"
        }
        """.write(to: paths.da3CoverageManifestURL, atomically: true, encoding: .utf8)

        let metadata = ProjectMetadata(title: "Test", input: .photos(folder: "/tmp/Photos"), preset: PresetSpec(mode: .object, quality: .draft))
        let runner = makeRunner(projectURL: root)
        XCTAssertEqual(try runner.test_validateStageOutput(.sfmMapping, paths: paths, metadata: metadata), .valid)
    }

    func testValidateStageOutputRejectsDa3ManifestWhenSparseTextTrackIsInvalid() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = ProjectPaths(root: root)
        try paths.ensureDirectories()
        XCTAssertTrue(try TestFileBuilder.writeGrayscaleImage(
            url: paths.framesSelectedURL.appendingPathComponent("frame_000000.jpg"),
            size: 16,
            value: 32,
            utType: .jpeg
        ))
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
        1 0 0 1 128 128 128 1.0 99 0
        """.write(to: sparse.appendingPathComponent("points3D.txt"), atomically: true, encoding: .utf8)
        try """
        {
          "mode": "direct",
          "requested_device": "mps",
          "selected_device": "mps",
          "model_subdir": "DA3-BASE",
          "fallback_model_subdir": "DA3-SMALL",
          "process_res": 504,
          "camera_type": "PINHOLE",
          "shared_camera": false,
          "max_points": 120000,
          "total_images": 1,
          "window_size": 2,
          "window_overlap": 0,
          "windows": [
            { "start": 0, "end": 1, "images": ["frame_000000.jpg"] }
          ],
          "raw_point_sample_count": 1,
          "fused_sparse_point_count": 1,
          "final_observation_count": 1,
          "mean_track_length": 1.0,
          "registered_image_count": 1,
          "native_colmap_export": true,
          "export_strategy": "native_colmap"
        }
        """.write(to: paths.da3CoverageManifestURL, atomically: true, encoding: .utf8)

        let metadata = ProjectMetadata(title: "Test", input: .photos(folder: "/tmp/Photos"), preset: PresetSpec(mode: .object, quality: .draft))
        let runner = makeRunner(projectURL: root)
        XCTAssertEqual(try runner.test_validateStageOutput(.sfmMapping, paths: paths, metadata: metadata), .corrupt)
    }

    func testValidateStageOutputRejectsDa3ResumeFromFeaturesWithInvalidManifest() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = ProjectPaths(root: root)
        try paths.ensureDirectories()
        try writeDa3SparseFixture(
            paths: paths,
            imageCount: 1,
            pointRows: ["1 0 0 1 128 128 128 1.0 1 0"],
            pointCount: 1,
            observationCount: 1,
            meanTrackLength: 1.0,
            nativeColmapExport: false,
            exportStrategy: "windowed_direct_colmap"
        )
        FileManager.default.createFile(atPath: paths.colmapDatabaseURL.path, contents: Data())

        let metadata = ProjectMetadata(
            title: "Test",
            input: .photos(folder: "/tmp/Photos"),
            preset: PresetSpec(mode: .object, quality: .draft),
            checkpoint: PipelineCheckpoint(stage: .sfmFeatures)
        )
        let runner = makeRunner(projectURL: root)
        XCTAssertEqual(try runner.test_validateStageOutput(.sfmFeatures, paths: paths, metadata: metadata), .corrupt)
    }

    func testValidateStageOutputRejectsDa3ManifestMeanTrackLengthMismatch() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = ProjectPaths(root: root)
        try paths.ensureDirectories()
        try writeDa3SparseFixture(
            paths: paths,
            imageCount: 2,
            pointRows: [
                "1 0 0 1 128 128 128 1.0 1 0",
                "2 0 0 2 128 128 128 1.0 2 0"
            ],
            imagePointLines: ["0 0 1", "0 0 2"],
            pointCount: 2,
            observationCount: 2,
            meanTrackLength: 2.0
        )

        let metadata = ProjectMetadata(title: "Test", input: .photos(folder: "/tmp/Photos"), preset: PresetSpec(mode: .object, quality: .draft))
        let runner = makeRunner(projectURL: root)
        XCTAssertEqual(try runner.test_validateStageOutput(.sfmMapping, paths: paths, metadata: metadata), .corrupt)
    }

    func testCompletedLegacyVggtGeometryCanStartNativeTraining() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = ProjectPaths(root: root)
        try paths.ensureDirectories()
        let sparse = paths.colmapSparseURL.appendingPathComponent("0", isDirectory: true)
        try writeLegacyTracklessSparseFixture(at: sparse)

        let metadata = ProjectMetadata(
            title: "Legacy training",
            input: .photos(folder: "/tmp/Photos"),
            preset: PresetSpec(mode: .object, quality: .draft),
            state: PipelineState(stage: .trainSplat, attempt: 0, lastError: nil, resumeToken: nil),
            checkpoint: PipelineCheckpoint(stage: .trainSplat),
            completedSfmMapping: SfmMappingCheckpoint(
                mapper: "vggt",
                sparsePath: "SfM/colmap/sparse/0",
                registeredImages: 2
            )
        )

        let runner = makeRunner(projectURL: root)
        XCTAssertEqual(try runner.test_validateStageOutput(.sfmMapping, paths: paths, metadata: metadata), .valid)
    }

    func testInterruptedLegacyVggtGeometryRestartsGeometry() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = ProjectPaths(root: root)
        try paths.ensureDirectories()
        let sparse = paths.colmapSparseURL.appendingPathComponent("0", isDirectory: true)
        try writeLegacyTracklessSparseFixture(at: sparse)

        let mapping = SfmMappingCheckpoint(
            mapper: "vggt",
            sparsePath: "SfM/colmap/sparse/0",
            registeredImages: 2
        )
        let metadata = ProjectMetadata(
            title: "Legacy geometry",
            input: .photos(folder: "/tmp/Photos"),
            preset: PresetSpec(mode: .object, quality: .draft),
            state: PipelineState(stage: .sfmMapping, attempt: 0, lastError: nil, resumeToken: nil),
            checkpoint: PipelineCheckpoint(stage: .sfmMapping, details: .sfmMapping(mapping)),
            completedSfmMapping: mapping
        )

        let runner = makeRunner(projectURL: root)
        XCTAssertEqual(try runner.test_validateStageOutput(.sfmMapping, paths: paths, metadata: metadata), .corrupt)
    }

    private func writeLegacyTracklessSparseFixture(at sparse: URL) throws {
        try FileManager.default.createDirectory(at: sparse, withIntermediateDirectories: true)
        try "1 SIMPLE_PINHOLE 640 480 500 320 240\n"
            .write(to: sparse.appendingPathComponent("cameras.txt"), atomically: true, encoding: .utf8)
        try """
        1 1 0 0 0 0 0 0 1 frame_000000.jpg

        2 1 0 0 0 0 0 0 1 frame_000001.jpg

        """.write(to: sparse.appendingPathComponent("images.txt"), atomically: true, encoding: .utf8)
        try "1 0 0 1 128 128 128 1.0\n"
            .write(to: sparse.appendingPathComponent("points3D.txt"), atomically: true, encoding: .utf8)
    }

    func testLegacyBrushExportDoesNotCompleteNativeTraining() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = ProjectPaths(root: root)
        try paths.ensureDirectories()
        let training = paths.trainingURL
        try FileManager.default.createDirectory(at: training, withIntermediateDirectories: true)
        try TestFileBuilder.writeMinimalPly(at: training.appendingPathComponent("export_00001.ply"))

        let metadata = ProjectMetadata(title: "Test", input: .photos(folder: "/tmp/Photos"), preset: PresetSpec(mode: .object, quality: .draft))
        let runner = makeRunner(projectURL: root)
        XCTAssertFalse(runner.test_isStageComplete(.trainSplat, paths: paths, metadata: metadata))
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
            preset: PresetSpec(mode: .object, quality: .draft),
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
            preset: PresetSpec(mode: .object, quality: .standard),
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
            at: paths.trainingURL.appendingPathComponent("export_99999.ply")
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
            preset: PresetSpec(mode: .object, quality: .standard),
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

    func testCompletedTrainingArtifactCannotBeMaskedByUnrelatedBrushExport() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = ProjectPaths(root: root)
        try paths.ensureDirectories()
        try TestFileBuilder.writeMinimalPly(
            at: paths.trainingURL.appendingPathComponent("export_99999.ply")
        )
        let metadata = ProjectMetadata(
            title: "Completed",
            input: .photos(folder: "/tmp/Photos"),
            preset: PresetSpec(mode: .object, quality: .standard),
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
            .missing
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
            preset: PresetSpec(mode: .object, quality: .standard),
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

        let metadata = ProjectMetadata(title: "Test", input: .photos(folder: "/tmp/Photos"), preset: PresetSpec(mode: .object, quality: .draft))
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

        let metadata = ProjectMetadata(title: "Test", input: .photos(folder: "/tmp/Photos"), preset: PresetSpec(mode: .object, quality: .draft))
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
            preset: PresetSpec(mode: .object, quality: .draft)
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

        let metadata = ProjectMetadata(title: "Test", input: .photos(folder: "/tmp/Photos"), preset: PresetSpec(mode: .object, quality: .draft))
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
        let config = PipelineRunner.PipelineConfig(toolchain: toolchain, preset: PresetSpec(mode: .object, quality: .standard))
        return PipelineRunner(projectURL: projectURL, config: config)
    }

    private func writeDa3SparseFixture(
        paths: ProjectPaths,
        imageCount: Int,
        pointRows: [String],
        imagePointLines: [String]? = nil,
        pointCount: Int,
        observationCount: Int,
        meanTrackLength: Double,
        nativeColmapExport: Bool = true,
        exportStrategy: String = "native_colmap"
    ) throws {
        for index in 0..<imageCount {
            XCTAssertTrue(try TestFileBuilder.writeGrayscaleImage(
                url: paths.framesSelectedURL.appendingPathComponent(String(format: "frame_%06d.jpg", index)),
                size: 16,
                value: UInt8(32 + index),
                utType: .jpeg
            ))
        }
        let sparse = paths.colmapSparseURL.appendingPathComponent("0", isDirectory: true)
        try FileManager.default.createDirectory(at: sparse, withIntermediateDirectories: true)
        try "1 SIMPLE_PINHOLE 640 480 500 320 240\n"
            .write(to: sparse.appendingPathComponent("cameras.txt"), atomically: true, encoding: .utf8)

        let imagePointLines = imagePointLines ?? Array(repeating: "0 0 1", count: imageCount)
        var imagesText = "# images\n"
        for index in 0..<imageCount {
            let imageID = index + 1
            imagesText += "\(imageID) 1 0 0 0 0 0 0 1 \(String(format: "frame_%06d.jpg", index))\n"
            imagesText += "\(imagePointLines[index])\n"
        }
        try imagesText.write(to: sparse.appendingPathComponent("images.txt"), atomically: true, encoding: .utf8)
        try (pointRows.joined(separator: "\n") + "\n")
            .write(to: sparse.appendingPathComponent("points3D.txt"), atomically: true, encoding: .utf8)

        let windowImages = (0..<imageCount)
            .map { String(format: "\"frame_%06d.jpg\"", $0) }
            .joined(separator: ", ")
        try """
        {
          "mode": "direct",
          "requested_device": "mps",
          "selected_device": "mps",
          "model_subdir": "DA3-BASE",
          "fallback_model_subdir": "DA3-SMALL",
          "process_res": 504,
          "camera_type": "PINHOLE",
          "shared_camera": false,
          "max_points": 120000,
          "total_images": \(imageCount),
          "window_size": \(max(2, imageCount)),
          "window_overlap": 0,
          "windows": [
            { "start": 0, "end": \(imageCount), "images": [\(windowImages)] }
          ],
          "raw_point_sample_count": \(pointCount),
          "fused_sparse_point_count": \(pointCount),
          "final_observation_count": \(observationCount),
          "mean_track_length": \(meanTrackLength),
          "registered_image_count": \(imageCount),
          "native_colmap_export": \(nativeColmapExport ? "true" : "false"),
          "export_strategy": "\(exportStrategy)"
        }
        """.write(to: paths.da3CoverageManifestURL, atomically: true, encoding: .utf8)
    }
}
