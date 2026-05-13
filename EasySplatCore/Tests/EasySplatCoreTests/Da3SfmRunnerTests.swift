#if canImport(XCTest)
import Foundation
import XCTest
@testable import EasySplatCore

final class Da3SfmRunnerTests: XCTestCase {
    func testRunBuildsExpectedArgsAndEnvironment() async throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temp) }
        let toolchain = try TestToolchains.da3Toolchain(root: temp, createFiles: true)
        let imagesPath = temp.appendingPathComponent("images", isDirectory: true)
        let outSparse = temp.appendingPathComponent("sparse/0", isDirectory: true)
        let coverageManifest = temp.appendingPathComponent("da3_coverage_manifest.json")

        try FileManager.default.createDirectory(at: imagesPath, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outSparse, withIntermediateDirectories: true)

        let config = Da3SfmConfig(
            device: "mps",
            mode: .direct,
            modelSubdirectory: "DA3-BASE",
            fallbackModelSubdirectory: "DA3-SMALL",
            processResolution: 504,
            maxPoints: 123_456,
            cameraType: "PINHOLE",
            sharedCamera: true,
            windowSize: 6,
            windowOverlap: 2,
            coverageManifestPath: coverageManifest
        )

        let mock = MockSubprocessRunner(scripts: [
            .init(
                path: toolchain.sfmTool.path,
                argsPrefix: ["--images", imagesPath.path],
                result: .init(exitCode: 0, terminationReason: .exit, stdout: "", stderr: ""),
                onRun: nil
            )
        ])

        let runner = Da3SfmRunner(runner: mock)
        try await runner.run(
            toolchain: toolchain,
            images: imagesPath,
            outSparse: outSparse,
            config: config,
            onLog: { _, _ in }
        )

        let capturedArgs = try XCTUnwrap(mock.calls.first?.1)
        XCTAssertEqual(capturedArgs.first, "--images")
        XCTAssertEqual(value(after: "--out-sparse", in: capturedArgs), outSparse.path)
        XCTAssertEqual(value(after: "--models-dir", in: capturedArgs), toolchain.models.path)
        XCTAssertEqual(value(after: "--mode", in: capturedArgs), "direct")
        XCTAssertEqual(value(after: "--model-subdir", in: capturedArgs), "DA3-BASE")
        XCTAssertEqual(value(after: "--fallback-model-subdir", in: capturedArgs), "DA3-SMALL")
        XCTAssertEqual(value(after: "--process-res", in: capturedArgs), "504")
        XCTAssertEqual(value(after: "--max-points", in: capturedArgs), "123456")
        XCTAssertEqual(value(after: "--camera-type", in: capturedArgs), "PINHOLE")
        XCTAssertTrue(capturedArgs.contains("--shared-camera"))
        XCTAssertEqual(value(after: "--manifest-out", in: capturedArgs), coverageManifest.path)

        let environment = try XCTUnwrap(mock.environments.first)
        XCTAssertEqual(environment["PYTHONUNBUFFERED"], "1")
        XCTAssertEqual(environment["EASYSPLAT_DA3_MODELS_DIR"], toolchain.models.path)
        XCTAssertEqual(environment["TORCH_HOME"], toolchain.models.path)
        XCTAssertEqual(environment["HF_HOME"], toolchain.models.appendingPathComponent("huggingface", isDirectory: true).path)
        XCTAssertEqual(environment["HF_HUB_OFFLINE"], "1")
        XCTAssertEqual(environment["TRANSFORMERS_OFFLINE"], "1")
        XCTAssertEqual(environment["HF_HUB_DISABLE_TELEMETRY"], "1")
        XCTAssertEqual(environment["DO_NOT_TRACK"], "1")
        XCTAssertEqual(environment["TOKENIZERS_PARALLELISM"], "false")
        XCTAssertNotNil(environment["PYTORCH_ENABLE_MPS_FALLBACK"])
        XCTAssertTrue(environment["PATH"]?.contains(toolchain.python.deletingLastPathComponent().path) == true)
    }

    func testRunRejectsSeedRefineUntilSupported() async throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temp) }
        let toolchain = try TestToolchains.da3Toolchain(root: temp, createFiles: true)
        let imagesPath = temp.appendingPathComponent("images", isDirectory: true)
        let outSparse = temp.appendingPathComponent("sparse/0", isDirectory: true)
        let coverageManifest = temp.appendingPathComponent("da3_coverage_manifest.json")
        try FileManager.default.createDirectory(at: imagesPath, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outSparse, withIntermediateDirectories: true)

        let config = Da3SfmConfig(
            device: "mps",
            mode: .seedRefine,
            modelSubdirectory: "DA3-BASE",
            fallbackModelSubdirectory: "DA3-SMALL",
            processResolution: 504,
            maxPoints: 123_456,
            cameraType: "PINHOLE",
            sharedCamera: true,
            windowSize: 6,
            windowOverlap: 2,
            coverageManifestPath: coverageManifest
        )

        let mock = MockSubprocessRunner(scripts: [])
        let runner = Da3SfmRunner(runner: mock)

        do {
            try await runner.run(
                toolchain: toolchain,
                images: imagesPath,
                outSparse: outSparse,
                config: config,
                onLog: { _, _ in }
            )
            XCTFail("Expected unsupported mode")
        } catch Da3SfmError.unsupportedMode(let mode) {
            XCTAssertEqual(mode, "seed_refine")
            XCTAssertTrue(mock.calls.isEmpty)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    private func value(after flag: String, in args: [String]) -> String? {
        guard let index = args.firstIndex(of: flag), args.indices.contains(index + 1) else {
            return nil
        }
        return args[index + 1]
    }
}
#endif
