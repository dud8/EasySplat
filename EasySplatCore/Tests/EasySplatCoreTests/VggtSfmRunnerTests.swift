#if canImport(XCTest)
import Foundation
import XCTest
@testable import EasySplatCore

final class VggtSfmRunnerTests: XCTestCase {
    func testRunBuildsExpectedArgs() async throws {
        let temp = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: temp) }
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

        XCTAssertEqual(value(after: "--images", in: capturedArgs), imagesPath.path)
        XCTAssertEqual(value(after: "--out-sparse", in: capturedArgs), outSparse.path)
        XCTAssertEqual(value(after: "--device", in: capturedArgs), "mps")
        XCTAssertEqual(value(after: "--img-load-resolution", in: capturedArgs), "1024")
        XCTAssertEqual(value(after: "--vggt-resolution", in: capturedArgs), "518")
        XCTAssertEqual(value(after: "--conf-thres", in: capturedArgs), "5.0")
        XCTAssertEqual(value(after: "--max-points", in: capturedArgs), "123456")
        XCTAssertEqual(value(after: "--models-dir", in: capturedArgs), toolchain.models.path)
        XCTAssertEqual(value(after: "--max-reproj-error", in: capturedArgs), "7.5")
        XCTAssertEqual(value(after: "--camera-type", in: capturedArgs), "SIMPLE_PINHOLE")
        XCTAssertEqual(value(after: "--vis-thresh", in: capturedArgs), "0.25")
        XCTAssertEqual(value(after: "--query-frame-num", in: capturedArgs), "10")
        XCTAssertEqual(value(after: "--max-query-pts", in: capturedArgs), "2048")
        XCTAssertEqual(value(after: "--keypoint-extractor", in: capturedArgs), "aliked+sp")
        XCTAssertEqual(value(after: "--ba-max-frames", in: capturedArgs), "48")
        XCTAssertTrue(capturedArgs.contains("--use-ba"))
        XCTAssertTrue(capturedArgs.contains("--shared-camera"))
        XCTAssertTrue(capturedArgs.contains("--fine-tracking"))

        let environment = try XCTUnwrap(mock.environments.first)
        XCTAssertEqual(environment["PYTHONUNBUFFERED"], "1")
        XCTAssertEqual(environment["TORCH_HOME"], toolchain.models.path)
        XCTAssertEqual(environment["EASYSPLAT_VGGT_MODELS_DIR"], toolchain.models.path)
        XCTAssertEqual(environment["HF_HUB_OFFLINE"], "1")
        XCTAssertEqual(environment["TRANSFORMERS_OFFLINE"], "1")
        XCTAssertEqual(environment["HF_HUB_DISABLE_TELEMETRY"], "1")
        XCTAssertEqual(environment["DO_NOT_TRACK"], "1")
        XCTAssertEqual(environment["TOKENIZERS_PARALLELISM"], "false")
        XCTAssertNotNil(environment["PYTORCH_ENABLE_MPS_FALLBACK"])
        XCTAssertTrue(environment["PATH"]?.contains(toolchain.python.deletingLastPathComponent().path) == true)
    }

    func testRunOmitsBundleAdjustmentWhenDisabled() async throws {
        let temp = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: temp) }
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

    func testRunRetriesLegacyArgsWhenBridgeRejectsAdvancedOptions() async throws {
        let temp = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: temp) }
        let toolchain = try TestToolchains.vggtToolchain(root: temp, createFiles: true)
        let imagesPath = temp.appendingPathComponent("images", isDirectory: true)
        let outSparse = temp.appendingPathComponent("sparse/0", isDirectory: true)

        try FileManager.default.createDirectory(at: imagesPath, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outSparse, withIntermediateDirectories: true)

        let mock = MockSubprocessRunner(scripts: [
            .init(
                path: toolchain.sfmTool.path,
                argsPrefix: ["--images", imagesPath.path],
                result: .init(
                    exitCode: 2,
                    terminationReason: .exit,
                    stdout: "",
                    stderr: "run.py: error: unrecognized arguments: --max-reproj-error 8.0 --use-ba"
                ),
                onRun: nil
            ),
            .init(
                path: toolchain.sfmTool.path,
                argsPrefix: ["--images", imagesPath.path],
                result: .init(exitCode: 0, terminationReason: .exit, stdout: "", stderr: ""),
                onRun: nil
            )
        ])

        let runner = VggtSfmRunner(runner: mock)
        try await runner.run(
            toolchain: toolchain,
            images: imagesPath,
            outSparse: outSparse,
            config: VggtSfmConfig(useBundleAdjustment: true),
            onLog: { _, _ in }
        )

        XCTAssertEqual(mock.calls.count, 2)
        XCTAssertTrue(mock.calls[0].1.contains("--max-reproj-error"))
        XCTAssertTrue(mock.calls[0].1.contains("--use-ba"))
        let retryArgs = mock.calls[1].1
        XCTAssertEqual(value(after: "--images", in: retryArgs), imagesPath.path)
        XCTAssertEqual(value(after: "--out-sparse", in: retryArgs), outSparse.path)
        XCTAssertEqual(value(after: "--device", in: retryArgs), "mps")
        XCTAssertEqual(value(after: "--img-load-resolution", in: retryArgs), "1024")
        XCTAssertEqual(value(after: "--vggt-resolution", in: retryArgs), "518")
        XCTAssertEqual(value(after: "--conf-thres", in: retryArgs), "5.0")
        XCTAssertEqual(value(after: "--max-points", in: retryArgs), "100000")
        XCTAssertEqual(value(after: "--models-dir", in: retryArgs), toolchain.models.path)
        XCTAssertFalse(retryArgs.contains("--max-reproj-error"))
        XCTAssertFalse(retryArgs.contains("--use-ba"))
    }

    private func value(after flag: String, in args: [String]) -> String? {
        guard let index = args.firstIndex(of: flag), args.indices.contains(index + 1) else {
            return nil
        }
        return args[index + 1]
    }
}
#endif
