#if canImport(XCTest)
import Foundation
import XCTest
@testable import EasySplatCore

final class MapAnythingSfmRunnerTests: XCTestCase {
    func testRunBuildsExpectedArgsAndEnvironment() async throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let toolchain = try TestToolchains.mapAnythingToolchain(root: temp, createFiles: true)
        let imagesPath = temp.appendingPathComponent("images", isDirectory: true)
        let outSparse = temp.appendingPathComponent("sparse/0", isDirectory: true)
        let coverageManifest = temp.appendingPathComponent("mapanything_coverage_manifest.json")

        try FileManager.default.createDirectory(at: imagesPath, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outSparse, withIntermediateDirectories: true)

        let config = MapAnythingSfmConfig(
            device: "mps",
            mode: .seedRefine,
            checkpointSubdirectory: "map-anything-apache",
            resolution: 518,
            memoryEfficientInference: true,
            minibatchSize: 1,
            useAMP: false,
            maxPoints: 123_456,
            cameraType: "SIMPLE_RADIAL",
            sharedCamera: true,
            anchorMaxViews: 32,
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

        let runner = MapAnythingSfmRunner(runner: mock)
        try await runner.run(
            toolchain: toolchain,
            images: imagesPath,
            outSparse: outSparse,
            config: config,
            onLog: { _, _ in }
        )

        let capturedArgs = try XCTUnwrap(mock.calls.first?.1)
        XCTAssertEqual(capturedArgs.first, "--images")
        XCTAssertTrue(capturedArgs.contains("--out-sparse"))
        XCTAssertTrue(capturedArgs.contains(outSparse.path))
        XCTAssertTrue(capturedArgs.contains("--models-dir"))
        XCTAssertTrue(capturedArgs.contains(toolchain.models.path))
        XCTAssertTrue(capturedArgs.contains("--mode"))
        XCTAssertTrue(capturedArgs.contains("seed_refine"))
        XCTAssertTrue(capturedArgs.contains("--checkpoint-subdir"))
        XCTAssertTrue(capturedArgs.contains("map-anything-apache"))
        XCTAssertTrue(capturedArgs.contains("--resolution"))
        XCTAssertTrue(capturedArgs.contains("518"))
        XCTAssertTrue(capturedArgs.contains("--memory-efficient-inference"))
        XCTAssertFalse(capturedArgs.contains("--no-memory-efficient-inference"))
        XCTAssertTrue(capturedArgs.contains("--max-points"))
        XCTAssertTrue(capturedArgs.contains("123456"))
        XCTAssertTrue(capturedArgs.contains("--shared-camera"))
        XCTAssertEqual(value(after: "--manifest-out", in: capturedArgs), coverageManifest.path)

        let environment = try XCTUnwrap(mock.environments.first)
        XCTAssertEqual(environment["PYTHONUNBUFFERED"], "1")
        XCTAssertEqual(environment["EASYSPLAT_MAPANYTHING_MODELS_DIR"], toolchain.models.path)
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

    func testRunPassesDisableFlagWhenMemoryEfficientInferenceIsDisabled() async throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let toolchain = try TestToolchains.mapAnythingToolchain(root: temp, createFiles: true)
        let imagesPath = temp.appendingPathComponent("images", isDirectory: true)
        let outSparse = temp.appendingPathComponent("sparse/0", isDirectory: true)

        try FileManager.default.createDirectory(at: imagesPath, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outSparse, withIntermediateDirectories: true)

        let config = MapAnythingSfmConfig(
            device: "mps",
            mode: .direct,
            memoryEfficientInference: false,
            useAMP: false,
            sharedCamera: false,
            anchorMaxViews: 6,
            windowSize: 6,
            windowOverlap: 0
        )

        let mock = MockSubprocessRunner(scripts: [
            .init(
                path: toolchain.sfmTool.path,
                argsPrefix: ["--images", imagesPath.path],
                result: .init(exitCode: 0, terminationReason: .exit, stdout: "", stderr: ""),
                onRun: nil
            )
        ])

        let runner = MapAnythingSfmRunner(runner: mock)
        try await runner.run(
            toolchain: toolchain,
            images: imagesPath,
            outSparse: outSparse,
            config: config,
            onLog: { _, _ in }
        )

        let capturedArgs = try XCTUnwrap(mock.calls.first?.1)
        XCTAssertFalse(capturedArgs.contains("--memory-efficient-inference"))
        XCTAssertTrue(capturedArgs.contains("--no-memory-efficient-inference"))
        XCTAssertFalse(capturedArgs.contains("--use-amp"))
        XCTAssertFalse(capturedArgs.contains("--shared-camera"))
        XCTAssertFalse(capturedArgs.contains("--manifest-out"))
    }

    private func value(after flag: String, in args: [String]) -> String? {
        guard let index = args.firstIndex(of: flag), args.indices.contains(index + 1) else {
            return nil
        }
        return args[index + 1]
    }
}
#endif
