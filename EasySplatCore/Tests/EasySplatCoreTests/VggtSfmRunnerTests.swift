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
            maxPoints: 123_456,
            useBundleAdjustment: true,
            maxReprojectionError: 7.5,
            sharedCamera: true,
            cameraType: "SIMPLE_PINHOLE",
            visibilityThreshold: 0.25,
            queryFrameCount: 10,
            maxQueryPoints: 2048,
            fineTracking: true,
            keypointExtractor: "aliked+sp",
            bundleAdjustmentMaxFrames: 48
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
        XCTAssertTrue(capturedArgs.contains("--use-ba"))
        XCTAssertTrue(capturedArgs.contains("--max-reproj-error"))
        XCTAssertTrue(capturedArgs.contains("7.5"))
        XCTAssertTrue(capturedArgs.contains("--shared-camera"))
        XCTAssertTrue(capturedArgs.contains("--camera-type"))
        XCTAssertTrue(capturedArgs.contains("SIMPLE_PINHOLE"))
        XCTAssertTrue(capturedArgs.contains("--vis-thresh"))
        XCTAssertTrue(capturedArgs.contains("0.25"))
        XCTAssertTrue(capturedArgs.contains("--query-frame-num"))
        XCTAssertTrue(capturedArgs.contains("10"))
        XCTAssertTrue(capturedArgs.contains("--max-query-pts"))
        XCTAssertTrue(capturedArgs.contains("2048"))
        XCTAssertTrue(capturedArgs.contains("--fine-tracking"))
        XCTAssertTrue(capturedArgs.contains("--keypoint-extractor"))
        XCTAssertTrue(capturedArgs.contains("aliked+sp"))
        XCTAssertTrue(capturedArgs.contains("--ba-max-frames"))
        XCTAssertTrue(capturedArgs.contains("48"))
    }

    func testRunOmitsBundleAdjustmentWhenDisabled() async throws {
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
            maxPoints: 100_000,
            useBundleAdjustment: false,
            fineTracking: false
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

        XCTAssertFalse(capturedArgs.contains("--use-ba"))
        XCTAssertTrue(capturedArgs.contains("--no-fine-tracking"))
    }
}
#endif
