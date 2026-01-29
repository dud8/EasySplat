#if canImport(XCTest)
import Foundation
import XCTest
@testable import EasySplatCore

final class LearnedMatchingRunnerTests: XCTestCase {
    func testRunBuildsExpectedArgs() async throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let toolchain = try TestToolchains.learnedSfmToolchain(root: temp, createFiles: true)
        let imagesPath = temp.appendingPathComponent("images", isDirectory: true)
        let outFeatures = temp.appendingPathComponent("features", isDirectory: true)
        let outMatchList = temp.appendingPathComponent("matches.txt")

        try FileManager.default.createDirectory(at: imagesPath, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outFeatures, withIntermediateDirectories: true)

        let config = LearnedMatchingConfig(
            device: "mps",
            maxImageSize: 1600,
            sequentialOverlap: 8,
            stride: 2,
            loopK: 3,
            pairing: "video"
        )

        var capturedArgs: [String] = []
        let mock = MockSubprocessRunner(scripts: [
            .init(path: toolchain.matchTool.path, argsPrefix: ["--images", imagesPath.path], result: .init(exitCode: 0, terminationReason: .exit, stdout: "", stderr: ""), onRun: { args in
                capturedArgs = args
            })
        ])

        let runner = LearnedMatchingRunner(runner: mock)
        try await runner.run(
            toolchain: toolchain,
            images: imagesPath,
            outFeatures: outFeatures,
            outMatchList: outMatchList,
            config: config,
            onLog: { _, _ in }
        )

        XCTAssertTrue(capturedArgs.contains("--device"))
        XCTAssertTrue(capturedArgs.contains("mps"))
        XCTAssertTrue(capturedArgs.contains("--max-image-size"))
        XCTAssertTrue(capturedArgs.contains("1600"))
        XCTAssertTrue(capturedArgs.contains("--pairing"))
        XCTAssertTrue(capturedArgs.contains("video"))
        XCTAssertTrue(capturedArgs.contains("--sequential-overlap"))
        XCTAssertTrue(capturedArgs.contains("8"))
        XCTAssertTrue(capturedArgs.contains("--stride"))
        XCTAssertTrue(capturedArgs.contains("2"))
        XCTAssertTrue(capturedArgs.contains("--loop-k"))
        XCTAssertTrue(capturedArgs.contains("3"))
        XCTAssertTrue(capturedArgs.contains("--models-dir"))
        XCTAssertTrue(capturedArgs.contains(toolchain.models.path))
    }
}
#endif
