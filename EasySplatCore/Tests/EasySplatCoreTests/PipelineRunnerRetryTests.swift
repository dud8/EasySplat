import XCTest
import UniformTypeIdentifiers
import SQLite3
@testable import EasySplatCore

final class PipelineRunnerRetryTests: XCTestCase {
    func testSelectedFrameManifestUsesPhotoRankLineageSchema() {
        XCTAssertEqual(PipelineRunner.SelectedFrameMapping.currentSchemaVersion, 3)
    }

    func testSelectedFrameMappingRoundTripsAuthenticatedPhotoRank() throws {
        let data = Data(
            """
            [{
              "schemaVersion": 3,
              "outputFileName": "frame_000000.jpg",
              "groupId": "photos",
              "isVideo": false,
              "sourceProjectRelativePath": "Originals/Photos/photo-0000.jpg",
              "sourceSHA256": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
              "photoRetainedRank": 7
            }]
            """.utf8
        )
        let decoded = try JSONDecoder().decode(
            [PipelineRunner.SelectedFrameMapping].self,
            from: data
        )
        let encoded = try JSONEncoder().encode(decoded)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [[String: Any]]
        )

        XCTAssertEqual(object.first?["photoRetainedRank"] as? Int, 7)
    }

    func testCopySelectedRejectsAuthenticatedPhotoWithoutRetainedRank() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = ProjectPaths(root: root)
        try paths.ensureDirectories()
        try FileManager.default.createDirectory(
            at: paths.importedPhotosURL,
            withIntermediateDirectories: true
        )
        let source = paths.importedPhotosURL.appendingPathComponent("photo-0000.jpg")
        XCTAssertTrue(try TestFileBuilder.writeGrayscaleImage(
            url: source,
            size: 16,
            value: 64,
            utType: .jpeg
        ))
        let digest = try GeometryArtifactStore.sha256(of: source)
        let runner = makeRunner(projectURL: root)

        XCTAssertThrowsError(try runner.copySelected(
            groups: [.init(
                id: "photos",
                frames: [source],
                isVideo: false,
                sourceBindingsByFileName: [
                    source.lastPathComponent: .init(
                        projectRelativePath: try paths.projectRelativePath(for: source),
                        sha256: digest
                    ),
                ]
            )],
            to: paths.framesSelectedURL,
            manifestURL: paths.framesSelectedManifestURL,
            maxDimension: 64,
            projectPaths: paths
        )) { error in
            guard let pipelineError = error as? PipelineRunner.PipelineError,
                  case .invalidInput = pipelineError else {
                return XCTFail("Expected invalidInput, got \(error)")
            }
        }
    }

    func testCopySelectedPersistsAuthenticatedPhotoRetainedRank() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = ProjectPaths(root: root)
        try paths.ensureDirectories()
        try FileManager.default.createDirectory(
            at: paths.importedPhotosURL,
            withIntermediateDirectories: true
        )
        let source = paths.importedPhotosURL.appendingPathComponent("photo-0000.jpg")
        XCTAssertTrue(try TestFileBuilder.writeGrayscaleImage(
            url: source,
            size: 16,
            value: 64,
            utType: .jpeg
        ))
        let digest = try GeometryArtifactStore.sha256(of: source)
        let runner = makeRunner(projectURL: root)

        let selection = try runner.copySelected(
            groups: [.init(
                id: "photos",
                frames: [source],
                isVideo: false,
                sourceBindingsByFileName: [
                    source.lastPathComponent: .init(
                        projectRelativePath: try paths.projectRelativePath(for: source),
                        sha256: digest,
                        photoRetainedRank: 7
                    ),
                ]
            )],
            to: paths.framesSelectedURL,
            manifestURL: paths.framesSelectedManifestURL,
            maxDimension: 64,
            projectPaths: paths
        )

        XCTAssertEqual(selection.manifest.first?.photoRetainedRank, 7)
    }

    func testCopySelectedRejectsNegativePhotoRetainedRank() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = ProjectPaths(root: root)
        try paths.ensureDirectories()
        try FileManager.default.createDirectory(
            at: paths.importedPhotosURL,
            withIntermediateDirectories: true
        )
        let source = paths.importedPhotosURL.appendingPathComponent("photo-0000.jpg")
        XCTAssertTrue(try TestFileBuilder.writeGrayscaleImage(
            url: source,
            size: 16,
            value: 64,
            utType: .jpeg
        ))
        let digest = try GeometryArtifactStore.sha256(of: source)
        let runner = makeRunner(projectURL: root)

        XCTAssertThrowsError(try runner.copySelected(
            groups: [.init(
                id: "photos",
                frames: [source],
                isVideo: false,
                sourceBindingsByFileName: [
                    source.lastPathComponent: .init(
                        projectRelativePath: try paths.projectRelativePath(for: source),
                        sha256: digest,
                        photoRetainedRank: -1
                    ),
                ]
            )],
            to: paths.framesSelectedURL,
            manifestURL: paths.framesSelectedManifestURL,
            maxDimension: 64,
            projectPaths: paths
        )) { error in
            guard let pipelineError = error as? PipelineRunner.PipelineError,
                  case .invalidInput = pipelineError else {
                return XCTFail("Expected invalidInput, got \(error)")
            }
        }
    }

    func testRunRejectsInjectedInvalidWorkerBudgetBeforePersistenceOrSubprocessLaunch() async throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = ProjectPaths(root: root)
        try paths.ensureDirectories()

        let options = RequestedRunOptions(inputOrdering: .unordered)
        let photoFixture = try writeControlledPhotoInputFixture(paths: paths)
        let input = photoFixture.input
        let hardware = HardwareProfile(memoryGB: 48, cpuCount: 16, gpuWorkingSetGB: 36)
        let validPlan = RunPlanResolver.resolve(
            requestedOptions: options,
            input: input,
            hardware: hardware,
            developmentOverrides: .none
        )
        let metadata = ProjectMetadata(
            title: "Invalid worker budget",
            input: input,
            photoInputReceipts: photoFixture.receipts,
            photoSelectionReceipt: photoFixture.selectionReceipt,
            requestedRunOptions: options,
            resolvedRunPlan: validPlan
        )
        try ProjectMetadataStore.save(metadata, to: paths.metadataURL)

        var invalidPlan = validPlan
        invalidPlan.geometryWorkerBudget.coupledMatchingWorkers = 0
        let subprocess = MockSubprocessRunner(scripts: [])
        let runner = PipelineRunner(
            projectURL: root,
            config: PipelineRunner.PipelineConfig(
                toolchain: TestToolchains.toolchainPaths(root: root),
                hardwareProfile: hardware,
                resolvedRunPlan: invalidPlan
            ),
            tooling: PipelineRunner.Tooling(runner: subprocess)
        )

        do {
            try await runner.run { _ in }
            XCTFail("Expected invalid worker budget to stop the run")
        } catch {
            XCTAssertEqual(
                error as? ResolvedRunPlanValidationError,
                .invalidGeometryWorkerBudget,
                "Unexpected preflight error: \(error)"
            )
        }

        XCTAssertTrue(subprocess.calls.isEmpty)
        XCTAssertEqual(
            try ProjectMetadataStore.load(from: paths.metadataURL).resolvedRunPlan,
            validPlan
        )
    }

    func testPairGraphRecoveryRecognizesRecoverableGeometryFailures() {
        XCTAssertTrue(PipelineRunner.shouldRecoverPairGraph(
            after: PipelineRunner.PipelineError.outputMissing
        ))
        XCTAssertTrue(PipelineRunner.shouldRecoverPairGraph(
            after: PipelineRunner.PipelineError.geometryResidualCoverageTooLow(
                measured: 12,
                total: 60
            )
        ))
        XCTAssertTrue(PipelineRunner.shouldRecoverPairGraph(
            after: PipelineRunner.PipelineError.geometryResidualsTooHigh(
                median: 2,
                p90: 4
            )
        ))
        XCTAssertFalse(PipelineRunner.shouldRecoverPairGraph(
            after: PipelineRunner.PipelineError.geometryProvenanceUnavailable("missing")
        ))
        XCTAssertFalse(PipelineRunner.shouldRecoverPairGraph(
            after: ColmapRunnerError.failed(
                command: "mapper",
                exitCode: 1,
                terminationReason: .exit,
                stdoutTail: "",
                stderrTail: "fatal"
            )
        ))
    }

    func testConditioningRecoveryRetriesOnlyCaptureGeometryFailures() {
        let measurement = conditioningMeasurementFixture()
        let recoverable: [(GeometryConditioningFailure, MappingCadenceFallbackTrigger)] = [
            (.insufficientViewSupport(measurement), .insufficientViewSupport),
            (.collapsedCameraTrajectory(measurement), .collapsedCameraTrajectory),
            (.insufficientParallax(measurement), .insufficientParallax),
            (.degeneratePointDistribution(measurement), .degeneratePointDistribution),
        ]

        for (failure, expectedTrigger) in recoverable {
            let error = PipelineRunner.PipelineError.geometryConditioningRejected(failure)
            XCTAssertTrue(PipelineRunner.shouldRecoverPairGraph(after: error), "\(failure)")
            XCTAssertEqual(
                PipelineRunner.mappingCadenceFallbackTrigger(after: error),
                expectedTrigger,
                "\(failure)"
            )
        }

        let malformed = PipelineRunner.PipelineError.geometryConditioningRejected(
            .insufficientDistinctTrackViews(pointID: 19, distinctViewCount: 1)
        )
        XCTAssertFalse(PipelineRunner.shouldRecoverPairGraph(after: malformed))
        XCTAssertNil(PipelineRunner.mappingCadenceFallbackTrigger(after: malformed))

        let capacity = PipelineRunner.PipelineError.geometryConditioningRejected(
            .rayPairWorkLimitExceeded(maximum: 1_000)
        )
        XCTAssertFalse(PipelineRunner.shouldRecoverPairGraph(after: capacity))
        XCTAssertNil(PipelineRunner.mappingCadenceFallbackTrigger(after: capacity))
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
        XCTAssertTrue(PipelineRunner.shouldRecoverPairGraph(
            after: PipelineRunner.PipelineError.geometryResidualsTooHigh(
                median: 2,
                p90: 4
            )
        ))
    }

    func testMappingCadenceFallbackUsesExactMeasuredGeometryWhitelist() {
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

        XCTAssertEqual(
            PipelineRunner.mappingCadenceFallbackTrigger(after: lowQuality),
            .lowReconstructionQuality
        )
        XCTAssertEqual(
            PipelineRunner.mappingCadenceFallbackTrigger(after: fragmentation),
            .fragmentedReconstruction
        )
        XCTAssertEqual(
            PipelineRunner.mappingCadenceFallbackTrigger(
                after: PipelineRunner.PipelineError.geometryCoverageTooLow(
                    registered: 80,
                    total: 100
                )
            ),
            .lowRegisteredViewCoverage
        )
        XCTAssertEqual(
            PipelineRunner.mappingCadenceFallbackTrigger(
                after: PipelineRunner.PipelineError.geometryResidualCoverageTooLow(
                    measured: 80,
                    total: 100
                )
            ),
            .sparseResidualCoverage
        )
        XCTAssertEqual(
            PipelineRunner.mappingCadenceFallbackTrigger(
                after: PipelineRunner.PipelineError.geometryResidualsTooHigh(
                    median: 2,
                    p90: 4
                )
            ),
            .excessiveResiduals
        )

        XCTAssertNil(PipelineRunner.mappingCadenceFallbackTrigger(
            after: CancellationError()
        ))
        XCTAssertNil(PipelineRunner.mappingCadenceFallbackTrigger(
            after: PipelineRunner.PipelineError.invalidInput
        ))
        XCTAssertNil(PipelineRunner.mappingCadenceFallbackTrigger(
            after: PipelineRunner.PipelineError.geometryRegisteredImagesMismatch
        ))
        XCTAssertNil(PipelineRunner.mappingCadenceFallbackTrigger(
            after: PipelineRunner.PipelineError.geometryResidualsUnavailable("parse failed")
        ))
        XCTAssertNil(PipelineRunner.mappingCadenceFallbackTrigger(
            after: PipelineRunner.PipelineError.geometryProvenanceUnavailable("missing")
        ))
        XCTAssertNil(PipelineRunner.mappingCadenceFallbackTrigger(
            after: PipelineRunner.PipelineError.outputMissing
        ))
        XCTAssertNil(PipelineRunner.mappingCadenceFallbackTrigger(
            after: ColmapRunnerError.failed(
                command: "mapper",
                exitCode: 1,
                terminationReason: .exit,
                stdoutTail: "",
                stderrTail: "fatal"
            )
        ))
    }

    private func conditioningMeasurementFixture() -> GeometryConditioningMeasurement {
        GeometryConditioningMeasurement(
            pointCount: 25,
            observationCount: 200,
            positiveDepthObservationCount: 200,
            stronglyMeasuredViewCount: 8,
            registeredViewCount: 8,
            perViewObservationMinimum: 25,
            perViewObservationP10: 25,
            perViewObservationMedian: 25,
            perViewObservationP90: 25,
            distinctTrackLengthMinimum: 8,
            distinctTrackLengthP10: 8,
            distinctTrackLengthMedian: 8,
            distinctTrackLengthP90: 8,
            pointsAtLeast1Point5Degrees: 25,
            pointsAtLeast2Degrees: 25,
            pointsAtLeast3Degrees: 25,
            observationsAtLeast1Point5Degrees: 200,
            observationsAtLeast2Degrees: 200,
            observationsAtLeast3Degrees: 200,
            medianObservedDepth: 12,
            cameraBaselineToMedianDepthRatio: 0.25,
            effectiveCameraCenterCount: 8,
            largestCameraCenterClusterSize: 1,
            cameraCenterMergeToleranceToMedianDepthRatio: 1e-5,
            numericallyConditionedPointCount: 25,
            numericallyConditionedObservationCount: 200,
            adaptiveParallaxThresholdMedianDegrees: 0.05,
            adaptiveParallaxThresholdP90Degrees: 0.05,
            cameraCenterEigenvalues: [0, 0, 1],
            pointEigenvalues: [0, 0.5, 0.5],
            cameraPairEvaluationCount: 28,
            rayPairEvaluationCount: 700
        )
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

        let options = RequestedRunOptions(inputOrdering: .unordered)
        var metadata = ProjectMetadata(
            title: "Test",
            input: .photos(folder: "Originals/Photos"),
            requestedRunOptions: options
        )
        metadata.resolvedRunPlan = RunPlanResolver.resolve(
            requestedOptions: metadata.requestedRunOptions,
            input: metadata.input,
            hardware: HardwareProfile(
                memoryGB: 48,
                cpuCount: 16,
                gpuWorkingSetGB: 36
            ),
            developmentOverrides: .none
        )
        let runner = makeRunner(projectURL: root)
        XCTAssertFalse(runner.test_isStageComplete(.selectFrames, paths: paths, metadata: metadata))

        let completed = try writeMatchingResumeFixture(at: root, route: .colmap)
        XCTAssertEqual(
            completed.metadata.photoInputReceipts?.count,
            RunPlanResolver.minimumReconstructionImageCount
        )
        XCTAssertTrue(runner.test_isStageComplete(
            .selectFrames,
            paths: completed.paths,
            metadata: completed.metadata
        ))
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
        try writeCompletedTrainingArtifact(artifact, paths: paths)
        let metadata = ProjectMetadata(
            title: "Wrong detail",
            input: .photos(folder: "/tmp/Photos"),
            requestedRunOptions: RequestedRunOptions(detailProfile: .balanced)
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
        checkpointed.elapsedSeconds = nil
        try TrainingArtifactStore.save(
            checkpointed,
            to: paths.trainingManifestURL,
            projectPaths: paths
        )
        let metadata = ProjectMetadata(
            title: "Checkpointed",
            input: .photos(folder: "/tmp/Photos"),
            requestedRunOptions: RequestedRunOptions(capturePath: .orbit, detailProfile: .balanced)
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

    func testMissingCompletedTrainingArtifactCannotBeMaskedByUnrelatedPly() throws {
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
            requestedRunOptions: RequestedRunOptions(detailProfile: .highDetail)
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
        let trainingArtifact = makeTrainingArtifact(
            outputPath: "Training/msplat/splat.ply"
        )
        try writeCompletedTrainingArtifact(trainingArtifact, paths: paths)
        let metadata = ProjectMetadata(
            title: "Stale training",
            input: .photos(folder: "/tmp/Photos"),
            requestedRunOptions: RequestedRunOptions(detailProfile: .highDetail)
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
            to: fixture.paths.framesSelectedURL.appendingPathComponent("frame_000001.jpg")
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
            to: fixture.paths.framesSelectedURL.appendingPathComponent("frame_000001.jpg")
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

    func testDa3MatchingResumeRejectsGenericDatabaseWithoutValidFeatureEvidence() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try writeMatchingResumeFixture(at: root, route: .da3)

        XCTAssertEqual(
            try makeRunner(projectURL: root).test_validateStageOutput(
                .sfmMatching,
                paths: fixture.paths,
                metadata: fixture.metadata
            ),
            .corrupt
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

        let (_, receipt) = try TestFileBuilder.writeControlledVideoReceipt(paths: paths)
        let metadata = ProjectMetadata(
            title: "Test",
            input: .video(files: [receipt.projectRelativePath]),
            videoInputReceipts: [receipt],
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
            groups: [[ExtractedFrameOutput(
                url: rawDir.appendingPathComponent("frame_000000.jpg"),
                origin: VideoFrameOrigin(
                    decodedFrameIndex: 0,
                    timestampSeconds: 0,
                    presentationTimeValue: nil,
                    presentationTimeTimescale: nil,
                    timestampWasRepaired: true
                )
            )]],
            targetCounts: [1],
            sourceEvidence: [ExtractedFrameSourceEvidence(receipt: receipt)],
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
        let metadata = try writeCurrentSelectedVideoFixture(paths: paths)

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

    func testSelectedFrameSourceDigestCacheIsScopedToValidationCall() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = ProjectPaths(root: root)
        try paths.ensureDirectories()
        let metadata = try writeCurrentSelectedVideoFixture(paths: paths)
        let runner = makeRunner(projectURL: root)
        let manifest = try runner.loadSelectedFrameManifest(
            from: paths.framesSelectedManifestURL
        )
        XCTAssertGreaterThan(manifest.count, 1)
        XCTAssertEqual(Set(manifest.compactMap(\.sourceProjectRelativePath)).count, 1)
        var hashedPaths: [String] = []

        let status = try runner.validateStageOutput(
            .selectFrames,
            paths: paths,
            metadata: metadata,
            selectedFrameSourceSHA256: { source in
                hashedPaths.append(source.standardizedFileURL.path)
                return try GeometryArtifactStore.sha256(of: source)
            }
        )

        XCTAssertEqual(status, .valid)
        let receipt = try XCTUnwrap(metadata.videoInputReceipts?.first)
        let expectedSource = try paths.resolveProjectRelativePath(
            receipt.projectRelativePath
        )
        XCTAssertEqual(hashedPaths, [expectedSource.standardizedFileURL.path])

        try Data("other content".utf8).write(to: expectedSource)
        XCTAssertEqual(
            try runner.validateStageOutput(
                .selectFrames,
                paths: paths,
                metadata: metadata,
                selectedFrameSourceSHA256: { source in
                    hashedPaths.append(source.standardizedFileURL.path)
                    return try GeometryArtifactStore.sha256(of: source)
                }
            ),
            .corrupt(reason: "selected frame lineage digest changed")
        )
        XCTAssertEqual(
            hashedPaths,
            [expectedSource.standardizedFileURL.path, expectedSource.standardizedFileURL.path]
        )
    }

    func testOneSelectedFrameDoesNotReplaceRecoverableRawFrames() throws {
        try assertUndersizedSelectedVideoDoesNotReplaceRawFrames(selectedFrameCount: 1)
    }

    func testTwoSelectedFramesDoNotReplaceRecoverableRawFrames() throws {
        try assertUndersizedSelectedVideoDoesNotReplaceRawFrames(selectedFrameCount: 2)
    }

    func testValidateStageOutputRejectsVideoGroupThatDoesNotMatchItsPolicyBoundDigest() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = ProjectPaths(root: root)
        try paths.ensureDirectories()
        let metadata = try writeCurrentSelectedVideoFixture(paths: paths)
        let runner = makeRunner(projectURL: root)
        var manifest = try runner.loadSelectedFrameManifest(
            from: paths.framesSelectedManifestURL
        )
        manifest[0] = replacingGroupID(in: manifest[0], with: "video_999")
        try runner.saveSelectedFrameManifest(manifest, to: paths.framesSelectedManifestURL)

        XCTAssertEqual(
            try runner.test_validateStageOutput(
                .selectFrames,
                paths: paths,
                metadata: metadata
            ),
            .corrupt
        )
    }

    func testValidateStageOutputRejectsPhotoGroupOtherThanPhotos() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try writeMatchingResumeFixture(at: root, route: .colmap)
        let runner = makeRunner(projectURL: root)
        var manifest = try runner.loadSelectedFrameManifest(
            from: fixture.paths.framesSelectedManifestURL
        )
        manifest[0] = replacingGroupID(in: manifest[0], with: "alternate-photos")
        try runner.saveSelectedFrameManifest(
            manifest,
            to: fixture.paths.framesSelectedManifestURL
        )

        XCTAssertEqual(
            try runner.test_validateStageOutput(
                .selectFrames,
                paths: fixture.paths,
                metadata: fixture.metadata
            ),
            .corrupt
        )
    }

    func testValidateStageOutputAcceptsAuthenticatedPhotoSelectionLineage() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try writeMatchingResumeFixture(at: root, route: .colmap)

        XCTAssertEqual(
            try makeRunner(projectURL: root).test_validateStageOutput(
                .selectFrames,
                paths: fixture.paths,
                metadata: fixture.metadata
            ),
            .valid
        )
    }

    func testValidateStageOutputRejectsPhotoRankThatDoesNotMatchItsReceipt() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try writeMatchingResumeFixture(at: root, route: .colmap)
        let runner = makeRunner(projectURL: root)
        var manifest = try runner.loadSelectedFrameManifest(
            from: fixture.paths.framesSelectedManifestURL
        )
        manifest[0] = replacingPhotoRetainedRank(
            in: manifest[0],
            with: try XCTUnwrap(manifest[1].photoRetainedRank)
        )
        try runner.saveSelectedFrameManifest(
            manifest,
            to: fixture.paths.framesSelectedManifestURL
        )

        XCTAssertEqual(
            try runner.test_validateStageOutput(
                .selectFrames,
                paths: fixture.paths,
                metadata: fixture.metadata
            ),
            .corrupt
        )
    }

    func testValidateStageOutputRejectsPhotoLineageOutsideProjectedOrder() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try writeMatchingResumeFixture(at: root, route: .colmap)
        let runner = makeRunner(projectURL: root)
        var manifest = try runner.loadSelectedFrameManifest(
            from: fixture.paths.framesSelectedManifestURL
        )
        let first = manifest[0]
        let second = manifest[1]
        manifest[0] = replacingPhotoSourceLineage(in: first, with: second)
        manifest[1] = replacingPhotoSourceLineage(in: second, with: first)
        try runner.saveSelectedFrameManifest(
            manifest,
            to: fixture.paths.framesSelectedManifestURL
        )

        XCTAssertEqual(
            try runner.test_validateStageOutput(
                .selectFrames,
                paths: fixture.paths,
                metadata: fixture.metadata
            ),
            .corrupt
        )
    }

    func testValidateStageOutputRejectsChangedPhotoSelectionArtifact() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try writeMatchingResumeFixture(at: root, route: .colmap)
        try Data("changed photo selection".utf8).write(
            to: fixture.paths.photoSelectionArtifactURL,
            options: .atomic
        )

        XCTAssertEqual(
            try makeRunner(projectURL: root).test_validateStageOutput(
                .selectFrames,
                paths: fixture.paths,
                metadata: fixture.metadata
            ),
            .corrupt
        )
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

        let metadata = try writeCurrentSelectedVideoFixture(paths: paths)
        TestFileBuilder.createFile(at: rawFrame, data: Data("raw".utf8))
        TestFileBuilder.createFile(
            at: paths.framesRawManifestURL,
            data: Data("raw manifest".utf8)
        )
        XCTAssertEqual(chflags(rawFrame.path, UInt32(UF_IMMUTABLE)), 0)
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

    func testValidateStageOutputRejectsCorruptPlyWithoutTrainingReceipt() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = ProjectPaths(root: root)
        try paths.ensureDirectories()
        TestFileBuilder.createFile(at: paths.outputURL.appendingPathComponent("splat.ply"), data: Data("ply".utf8))

        let metadata = ProjectMetadata(
            title: "Test",
            input: .photos(folder: "/tmp/Photos")
        )
        let runner = makeRunner(projectURL: root)
        let status = try runner.test_validateStageOutput(.exportSplat, paths: paths, metadata: metadata)
        XCTAssertEqual(status, .missing)
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

    func testGeometryRerunInvalidatesAcceptedSidecarsAndPreservesPublishedOutput() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = ProjectPaths(root: root)
        try paths.ensureDirectories()
        let photoFixture = try writeControlledPhotoInputFixture(paths: paths)
        var metadata = ProjectMetadata(
            title: "Geometry rerun",
            input: photoFixture.input,
            photoInputReceipts: photoFixture.receipts,
            photoSelectionReceipt: photoFixture.selectionReceipt,
            requestedRunOptions: RequestedRunOptions(inputOrdering: .unordered),
            checkpoint: PipelineCheckpoint(stage: .sfmMapping),
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
        try Data("stale training manifest".utf8).write(to: paths.trainingManifestURL)
        let output = paths.outputURL.appendingPathComponent("splat.ply")
        try TestFileBuilder.writeMinimalPly(at: output)

        try makeRunner(projectURL: root).test_invalidateAcceptedArtifactsForGeometryRerun(
            startingAt: .sfmMapping,
            metadata: &metadata,
            paths: paths
        )

        XCTAssertNil(metadata.checkpoint)
        XCTAssertEqual(metadata.stageTimings?.map(\.stage), [.sfmMatching])
        XCTAssertFalse(FileManager.default.fileExists(atPath: sparseSentinel.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: refinementSentinel.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.geometryManifestURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: trainingSentinel.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.trainingManifestURL.path))
        XCTAssertEqual(ProjectArtifactValidator.validatePlyFile(at: output), .valid)
        let persisted = try ProjectMetadataStore.load(from: paths.metadataURL)
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
        let photoFixture = try writeControlledPhotoInputFixture(paths: paths)
        let input = photoFixture.input
        let previousPlan = RunPlanResolver.resolve(
            requestedOptions: options,
            input: input,
            hardware: hardware,
            developmentOverrides: .none
        )
        var currentPlan = previousPlan
        currentPlan.geometryWorkerBudget.coupledMatchingWorkers -= 1
        let completedBoundary = RunPlanResolver.safeResumeStage(
            .sfmMapping,
            input: input,
            previousPlan: previousPlan,
            currentPlan: currentPlan
        )
        XCTAssertEqual(completedBoundary, .sfmFeatures)
        var metadata = ProjectMetadata(
            title: "Durable plan change",
            input: input,
            photoInputReceipts: photoFixture.receipts,
            photoSelectionReceipt: photoFixture.selectionReceipt,
            requestedRunOptions: options,
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
        try Data("stale training manifest".utf8).write(to: paths.trainingManifestURL)
        try Data("stale".utf8).write(to: paths.geometryManifestURL)
        try Data("stale".utf8).write(to: paths.pairGraphEvidenceURL)
        try Data("stale".utf8).write(to: paths.pairGraphRecoveryURL)
        let publishedOutput = paths.outputURL.appendingPathComponent("splat.ply")
        try TestFileBuilder.writeMinimalPly(at: publishedOutput)

        try makeRunner(projectURL: root).test_persistResolvedPlanChange(
            currentPlan,
            completedBoundary: completedBoundary,
            metadata: &metadata,
            paths: paths
        )

        let persisted = try ProjectMetadataStore.load(from: paths.metadataURL)
        XCTAssertEqual(persisted.resolvedRunPlan, currentPlan)
        XCTAssertEqual(persisted.state.stage, .sfmFeatures)
        XCTAssertNil(persisted.state.lastError)
        XCTAssertNil(persisted.checkpoint)
        XCTAssertNil(persisted.lastRunStartedAt)
        XCTAssertEqual(try databaseRowCount("matches", at: paths.colmapDatabaseURL), 0)
        XCTAssertEqual(try databaseRowCount("two_view_geometries", at: paths.colmapDatabaseURL), 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: sparseSentinel.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.geometryManifestURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.pairGraphEvidenceURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.pairGraphRecoveryURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: trainingSentinel.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.trainingManifestURL.path))
        XCTAssertEqual(ProjectArtifactValidator.validatePlyFile(at: publishedOutput), .valid)
    }

    private func writeMatchingResumeFixture(
        at root: URL,
        route: SfmBackend
    ) throws -> (paths: ProjectPaths, metadata: ProjectMetadata) {
        let paths = ProjectPaths(root: root)
        try paths.ensureDirectories()
        let input = InputSpec.photos(folder: "Originals/Photos")
        let options = RequestedRunOptions(
            detailProfile: .fast,
            cameraGrouping: route == .da3 ? .sameCameraAndLens : .automatic,
            inputOrdering: .unordered,
            photoSelection: .useAllValidPhotos
        )
        let planForRoute = RunPlanResolver.resolve(
            requestedOptions: options,
            input: input,
            hardware: HardwareProfile(memoryGB: 48, cpuCount: 16, gpuWorkingSetGB: 36),
            developmentOverrides: DevelopmentOverrides(candidateRoute: route)
        )
        guard planForRoute.geometryBackend == route else {
            throw NSError(domain: "PipelineRunnerRetryTests", code: 5)
        }
        try FileManager.default.createDirectory(
            at: paths.importedPhotosURL,
            withIntermediateDirectories: true
        )
        let admittedPhotos = try (0..<3).map { index in
            let source = paths.importedPhotosURL.appendingPathComponent(
                String(format: "photo-%04d.jpg", index)
            )
            guard try TestFileBuilder.writeGrayscaleImage(
                url: source,
                size: 16,
                value: UInt8(80 + index),
                utType: .jpeg
            ) else {
                throw NSError(domain: "PipelineRunnerRetryTests", code: 3)
            }
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: source.path
            )
            let sourceSHA256 = try GeometryArtifactStore.sha256(of: source)
            return (source, PhotoInputReceipt(
                projectRelativePath: try paths.projectRelativePath(for: source),
                safeDisplayName: "source_\(index).jpg",
                byteCount: Int64(try Data(contentsOf: source).count),
                sha256: sourceSHA256,
                pixelWidth: 16,
                pixelHeight: 16,
                orientation: 1,
                typeIdentifier: "public.jpeg",
                analysisEvidence: TestFileBuilder.photoAnalysisEvidence(
                    sourceSHA256: sourceSHA256,
                    seed: UInt8(truncatingIfNeeded: index)
                ),
                retainedRank: 0
            ))
        }
        let rankedPhotos = admittedPhotos
            .sorted { $0.1.source.sha256 < $1.1.source.sha256 }
            .enumerated()
            .map { rank, photo in
                let receipt = photo.1
                return (
                    photo.0,
                    PhotoInputReceipt(
                        projectRelativePath: receipt.projectRelativePath,
                        safeDisplayName: receipt.safeDisplayName,
                        byteCount: receipt.byteCount,
                        sha256: receipt.sha256,
                        pixelWidth: receipt.pixelWidth,
                        pixelHeight: receipt.pixelHeight,
                        orientation: receipt.orientation,
                        typeIdentifier: receipt.typeIdentifier,
                        source: receipt.source,
                        importMode: receipt.importMode,
                        analysisEvidence: receipt.analysisEvidence,
                        retainedRank: rank
                    )
                )
            }
        let sourceImages = rankedPhotos.map(\.0)
        let photoReceipts = rankedPhotos.map(\.1)
        let selectionArtifact = PhotoSelectionArtifact(
            strategy: .useAll,
            analysisRecipeVersion: PhotoAnalysisEvidenceBuilder.recipeVersion,
            analysisRecipeSHA256: PhotoAnalysisEvidenceBuilder.recipeSHA256,
            selectorPolicyVersion: PhotoDiversitySelector.selectorPolicyVersion,
            selectorPolicySHA256: PhotoDiversitySelector.selectorPolicySHA256,
            inputOrdering: .unordered,
            requestedPhotoSelection: .useAllValidPhotos,
            admissionCapacity: photoReceipts.count,
            discoveredCount: photoReceipts.count,
            acceptedCount: photoReceipts.count,
            unreadableCount: 0,
            exactDuplicateCount: 0,
            companionDuplicateCount: 0,
            candidates: photoReceipts.enumerated().map { index, receipt in
                PhotoSelectionCandidateArtifact(
                    admissionOrdinal: index,
                    evidence: receipt.analysisEvidence,
                    retainedRank: receipt.retainedRank
                )
            },
            retainedSourceSHA256s: photoReceipts.map(\.source.sha256),
            canonicalRetainedSourceSHA256s: photoReceipts.map(\.source.sha256)
        )
        let selectionFile = try PhotoSelectionArtifactStore.save(
            selectionArtifact,
            to: paths.photoSelectionArtifactURL,
            projectPaths: paths
        )
        let selectionReceipt = PhotoSelectionReceipt(
            projectRelativePath: PhotoSelectionReceipt.projectRelativePath,
            byteCount: selectionFile.byteCount,
            sha256: selectionFile.sha256,
            artifactSchemaVersion: selectionArtifact.schemaVersion,
            analysisRecipeVersion: selectionArtifact.analysisRecipeVersion,
            analysisRecipeSHA256: selectionArtifact.analysisRecipeSHA256,
            selectorPolicyVersion: selectionArtifact.selectorPolicyVersion,
            selectorPolicySHA256: selectionArtifact.selectorPolicySHA256
        )
        let runner = makeRunner(projectURL: root)
        _ = try runner.copySelected(
            groups: [PipelineRunner.SelectedFrameGroup(
                id: "photos",
                frames: sourceImages,
                isVideo: false,
                sourceBindingsByFileName: Dictionary(
                    uniqueKeysWithValues: zip(sourceImages, photoReceipts).map {
                        source, receipt in
                        (
                            source.lastPathComponent,
                            PipelineRunner.SelectedInputSource(
                                projectRelativePath: receipt.projectRelativePath,
                                sha256: receipt.sha256,
                                photoRetainedRank: receipt.retainedRank
                            )
                        )
                    }
                )
            )],
            to: paths.framesSelectedURL,
            manifestURL: paths.framesSelectedManifestURL,
            maxDimension: CGFloat(planForRoute.maximumImageDimension),
            projectPaths: paths
        )
        let imageNames = (0..<3).map { String(format: "frame_%06d.jpg", $0) }

        var database: OpaquePointer?
        guard sqlite3_open(paths.colmapDatabaseURL.path, &database) == SQLITE_OK,
              let database else {
            throw NSError(domain: "PipelineRunnerRetryTests", code: 1)
        }
        let firstPairID = ColmapPairGraphInspector.pairIDDivisor + 2
        let secondPairID = 2 * ColmapPairGraphInspector.pairIDDivisor + 3
        let thirdPairID = ColmapPairGraphInspector.pairIDDivisor + 3
        var cameraParameters = Data()
        for value in [500.0, 500.0, 8.0, 8.0] {
            var littleEndian = value.bitPattern.littleEndian
            withUnsafeBytes(of: &littleEndian) {
                cameraParameters.append(contentsOf: $0)
            }
        }
        let cameraParameterHex = cameraParameters.map {
            String(format: "%02x", $0)
        }.joined()
        let sql = """
        CREATE TABLE cameras(
            camera_id INTEGER PRIMARY KEY AUTOINCREMENT NOT NULL,
            model INTEGER NOT NULL,
            width INTEGER NOT NULL,
            height INTEGER NOT NULL,
            params BLOB,
            prior_focal_length INTEGER NOT NULL
        );
        CREATE TABLE images(
            image_id INTEGER PRIMARY KEY AUTOINCREMENT NOT NULL,
            name TEXT NOT NULL UNIQUE,
            camera_id INTEGER NOT NULL,
            CONSTRAINT image_id_check CHECK(
                image_id >= 0 AND image_id < 2147483647
            ),
            FOREIGN KEY(camera_id) REFERENCES cameras(camera_id)
        );
        CREATE UNIQUE INDEX index_name ON images(name);
        CREATE TABLE rigs(
            rig_id INTEGER PRIMARY KEY AUTOINCREMENT NOT NULL,
            ref_sensor_id INTEGER NOT NULL,
            ref_sensor_type INTEGER NOT NULL
        );
        CREATE UNIQUE INDEX rig_ref_sensor_assignment
            ON rigs(ref_sensor_id, ref_sensor_type);
        CREATE TABLE rig_sensors(
            rig_id INTEGER NOT NULL,
            sensor_id INTEGER NOT NULL,
            sensor_type INTEGER NOT NULL,
            sensor_from_rig BLOB,
            FOREIGN KEY(rig_id) REFERENCES rigs(rig_id) ON DELETE CASCADE
        );
        CREATE UNIQUE INDEX rig_sensor_assignment
            ON rig_sensors(sensor_id, sensor_type);
        CREATE TABLE frames(
            frame_id INTEGER PRIMARY KEY AUTOINCREMENT NOT NULL,
            rig_id INTEGER NOT NULL,
            FOREIGN KEY(rig_id) REFERENCES rigs(rig_id) ON DELETE CASCADE
        );
        CREATE TABLE frame_data(
            frame_id INTEGER NOT NULL,
            data_id INTEGER NOT NULL,
            sensor_id INTEGER NOT NULL,
            sensor_type INTEGER NOT NULL,
            FOREIGN KEY(frame_id) REFERENCES frames(frame_id) ON DELETE CASCADE
        );
        CREATE UNIQUE INDEX frame_sensor_assignment
            ON frame_data(data_id, sensor_type);
        CREATE TABLE pose_priors(
            pose_prior_id INTEGER PRIMARY KEY NOT NULL,
            corr_data_id INTEGER NOT NULL,
            corr_sensor_id INTEGER NOT NULL,
            corr_sensor_type INTEGER NOT NULL,
            position BLOB,
            position_covariance BLOB,
            gravity BLOB,
            coordinate_system INTEGER NOT NULL
        );
        CREATE UNIQUE INDEX pose_prior_data_assignment
            ON pose_priors(corr_data_id, corr_sensor_id, corr_sensor_type);
        CREATE TABLE keypoints(
            image_id INTEGER PRIMARY KEY NOT NULL,
            rows INTEGER NOT NULL,
            cols INTEGER NOT NULL,
            data BLOB,
            FOREIGN KEY(image_id) REFERENCES images(image_id) ON DELETE CASCADE
        );
        CREATE TABLE descriptors(
            image_id INTEGER PRIMARY KEY NOT NULL,
            type INTEGER NOT NULL,
            rows INTEGER NOT NULL,
            cols INTEGER NOT NULL,
            data BLOB,
            FOREIGN KEY(image_id) REFERENCES images(image_id) ON DELETE CASCADE
        );
        CREATE TABLE matches(
            pair_id INTEGER PRIMARY KEY NOT NULL,
            rows INTEGER NOT NULL,
            cols INTEGER NOT NULL,
            data BLOB
        );
        CREATE TABLE two_view_geometries(
            pair_id INTEGER PRIMARY KEY NOT NULL,
            rows INTEGER NOT NULL,
            cols INTEGER NOT NULL,
            data BLOB,
            config INTEGER NOT NULL,
            F BLOB,
            E BLOB,
            H BLOB,
            qvec BLOB,
            tvec BLOB
        );
        INSERT INTO cameras(camera_id, model, width, height, params, prior_focal_length)
        VALUES
            (1, 1, 16, 16, X'\(cameraParameterHex)', 0),
            (2, 1, 16, 16, X'\(cameraParameterHex)', 0),
            (3, 1, 16, 16, X'\(cameraParameterHex)', 0);
        INSERT INTO images(image_id, name, camera_id) VALUES (1, 'frame_000000.jpg', 1), (2, 'frame_000001.jpg', 2), (3, 'frame_000002.jpg', 3);
        INSERT INTO rigs(rig_id, ref_sensor_id, ref_sensor_type)
        VALUES (1, 1, 0), (2, 2, 0), (3, 3, 0);
        INSERT INTO frames(frame_id, rig_id)
        VALUES (1, 1), (2, 2), (3, 3);
        INSERT INTO frame_data(frame_id, data_id, sensor_id, sensor_type)
        VALUES (1, 1, 1, 0), (2, 2, 2, 0), (3, 3, 3, 0);
        INSERT INTO keypoints(image_id, rows, cols, data) VALUES (1, 64, 4, X'01'), (2, 64, 4, X'02'), (3, 64, 4, X'03');
        INSERT INTO descriptors(image_id, type, rows, cols, data) VALUES (1, 0, 64, 128, X'01'), (2, 0, 64, 128, X'02'), (3, 0, 64, 128, X'03');
        INSERT INTO matches(pair_id, rows, cols, data) VALUES (\(firstPairID), 24, 2, X'01'), (\(secondPairID), 24, 2, X'02'), (\(thirdPairID), 24, 2, X'03');
        INSERT INTO two_view_geometries(pair_id, rows, cols, data, config) VALUES (\(firstPairID), 18, 2, X'01', 2), (\(secondPairID), 18, 2, X'02', 2), (\(thirdPairID), 18, 2, X'03', 2);
        """
        let sqliteResult = sqlite3_exec(database, sql, nil, nil, nil)
        sqlite3_close(database)
        guard sqliteResult == SQLITE_OK else {
            throw NSError(domain: "PipelineRunnerRetryTests", code: 2)
        }

        let cameraGroupingReceipt = try ColmapCameraGroupingStore.normalize(
            databaseURL: paths.colmapDatabaseURL,
            selectedImages: imageNames.map {
                ColmapSelectedImageCameraEvidence(
                    imageName: $0,
                    sourceGroupID: "photos",
                    isVideo: false
                )
            },
            mode: .preserveExisting
        )
        let featureEvidence = ColmapFeatureEvidence(
            selectedFramesDigest: try GeometryArtifactStore.selectedFramesDigest(
                orderedImageNames: imageNames,
                projectPaths: paths
            ),
            imageNames: imageNames,
            featureDatabaseDigest: try ColmapDatabaseDigester
                .digests(at: paths.colmapDatabaseURL).feature,
            cameraGroupingReceipt: cameraGroupingReceipt,
            cameraInitializationReceipt: .automaticPerImageSimpleRadial
        )
        try ColmapFeatureEvidenceStore.save(
            featureEvidence,
            to: paths.colmapFeatureEvidenceURL,
            projectPaths: paths
        )

        let plan = try ColmapPairPlan.exhaustive(imageNames: imageNames)
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
            pairingPolicy: planForRoute.pairingPolicy,
            planBinding: PairGraphPlanBinding(planForRoute),
            attempts: [attempt],
            acceptedAttemptNumber: 1,
            acceptedInspection: inspection,
            matchingDurationSeconds: 0.01,
            fallbackReasons: []
        )
        if route == .da3 {
            try PairGraphEvidenceStore.saveDa3Refinement(
                evidence,
                expectedPlanBinding: PairGraphPlanBinding(planForRoute),
                expectedPairPlan: plan,
                to: paths.pairGraphEvidenceURL,
                projectPaths: paths
            )
        } else {
            try PairGraphEvidenceStore.save(
                evidence,
                to: paths.pairGraphEvidenceURL,
                projectPaths: paths
            )
        }

        return (
            paths,
            ProjectMetadata(
                title: "Matching resume",
                input: input,
                photoInputReceipts: photoReceipts,
                photoSelectionReceipt: selectionReceipt,
                requestedRunOptions: options,
                resolvedRunPlan: planForRoute
            )
        )
    }

    private func writeControlledPhotoInputFixture(
        paths: ProjectPaths,
        value: UInt8 = 64
    ) throws -> (
        input: InputSpec,
        receipts: [PhotoInputReceipt],
        selectionReceipt: PhotoSelectionReceipt
    ) {
        try paths.ensureDirectories()
        try FileManager.default.createDirectory(
            at: paths.importedPhotosURL,
            withIntermediateDirectories: true
        )
        let source = paths.importedPhotosURL.appendingPathComponent("photo-0000.jpg")
        guard try TestFileBuilder.writeGrayscaleImage(
            url: source,
            size: 16,
            value: value,
            utType: .jpeg
        ) else {
            throw NSError(domain: "PipelineRunnerRetryTests", code: 6)
        }
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: source.path
        )
        let sourceSHA256 = try GeometryArtifactStore.sha256(of: source)
        let receipt = PhotoInputReceipt(
            projectRelativePath: try paths.projectRelativePath(for: source),
            safeDisplayName: "source.jpg",
            byteCount: Int64(try Data(contentsOf: source).count),
            sha256: sourceSHA256,
            pixelWidth: 16,
            pixelHeight: 16,
            orientation: 1,
            typeIdentifier: UTType.jpeg.identifier,
            analysisEvidence: TestFileBuilder.photoAnalysisEvidence(
                sourceSHA256: sourceSHA256
            ),
            retainedRank: 0
        )
        let selectionArtifact = PhotoSelectionArtifact(
            strategy: .visualDiversity,
            analysisRecipeVersion: PhotoAnalysisEvidenceBuilder.recipeVersion,
            analysisRecipeSHA256: PhotoAnalysisEvidenceBuilder.recipeSHA256,
            selectorPolicyVersion: PhotoDiversitySelector.selectorPolicyVersion,
            selectorPolicySHA256: PhotoDiversitySelector.selectorPolicySHA256,
            inputOrdering: .unordered,
            requestedPhotoSelection: .automatic,
            admissionCapacity: 1,
            discoveredCount: 1,
            acceptedCount: 1,
            unreadableCount: 0,
            exactDuplicateCount: 0,
            companionDuplicateCount: 0,
            candidates: [PhotoSelectionCandidateArtifact(
                admissionOrdinal: 0,
                evidence: receipt.analysisEvidence,
                retainedRank: receipt.retainedRank
            )],
            retainedSourceSHA256s: [receipt.source.sha256],
            canonicalRetainedSourceSHA256s: [receipt.source.sha256]
        )
        let selectionFile = try PhotoSelectionArtifactStore.save(
            selectionArtifact,
            to: paths.photoSelectionArtifactURL,
            projectPaths: paths
        )
        let selectionReceipt = PhotoSelectionReceipt(
            projectRelativePath: PhotoSelectionReceipt.projectRelativePath,
            byteCount: selectionFile.byteCount,
            sha256: selectionFile.sha256,
            artifactSchemaVersion: selectionArtifact.schemaVersion,
            analysisRecipeVersion: selectionArtifact.analysisRecipeVersion,
            analysisRecipeSHA256: selectionArtifact.analysisRecipeSHA256,
            selectorPolicyVersion: selectionArtifact.selectorPolicyVersion,
            selectorPolicySHA256: selectionArtifact.selectorPolicySHA256
        )
        return (
            .photos(folder: "Originals/Photos"),
            [receipt],
            selectionReceipt
        )
    }

    private func writeCurrentSelectedVideoFixture(
        paths: ProjectPaths,
        selectedFrameCount: Int = RunPlanResolver.minimumReconstructionImageCount
    ) throws -> ProjectMetadata {
        precondition(selectedFrameCount > 0)
        let (source, receipt) = try TestFileBuilder.writeControlledVideoReceipt(
            paths: paths,
            bytes: Data("video fixture".utf8)
        )
        let input = InputSpec.video(files: [receipt.projectRelativePath])
        let options = RequestedRunOptions(capturePath: .orbit, detailProfile: .fast)
        let plan = RunPlanResolver.resolve(
            requestedOptions: options,
            input: input,
            hardware: HardwareProfile(memoryGB: 48, cpuCount: 16, gpuWorkingSetGB: 36),
            developmentOverrides: .none
        )
        let sourcePath = try paths.projectRelativePath(for: source)
        let videoSourceData = try JSONSerialization.data(withJSONObject: [
            "projectRelativePath": sourcePath,
            "sourceSHA256": receipt.sha256,
            "trackID": 1,
            "pixelWidth": 16,
            "pixelHeight": 16,
            "nominalFrameRate": 30,
            "transformA": 1,
            "transformB": 0,
            "transformC": 0,
            "transformD": 1,
            "transformTX": 0,
            "transformTY": 0,
        ])
        let videoSource = try JSONDecoder().decode(
            PipelineRunner.SelectedVideoSource.self,
            from: videoSourceData
        )
        let normalization = PipelineRunner.SelectedFrameNormalization(
            sourcePixelWidth: 16,
            sourcePixelHeight: 16,
            sourceOrientation: 1,
            maximumPixelDimension: plan.maximumImageDimension,
            outputPixelWidth: 16,
            outputPixelHeight: 16,
            outputFormat: "jpg",
            transcoded: true
        )
        let mappings = try (0..<selectedFrameCount).map { index in
            let selected = paths.framesSelectedURL.appendingPathComponent(
                String(format: "frame_%06d.jpg", index)
            )
            guard try TestFileBuilder.writeGrayscaleImage(
                url: selected,
                size: 16,
                value: UInt8(64 + index),
                utType: .jpeg
            ) else {
                throw NSError(domain: "PipelineRunnerRetryTests", code: 4)
            }
            let origin = VideoFrameOrigin(
                decodedFrameIndex: index,
                timestampSeconds: Double(index) / 30,
                presentationTimeValue: Int64(index),
                presentationTimeTimescale: 30,
                timestampWasRepaired: false
            )
            return PipelineRunner.SelectedFrameMapping(
                outputFileName: selected.lastPathComponent,
                groupId: "video_000",
                isVideo: true,
                timestampSeconds: origin.timestampSeconds,
                sourceProjectRelativePath: sourcePath,
                sourceSHA256: try GeometryArtifactStore.sha256(of: source),
                selectedSHA256: try GeometryArtifactStore.sha256(of: selected),
                selectedPixelSHA256: try PipelineRunner.selectedFramePixelSHA256(at: selected),
                normalization: normalization,
                videoSource: videoSource,
                videoOrigin: origin
            )
        }
        try JSONEncoder().encode(mappings).write(
            to: paths.framesSelectedManifestURL,
            options: .atomic
        )
        var metadata = ProjectMetadata(
            title: "Test",
            input: input,
            videoInputReceipts: [receipt],
            requestedRunOptions: options,
            resolvedRunPlan: plan
        )
        metadata.state = PipelineState(stage: .sfmFeatures, lastError: nil)
        return metadata
    }

    private func assertUndersizedSelectedVideoDoesNotReplaceRawFrames(
        selectedFrameCount: Int
    ) throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = ProjectPaths(root: root)
        try paths.ensureDirectories()
        let metadata = try writeCurrentSelectedVideoFixture(
            paths: paths,
            selectedFrameCount: selectedFrameCount
        )
        let receipt = try XCTUnwrap(metadata.videoInputReceipts?.first)
        let rawDirectory = paths.framesRawURL.appendingPathComponent(
            "video_000",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: rawDirectory,
            withIntermediateDirectories: true
        )
        let rawFrames = try (0..<RunPlanResolver.minimumReconstructionImageCount).map {
            index in
            let url = rawDirectory.appendingPathComponent(
                String(format: "frame_%06d.jpg", index)
            )
            guard try TestFileBuilder.writeGrayscaleImage(
                url: url,
                size: 16,
                value: UInt8(96 + index),
                utType: .jpeg
            ) else {
                throw NSError(domain: "PipelineRunnerRetryTests", code: 7)
            }
            return ExtractedFrameOutput(
                url: url,
                origin: VideoFrameOrigin(
                    decodedFrameIndex: index,
                    timestampSeconds: Double(index) / 30,
                    presentationTimeValue: Int64(index),
                    presentationTimeTimescale: 30,
                    timestampWasRepaired: false
                )
            )
        }
        _ = try ExtractedFrameManifestStore.persist(
            groups: [rawFrames],
            targetCounts: [rawFrames.count],
            sourceEvidence: [ExtractedFrameSourceEvidence(receipt: receipt)],
            paths: paths
        )
        let runner = makeRunner(projectURL: root)

        XCTAssertEqual(
            try runner.test_validateStageOutput(
                .selectFrames,
                paths: paths,
                metadata: metadata
            ),
            .corrupt
        )
        XCTAssertEqual(
            try runner.test_validateStageOutput(
                .extractFrames,
                paths: paths,
                metadata: metadata
            ),
            .valid
        )
        try runner.test_cleanupRawFramesAfterDurableSelection(
            paths: paths,
            metadata: metadata
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: rawFrames[0].url.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: paths.framesRawManifestURL.path))
    }

    private func replacingGroupID(
        in mapping: PipelineRunner.SelectedFrameMapping,
        with groupID: String
    ) -> PipelineRunner.SelectedFrameMapping {
        PipelineRunner.SelectedFrameMapping(
            schemaVersion: mapping.schemaVersion,
            outputFileName: mapping.outputFileName,
            groupId: groupID,
            isVideo: mapping.isVideo,
            timestampSeconds: mapping.timestampSeconds,
            lowLightExposureEV: mapping.lowLightExposureEV,
            sourceProjectRelativePath: mapping.sourceProjectRelativePath,
            sourceSHA256: mapping.sourceSHA256,
            photoRetainedRank: mapping.photoRetainedRank,
            selectedSHA256: mapping.selectedSHA256,
            selectedPixelSHA256: mapping.selectedPixelSHA256,
            normalization: mapping.normalization,
            videoSource: mapping.videoSource,
            videoOrigin: mapping.videoOrigin
        )
    }

    private func replacingPhotoRetainedRank(
        in mapping: PipelineRunner.SelectedFrameMapping,
        with retainedRank: Int
    ) -> PipelineRunner.SelectedFrameMapping {
        PipelineRunner.SelectedFrameMapping(
            schemaVersion: mapping.schemaVersion,
            outputFileName: mapping.outputFileName,
            groupId: mapping.groupId,
            isVideo: mapping.isVideo,
            timestampSeconds: mapping.timestampSeconds,
            lowLightExposureEV: mapping.lowLightExposureEV,
            sourceProjectRelativePath: mapping.sourceProjectRelativePath,
            sourceSHA256: mapping.sourceSHA256,
            photoRetainedRank: retainedRank,
            selectedSHA256: mapping.selectedSHA256,
            selectedPixelSHA256: mapping.selectedPixelSHA256,
            normalization: mapping.normalization,
            videoSource: mapping.videoSource,
            videoOrigin: mapping.videoOrigin
        )
    }

    private func replacingPhotoSourceLineage(
        in mapping: PipelineRunner.SelectedFrameMapping,
        with source: PipelineRunner.SelectedFrameMapping
    ) -> PipelineRunner.SelectedFrameMapping {
        PipelineRunner.SelectedFrameMapping(
            schemaVersion: mapping.schemaVersion,
            outputFileName: mapping.outputFileName,
            groupId: mapping.groupId,
            isVideo: mapping.isVideo,
            timestampSeconds: mapping.timestampSeconds,
            lowLightExposureEV: mapping.lowLightExposureEV,
            sourceProjectRelativePath: source.sourceProjectRelativePath,
            sourceSHA256: source.sourceSHA256,
            photoRetainedRank: source.photoRetainedRank,
            selectedSHA256: mapping.selectedSHA256,
            selectedPixelSHA256: mapping.selectedPixelSHA256,
            normalization: mapping.normalization,
            videoSource: mapping.videoSource,
            videoOrigin: mapping.videoOrigin
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

    private func writeCompletedTrainingArtifact(
        _ source: TrainingArtifact,
        paths: ProjectPaths
    ) throws {
        var artifact = source
        let outputPath = try XCTUnwrap(artifact.outputPath)
        let outputURL = try paths.resolveProjectRelativePath(outputPath)
        try FileManager.default.createDirectory(
            at: outputURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try TestFileBuilder.writeMinimalPly(at: outputURL)
        let evidence = try ProjectArtifactValidator.validatedPlyEvidence(at: outputURL)
        artifact.outputSHA256 = evidence.sha256
        artifact.outputBytes = Int64(evidence.byteCount)
        artifact.gaussianCount = evidence.vertexCount
        artifact.sceneBounds = evidence.sceneBounds
        try TrainingArtifactStore.save(
            artifact,
            to: paths.trainingManifestURL,
            projectPaths: paths
        )
    }

    private func makeRunner(projectURL: URL) -> PipelineRunner {
        let toolchain = TestToolchains.toolchainPaths(root: projectURL)
        let config = PipelineRunner.PipelineConfig(toolchain: toolchain)
        return PipelineRunner(projectURL: projectURL, config: config)
    }

}
