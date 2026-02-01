#if canImport(XCTest)
import Foundation
import XCTest
@testable import EasySplatCore

final class VggtSfmRunnerTests: XCTestCase {
    func testRunBuildsExpectedArgs() async throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let toolchain = try TestToolchains.vggtToolchain(root: temp, createFiles: true)
        let imagesPath = temp.appendingPathComponent("images", isDirectory: true)
        let outSparse = temp.appendingPathComponent("sparse/0", isDirectory: true)

        try FileManager.default.createDirectory(at: imagesPath, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outSparse, withIntermediateDirectories: true)

        let config = VggtSfmConfig(
            device: "mps",
            imageLoadResolution: 1024,
            vggtFixedResolution: 518,
            confidenceThreshold: 5.0,
            maxPoints: 123_456
        )

        var capturedArgs: [String] = []
        let mock = MockSubprocessRunner(scripts: [
            .init(path: toolchain.sfmTool.path, argsPrefix: ["--images", imagesPath.path], result: .init(exitCode: 0, terminationReason: .exit, stdout: "", stderr: ""), onRun: { args in
                capturedArgs = args
            })
        ])

        let runner = VggtSfmRunner(runner: mock)
        try await runner.run(
            toolchain: toolchain,
            images: imagesPath,
            outSparse: outSparse,
            config: config,
            onLog: { _, _ in }
        )

        XCTAssertEqual(capturedArgs.first, "--images")
        XCTAssertTrue(capturedArgs.contains("--out-sparse"))
        XCTAssertTrue(capturedArgs.contains(outSparse.path))
        XCTAssertTrue(capturedArgs.contains("--device"))
        XCTAssertTrue(capturedArgs.contains("mps"))
        XCTAssertTrue(capturedArgs.contains("--img-load-resolution"))
        XCTAssertTrue(capturedArgs.contains("1024"))
        XCTAssertTrue(capturedArgs.contains("--vggt-resolution"))
        XCTAssertTrue(capturedArgs.contains("518"))
        XCTAssertTrue(capturedArgs.contains("--conf-thres"))
        XCTAssertTrue(capturedArgs.contains("5.0"))
        XCTAssertTrue(capturedArgs.contains("--max-points"))
        XCTAssertTrue(capturedArgs.contains("123456"))
        XCTAssertTrue(capturedArgs.contains("--models-dir"))
        XCTAssertTrue(capturedArgs.contains(toolchain.models.path))
    }
}
#endif

