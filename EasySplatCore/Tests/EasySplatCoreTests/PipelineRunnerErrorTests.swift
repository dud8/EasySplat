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

    func testDisconnectedRetrievalGraphOffersCaptureGuidance() {
        let runner = makeRunner()

        let message = runner.test_failureMessages(
            for: ColmapPairPlanningError.disconnectedGraph,
            stage: .sfmMatching
        )

        XCTAssertEqual(
            message.userMessage,
            "The capture did not have enough connected overlap. Try again with more overlap."
        )
        XCTAssertTrue(message.debugMessage.contains("retrieval graph was disconnected"))
    }

    func testRetryDiagnosticEventIncludesCommandTerminationAndLastStderrLine() {
        let runner = makeRunner()
        let error = ColmapRunnerError.failed(
            command: "sequential_matcher",
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
            "Previous sequential_matcher attempt failed: exit 10, \(Process.TerminationReason.uncaughtSignal) — segmentation fault"
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
