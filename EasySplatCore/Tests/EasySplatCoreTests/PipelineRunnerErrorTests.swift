import XCTest
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
        XCTAssertEqual(lowQualityMessage.userMessage, "I couldn't get a stable camera solve. Try a slower capture and more light.")
        XCTAssertTrue(lowQualityMessage.debugMessage.contains("Low-quality reconstruction"))

        let transcode = runner.test_makePipelineErrorImageTranscodeFailed("bad")
        let transcodeMessage = runner.test_failureMessages(for: transcode, stage: .selectFrames)
        XCTAssertEqual(transcodeMessage.userMessage, "Failed to convert photos for processing. Try exporting as JPEG/PNG.")

        let outputMissing = runner.test_makePipelineErrorOutputMissing()
        let outputMessage = runner.test_failureMessages(for: outputMissing, stage: .exportSplat)
        XCTAssertEqual(outputMessage.userMessage, "Processing failed. Expected outputs were missing.")
    }

    func testFailureMessagesForSubprocessFailure() throws {
        let runner = makeRunner()
        let failure = SubprocessFailure(
            tool: "glomap",
            command: "mapper",
            exitCode: 1,
            terminationReason: .exit,
            stdoutTail: "out",
            stderrTail: "err"
        )
        let message = runner.test_failureMessages(for: failure, stage: .sfmMapping)
        XCTAssertEqual(message.userMessage, "Processing failed. Check details for more info.")
        XCTAssertTrue(message.debugMessage.contains("Tool: glomap"))
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
        XCTAssertEqual(message.userMessage, "COLMAP crashed while matching images. Try fewer frames or a lower quality preset.")
        XCTAssertTrue(message.debugMessage.contains("Exit code: 10"))
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

    func testGlomapErrorIndicatesMissingOpenSSL() throws {
        let runner = makeRunner()
        let failure = SubprocessFailure(
            tool: "glomap",
            command: "mapper",
            exitCode: 1,
            terminationReason: .exit,
            stdoutTail: "",
            stderrTail: "Library not loaded: @rpath/libcrypto.3.dylib"
        )
        XCTAssertTrue(runner.test_glomapErrorIndicatesMissingOpenSSL(failure))
    }

    private func makeRunner() -> PipelineRunner {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let vggt = VggtToolchain(root: root, sfmTool: root, python: root, models: root)
        let fastvggt = FastVggtToolchain(root: root, sfmTool: root, python: root, models: root)
        let toolchain = ToolchainPaths(root: root, colmap: root, glomap: root, brush: root, vggt: vggt, fastvggt: fastvggt)
        let config = PipelineRunner.PipelineConfig(toolchain: toolchain, preset: PresetSpec(mode: .object, quality: .standard))
        return PipelineRunner(projectURL: root, config: config)
    }
}
