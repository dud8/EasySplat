import XCTest
import SQLite3
@testable import EasySplatCore

final class PipelineRunnerErrorTests: XCTestCase {
    func testFailureMessagesForPipelineErrors() throws {
        let runner = makeRunner()

        let invalid = runner.test_makePipelineErrorInvalidInput()
        let invalidMessage = runner.test_failureMessages(for: invalid, stage: .selectFrames)
        XCTAssertEqual(invalidMessage.userMessage, "No usable photos or video frames were found.")

        let score = ReconstructionScore(registeredImages: 1, totalImages: 10, meanReprojectionError: 5.0)
        let lowQuality = runner.test_makePipelineErrorLowQuality(score)
        let lowQualityMessage = runner.test_failureMessages(for: lowQuality, stage: .sfmMapping)
        XCTAssertEqual(lowQualityMessage.userMessage, "The camera solve was unstable. Try a slower capture with more light.")
        XCTAssertTrue(lowQualityMessage.debugMessage.contains("Low-quality reconstruction"))

        let transcode = runner.test_makePipelineErrorImageTranscodeFailed("bad")
        let transcodeMessage = runner.test_failureMessages(for: transcode, stage: .selectFrames)
        XCTAssertEqual(transcodeMessage.userMessage, "Failed to convert photos for processing. Try exporting as JPEG/PNG.")

        let outputMissing = runner.test_makePipelineErrorOutputMissing()
        let outputMessage = runner.test_failureMessages(for: outputMissing, stage: .exportSplat)
        XCTAssertEqual(outputMessage.userMessage, "Processing failed. Expected outputs were missing.")
    }

    func testPhotoBudgetFailureDoesNotRecommendAResourcePolicyThatLowersTheLimit() {
        let runner = makeRunner()
        let error = runner.test_makePipelineErrorPhotoSelectionExceedsBudget(
            selected: 300,
            maximum: 250
        )

        let message = runner.test_failureMessages(for: error, stage: .selectFrames)

        XCTAssertTrue(message.userMessage.contains("Automatic selection"))
        XCTAssertFalse(message.userMessage.contains("Conserve Memory"))
    }

    func testVideoBudgetFailureExplainsSeparateClipLimitWithoutBackendCopy() {
        let runner = makeRunner()
        let error = runner.test_makePipelineErrorVideoFrameBudgetTooSmall(
            required: 8,
            available: 6
        )

        let message = runner.test_failureMessages(for: error, stage: .selectFrames)

        XCTAssertEqual(
            message.userMessage,
            "This capture has too many separate clips for the selected detail."
        )
        XCTAssertTrue(message.debugMessage.contains("requires 8 frames"))
        XCTAssertTrue(message.debugMessage.contains("budget is 6"))
        XCTAssertFalse(message.userMessage.lowercased().contains("backend"))
    }

    func testLowQualityFailureMessageKeepsReliableMapperReprojection() {
        let runner = makeRunner()
        let score = ReconstructionScore(
            registeredImages: 3,
            totalImages: 10,
            meanReprojectionError: 1.25,
            pointCount: 120
        )

        let error = runner.test_makePipelineErrorLowQuality(score, mapper: "colmap")
        let message = runner.test_failureMessages(for: error, stage: .sfmMapping)

        XCTAssertTrue(message.debugMessage.contains("mean reprojection error 1.25"))
    }

    func testFragmentedMappingFailureExplainsTheMeasuredSplit() {
        let runner = makeRunner()
        let error = PipelineRunner.PipelineError.fragmentedReconstruction(
            MappingFragmentationEvidence(
                selectedModelOrder: 0,
                selectedRegisteredViewCount: 226,
                credibleUnionRegisteredViewCount: 249,
                omittedRecoverableViewCount: 23,
                totalSelectedViewCount: 250
            )
        )

        let message = runner.test_failureMessages(for: error, stage: .sfmMapping)

        XCTAssertEqual(
            message.userMessage,
            "The scene could not be connected. Keep the subject and surroundings still, and include more shared detail between views."
        )
        XCTAssertTrue(message.debugMessage.contains("selected model 0 registered 226 of 250"))
        XCTAssertTrue(message.debugMessage.contains("credible union registered 249"))
        XCTAssertTrue(message.debugMessage.contains("23 recoverable views"))
        XCTAssertFalse(message.userMessage.lowercased().contains("colmap"))
    }

    func testConditioningFailuresUseCaptureNeutralGuidanceAndPreserveTheirCause() {
        let runner = makeRunner()
        let measurement = conditioningMeasurementFixture()
        let cases: [(GeometryConditioningFailure, String)] = [
            (
                .insufficientViewSupport(measurement),
                "Not enough views contained reliable shared detail. Try again with more overlap."
            ),
            (
                .collapsedCameraTrajectory(measurement),
                "The capture did not move through enough space. Move around or through the scene as you record."
            ),
            (
                .insufficientParallax(measurement),
                "The views were too similar to recover stable depth. Move around or through the scene as you record."
            ),
            (
                .degeneratePointDistribution(measurement),
                "The capture did not contain enough three-dimensional detail. Try more viewpoints with shared detail."
            ),
        ]

        for (failure, expectedUserMessage) in cases {
            let error = PipelineRunner.PipelineError.geometryConditioningRejected(failure)
            let message = runner.test_failureMessages(for: error, stage: .sfmMapping)

            XCTAssertEqual(message.userMessage, expectedUserMessage)
            XCTAssertTrue(message.debugMessage.contains(failure.localizedDescription))
            guard case .geometryConditioningRejected(let preserved) = error else {
                return XCTFail("Expected a typed conditioning rejection")
            }
            XCTAssertEqual(preserved, failure)
        }
    }

    func testCaptureFailureClassificationUsesOnlyTypedReconstructionFailures() {
        let measurement = conditioningMeasurementFixture()

        XCTAssertEqual(
            PipelineRunner.captureFailureType(
                for: ColmapPairPlanningError.disconnectedVerifiedGraph
            ),
            .disconnectedInput
        )
        XCTAssertEqual(
            PipelineRunner.captureFailureType(
                for: PipelineRunner.PipelineError.fragmentedReconstruction(
                    MappingFragmentationEvidence(
                        selectedModelOrder: 0,
                        selectedRegisteredViewCount: 18,
                        credibleUnionRegisteredViewCount: 30,
                        omittedRecoverableViewCount: 12,
                        totalSelectedViewCount: 30
                    )
                )
            ),
            .multipleScenes
        )
        for failure in [
            GeometryConditioningFailure.insufficientViewSupport(measurement),
            .collapsedCameraTrajectory(measurement),
            .insufficientParallax(measurement),
            .degeneratePointDistribution(measurement),
        ] {
            XCTAssertEqual(
                PipelineRunner.captureFailureType(
                    for: PipelineRunner.PipelineError.geometryConditioningRejected(failure)
                ),
                .insufficientOverlap
            )
        }
        XCTAssertNil(
            PipelineRunner.captureFailureType(
                for: PipelineRunner.PipelineError.geometryConditioningRejected(
                    .rayPairWorkLimitExceeded(maximum: 1_000)
                )
            )
        )
        XCTAssertNil(
            PipelineRunner.captureFailureType(
                for: PipelineRunner.PipelineError.outputMissing
            )
        )
    }

    func testMalformedTracksAndConditioningCapacityDoNotBlameTheCapture() {
        let runner = makeRunner()
        let malformed = PipelineRunner.PipelineError.geometryConditioningRejected(
            .insufficientDistinctTrackViews(pointID: 19, distinctViewCount: 1)
        )
        let malformedMessage = runner.test_failureMessages(
            for: malformed,
            stage: .sfmMapping
        )
        XCTAssertEqual(
            malformedMessage.userMessage,
            "The camera solve contained inconsistent track data."
        )
        XCTAssertFalse(malformedMessage.userMessage.lowercased().contains("capture"))
        XCTAssertTrue(malformedMessage.debugMessage.contains("point 19"))

        let capacity = PipelineRunner.PipelineError.geometryConditioningRejected(
            .rayPairWorkLimitExceeded(maximum: 1_000)
        )
        let capacityMessage = runner.test_failureMessages(for: capacity, stage: .sfmMapping)
        XCTAssertEqual(
            capacityMessage.userMessage,
            "This reconstruction exceeded the safe geometry-verification limit."
        )
        XCTAssertFalse(capacityMessage.userMessage.lowercased().contains("overlap"))
        XCTAssertTrue(capacityMessage.debugMessage.contains("1000-pair work limit"))
    }

    func testFailureMessagesForSubprocessFailure() throws {
        let runner = makeRunner()
        let failure = SubprocessFailure(
            tool: "geometry-helper",
            command: "mapper",
            exitCode: 1,
            terminationReason: .exit,
            stdoutTail: "out",
            stderrTail: "err"
        )
        let message = runner.test_failureMessages(for: failure, stage: .sfmMapping)
        XCTAssertEqual(message.userMessage, "Processing failed. Check details for more info.")
        XCTAssertTrue(message.debugMessage.contains("Tool: geometry-helper"))
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

    func testRasterMemoryFailureNamesTheResolvedLimitWithoutBackendCopy() {
        let runner = makeRunner()
        let error = MsplatRasterMemoryBudgetExceeded(
            iteration: 12,
            requiredBytes: 9_000_000_000,
            budgetBytes: 8_000_000_000
        )

        let message = runner.test_failureMessages(for: error, stage: .trainSplat)

        XCTAssertEqual(
            message.userMessage,
            "Training needs more memory than this run allows."
        )
        XCTAssertFalse(message.userMessage.lowercased().contains("msplat"))
        XCTAssertTrue(message.debugMessage.contains("required 9000000000 bytes"))
        XCTAssertTrue(message.debugMessage.contains("budget 8000000000 bytes"))
    }

    func testRasterResourceFailureNamesTheMetalLimitWithoutSuggestingMoreMemory() {
        let runner = makeRunner()
        let error = MsplatRasterResourceLimitExceeded(
            iteration: 12,
            requiredBytes: 5_000_000_000,
            maximumBufferBytes: 4_000_000_000,
            intersectionCount: 400_000_000
        )

        let message = runner.test_failureMessages(for: error, stage: .trainSplat)

        XCTAssertEqual(
            message.userMessage,
            "This scene exceeded Metal's size limit for one training buffer."
        )
        XCTAssertFalse(message.userMessage.lowercased().contains("more memory"))
        XCTAssertTrue(message.debugMessage.contains("required 5000000000 bytes"))
        XCTAssertTrue(message.debugMessage.contains("maximum 4000000000 bytes"))
    }

    func testMetalAllocationFailureExplainsTransientUnifiedMemoryPressure() {
        let runner = makeRunner()
        let error = MsplatMetalAllocationUnavailable(
            iteration: 27,
            requestedBytes: 1_250_000_000,
            currentAllocatedBytes: 7_500_000_000,
            requiredBytes: 8_750_000_000,
            budgetBytes: 12_000_000_000,
            recommendedWorkingSetBytes: 10_000_000_000,
            maximumBufferBytes: 4_000_000_000,
            intersectionCount: 91_000_000
        )

        let message = runner.test_failureMessages(for: error, stage: .trainSplat)

        XCTAssertEqual(
            message.userMessage,
            "Training could not reserve unified memory. Close other demanding apps, then try again."
        )
        XCTAssertTrue(message.debugMessage.contains("iteration 27"))
        XCTAssertTrue(message.debugMessage.contains("requested 1250000000 bytes"))
        XCTAssertTrue(message.debugMessage.contains("currently allocated 7500000000 bytes"))
        XCTAssertTrue(message.debugMessage.contains("required 8750000000 bytes"))
        XCTAssertTrue(message.debugMessage.contains("budget 12000000000 bytes"))
        XCTAssertTrue(message.debugMessage.contains("recommended working set 10000000000 bytes"))
        XCTAssertTrue(message.debugMessage.contains("maximum buffer 4000000000 bytes"))
        XCTAssertTrue(message.debugMessage.contains("91000000 intersections"))
    }

    func testLiveAdmissionFailuresRemainActionableAndBackendNeutral() {
        let runner = makeRunner()
        let cases: [(TrainingResourceAdmissionError, String)] = [
            (
                .invalidObservation,
                "Current memory availability could not be verified. Try again."
            ),
            (
                .staleObservation,
                "Memory availability changed before training could start. Try again."
            ),
            (
                .insufficientAvailableMemory(
                    requiredBytes: 12_000_000_000,
                    availableBytes: 8_000_000_000
                ),
                "Training needs more free unified memory. Close other demanding apps, then try again."
            ),
        ]

        for (error, expected) in cases {
            let message = runner.test_failureMessages(for: error, stage: .trainSplat)
            XCTAssertEqual(message.userMessage, expected)
            XCTAssertFalse(message.userMessage.lowercased().contains("msplat"))
        }
        let insufficient = runner.test_failureMessages(
            for: TrainingResourceAdmissionError.insufficientAvailableMemory(
                requiredBytes: 12_000_000_000,
                availableBytes: 8_000_000_000
            ),
            stage: .trainSplat
        )
        XCTAssertTrue(insufficient.debugMessage.contains("required 12000000000 bytes"))
        XCTAssertTrue(insufficient.debugMessage.contains("available 8000000000 bytes"))
    }

    func testFailureMessagesForColmapCrash() throws {
        let runner = makeRunner()
        let error = ColmapRunnerError.failed(
            command: "matcher",
            exitCode: 10,
            terminationReason: .uncaughtSignal,
            stdoutTail: "",
            stderrTail: "crash"
        )
        let message = runner.test_failureMessages(for: error, stage: .sfmMatching)
        XCTAssertEqual(message.userMessage, "Image matching stopped. Try fewer frames or Fast detail.")
        XCTAssertFalse(message.userMessage.lowercased().contains("colmap"))
        XCTAssertTrue(message.debugMessage.contains("Exit code: 10"))
    }

    func testDisconnectedSceneFailuresOfferStableCaptureGuidance() {
        let runner = makeRunner()
        let errors: [Error] = [
            ColmapPairPlanningError.disconnectedPairSchedule,
            ColmapPairPlanningError.disconnectedVerifiedGraph,
            PipelineRunner.PipelineError.geometryCoverageTooLow(registered: 18, total: 22),
        ]

        for error in errors {
            XCTAssertEqual(
                runner.test_failureMessages(for: error, stage: .sfmMatching).userMessage,
                "The scene could not be connected. Keep the subject and surroundings still, and include more shared detail between views."
            )
        }

        let verifiedGraph = runner.test_failureMessages(
            for: ColmapPairPlanningError.disconnectedVerifiedGraph,
            stage: .sfmMatching
        )
        XCTAssertTrue(verifiedGraph.debugMessage.contains("pair graph remained disconnected"))
    }

    func testExhaustedVerifiedGraphFailurePreservesActionableMeasurements() throws {
        let runner = makeRunner()
        let failure = try CaptureConnectionFailure(
            pairingPolicy: .unorderedRetrieval,
            selectedViewCount: 256,
            attempt: PairMatchingAttemptArtifact(
                attemptNumber: 4,
                matcher: .exact,
                recoveryLevel: .maximum,
                outcome: .rejected,
                scheduledPairCount: 8_160,
                attemptedPairCount: 8_160,
                rawMatchedPairCount: 2_740,
                spatiallyVerifiedPairCount: 1_203,
                durationSeconds: 14.5
            ),
            connectedComponentCount: 13,
            isolatedViewCount: 11,
            descriptorlessViewCount: 2,
            componentViewCounts: [243, 2] + Array(repeating: 1, count: 11),
            degreeP10: 0,
            degreeMedian: 8,
            degreeP90: 19
        )

        let message = runner.test_failureMessages(for: failure, stage: .sfmMatching)

        XCTAssertEqual(
            message.userMessage,
            "EasySplat found separate parts of the capture. Add views between the gaps with clear shared detail, and keep the scene still."
        )
        for hiddenImplementationTerm in ["faiss", "exact", "colmap", "unordered", "graph"] {
            XCTAssertFalse(message.userMessage.lowercased().contains(hiddenImplementationTerm))
        }
        XCTAssertTrue(message.debugMessage.contains("policy unorderedRetrieval"))
        XCTAssertTrue(message.debugMessage.contains("256 selected views"))
        XCTAssertTrue(message.debugMessage.contains("attempt 4"))
        XCTAssertTrue(message.debugMessage.contains("matcher exact"))
        XCTAssertTrue(message.debugMessage.contains("recovery maximum"))
        XCTAssertTrue(message.debugMessage.contains("scheduled 8160"))
        XCTAssertTrue(message.debugMessage.contains("attempted 8160"))
        XCTAssertTrue(message.debugMessage.contains("raw matched 2740"))
        XCTAssertTrue(message.debugMessage.contains("verified 1203"))
        XCTAssertTrue(message.debugMessage.contains("13 components"))
        XCTAssertTrue(message.debugMessage.contains("11 isolated"))
        XCTAssertTrue(message.debugMessage.contains("2 descriptorless"))
        XCTAssertTrue(
            message.debugMessage.contains(
                "component sizes [243, 2, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1]"
            )
        )
        XCTAssertTrue(message.debugMessage.contains("degree p10/median/p90 0/8/19"))
    }

    func testCaptureConnectionFailureRejectsImpossibleTopologyAndDegreeEvidence() {
        let attempt = PairMatchingAttemptArtifact(
            attemptNumber: 1,
            matcher: .faiss,
            recoveryLevel: .maximum,
            outcome: .rejected,
            scheduledPairCount: 40,
            attemptedPairCount: 40,
            rawMatchedPairCount: 20,
            spatiallyVerifiedPairCount: 6,
            durationSeconds: 1
        )

        XCTAssertThrowsError(try CaptureConnectionFailure(
            pairingPolicy: .unorderedRetrieval,
            selectedViewCount: 8,
            attempt: attempt,
            connectedComponentCount: 3,
            isolatedViewCount: 2,
            descriptorlessViewCount: 1,
            componentViewCounts: [6, 2],
            degreeP10: 0,
            degreeMedian: 2,
            degreeP90: 4
        ))
        XCTAssertThrowsError(try CaptureConnectionFailure(
            pairingPolicy: .unorderedRetrieval,
            selectedViewCount: 8,
            attempt: attempt,
            connectedComponentCount: 3,
            isolatedViewCount: 2,
            descriptorlessViewCount: 1,
            componentViewCounts: [6, 1, 1],
            degreeP10: 3,
            degreeMedian: 2,
            degreeP90: 4
        ))
    }

    func testRetryDiagnosticEventIncludesCommandTerminationAndLastStderrLine() {
        let runner = makeRunner()
        let error = ColmapRunnerError.failed(
            command: "matches_importer",
            exitCode: 10,
            terminationReason: .uncaughtSignal,
            stdoutTail: "ignored stdout",
            stderrTail: "first detail\nsegmentation fault\n"
        )
        var events: [PipelineEvent] = []

        runner.emitColmapRetryDiagnostics(error, stage: .sfmMatching) { events.append($0) }

        guard case let .stageLog(stage, line, isError) = events.first else {
            return XCTFail("Expected one retry diagnostic stage log event.")
        }
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(stage, .sfmMatching)
        XCTAssertTrue(isError)
        XCTAssertEqual(
            line,
            "Previous matches_importer attempt failed: exit 10, \(Process.TerminationReason.uncaughtSignal) — segmentation fault"
        )
    }

    func testKeypointStatsEmitMeasurementAndLowTextureWarningEvents() throws {
        let runner = makeRunner()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let database = root.appendingPathComponent("database.db")
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(database.path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        XCTAssertEqual(sqlite3_exec(db, "CREATE TABLE images(image_id INTEGER PRIMARY KEY);", nil, nil, nil), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(db, "CREATE TABLE keypoints(image_id INTEGER PRIMARY KEY, rows INTEGER);", nil, nil, nil), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(db, "INSERT INTO images(image_id) VALUES (1), (2);", nil, nil, nil), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(db, "INSERT INTO keypoints(image_id, rows) VALUES (1, 5000), (2, 50);", nil, nil, nil), SQLITE_OK)
        sqlite3_close(db)
        db = nil
        var events: [PipelineEvent] = []

        runner.logKeypointStats(database: database) { events.append($0) }

        let lines = events.compactMap { event -> (String, Bool)? in
            guard case let .stageLog(stage, line, isError) = event else { return nil }
            XCTAssertEqual(stage, .sfmFeatures)
            return (line, isError)
        }
        XCTAssertEqual(lines.count, 2)
        XCTAssertEqual(lines[0].0, "Extracted 5050 keypoints across 2 images (avg 2525/image, min 50).")
        XCTAssertFalse(lines[0].1)
        XCTAssertTrue(lines[1].0.contains("only 50 keypoints (below 100)"))
        XCTAssertTrue(lines[1].1)
    }

    func testColmapErrorIndicatesGpuFailure() throws {
        let runner = makeRunner()
        let error = ColmapRunnerError.failed(
            command: "feature_extractor",
            exitCode: 1,
            terminationReason: .exit,
            stdoutTail: "CUDA error",
            stderrTail: ""
        )
        XCTAssertTrue(runner.test_colmapErrorIndicatesGpuFailure(error))
    }

    private func makeRunner() -> PipelineRunner {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let toolchain = TestToolchains.toolchainPaths(root: root)
        let config = PipelineRunner.PipelineConfig(toolchain: toolchain)
        return PipelineRunner(projectURL: root, config: config)
    }

    /// Regression: a malformed or future-versioned project.json causes ProjectMetadataStore.load
    /// to throw at the very top of run(). The previous run's tool log files (e.g. colmap.log,
    /// msplat.log) are exactly what the user needs to diagnose the failed/interrupted state —
    /// the log reset MUST happen only after metadata loads successfully.
    func testRunPreservesPreviousToolLogsWhenMetadataLoadFails() async throws {
        let projectURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: projectURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: projectURL) }

        let paths = ProjectPaths(root: projectURL)
        try paths.ensureDirectories()

        // Plant evidence from a hypothetical prior run.
        let priorColmap = "[2026-04-26T19:30:00.000Z] colmap CRITICAL evidence from previous run\n"
        try priorColmap.write(to: paths.colmapLogURL, atomically: true, encoding: .utf8)
        let priorTraining = "[2026-04-26T19:35:00.000Z] trainer trace from previous run\n"
        try priorTraining.write(to: paths.msplatLogURL, atomically: true, encoding: .utf8)

        // Write a malformed project.json so ProjectMetadataStore.load throws.
        try "{ this is not json".write(to: paths.metadataURL, atomically: true, encoding: .utf8)

        let toolchain = TestToolchains.toolchainPaths(root: projectURL)
        let config = PipelineRunner.PipelineConfig(toolchain: toolchain)
        let runner = PipelineRunner(projectURL: projectURL, config: config)

        // run() must throw without ever wiping the tool logs.
        do {
            try await runner.run { _ in }
            XCTFail("expected metadata load to throw")
        } catch {
            // expected — proceed to verify logs survived.
        }

        let colmapText = try String(contentsOf: paths.colmapLogURL, encoding: .utf8)
        XCTAssertTrue(colmapText.contains("CRITICAL evidence from previous run"),
                      "colmap log was wiped by failed run; got:\n\(colmapText)")
        let trainerText = try String(contentsOf: paths.msplatLogURL, encoding: .utf8)
        XCTAssertTrue(trainerText.contains("trace from previous run"),
                      "trainer log was wiped by failed run; got:\n\(trainerText)")
    }
}
