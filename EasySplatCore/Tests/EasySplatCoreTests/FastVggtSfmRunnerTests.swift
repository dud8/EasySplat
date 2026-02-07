#if canImport(XCTest)
import Foundation
import XCTest
@testable import EasySplatCore

final class FastVggtSfmRunnerTests: XCTestCase {
    func testRunBuildsExpectedArgs() async throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let toolchain = try TestToolchains.fastVggtToolchain(root: temp, createFiles: true)
        let imagesPath = temp.appendingPathComponent("images", isDirectory: true)
        let outSparse = temp.appendingPathComponent("sparse/0", isDirectory: true)

        try FileManager.default.createDirectory(at: imagesPath, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outSparse, withIntermediateDirectories: true)

        let config = FastVggtSfmConfig(
            device: "mps",
            dtype: "auto",
            vggtFixedResolution: 518,
            confidenceThreshold: 3.0,
            maxPoints: 111_111,
            merging: 2,
            mergeRatio: 0.85,
            sharedCamera: true,
            cameraType: "SIMPLE_PINHOLE"
        )

        var capturedArgs: [String] = []
        let mock = MockSubprocessRunner(scripts: [
            .init(path: toolchain.sfmTool.path, argsPrefix: ["--images", imagesPath.path], result: .init(exitCode: 0, terminationReason: .exit, stdout: "", stderr: ""), onRun: { args in
                capturedArgs = args
            })
        ])

        let runner = FastVggtSfmRunner(runner: mock)
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
        XCTAssertTrue(capturedArgs.contains("--dtype"))
        XCTAssertTrue(capturedArgs.contains("auto"))
        XCTAssertTrue(capturedArgs.contains("--vggt-resolution"))
        XCTAssertTrue(capturedArgs.contains("518"))
        XCTAssertTrue(capturedArgs.contains("--conf-thres"))
        XCTAssertTrue(capturedArgs.contains("3.0"))
        XCTAssertTrue(capturedArgs.contains("--max-points"))
        XCTAssertTrue(capturedArgs.contains("111111"))
        XCTAssertTrue(capturedArgs.contains("--models-dir"))
        XCTAssertTrue(capturedArgs.contains(toolchain.models.path))
        XCTAssertTrue(capturedArgs.contains("--merging"))
        XCTAssertTrue(capturedArgs.contains("2"))
        XCTAssertTrue(capturedArgs.contains("--merge-ratio"))
        XCTAssertTrue(capturedArgs.contains("0.85"))
        XCTAssertTrue(capturedArgs.contains("--shared-camera"))
        XCTAssertTrue(capturedArgs.contains("--camera-type"))
        XCTAssertTrue(capturedArgs.contains("SIMPLE_PINHOLE"))
        XCTAssertFalse(capturedArgs.contains("--track-mode"))
        XCTAssertFalse(capturedArgs.contains("--no-track-mode"))
        XCTAssertFalse(capturedArgs.contains("--use-ba"))
        XCTAssertFalse(capturedArgs.contains("--no-use-ba"))
        XCTAssertFalse(capturedArgs.contains("--require-refined-model"))
        XCTAssertFalse(capturedArgs.contains("--allow-feedforward-fallback"))
        XCTAssertFalse(capturedArgs.contains("--ba-max-iterations"))
        XCTAssertFalse(capturedArgs.contains("--ba-refine-focal"))
        XCTAssertFalse(capturedArgs.contains("--ba-refine-principal-point"))
        XCTAssertFalse(capturedArgs.contains("--ba-refine-extra-params"))
        XCTAssertFalse(capturedArgs.contains("--refinement-policy"))
        XCTAssertFalse(capturedArgs.contains("--watchdog-seconds"))
        XCTAssertFalse(capturedArgs.contains("--max-tracks-profile"))
        XCTAssertFalse(capturedArgs.contains("--allow-track-only-degrade"))
        XCTAssertFalse(capturedArgs.contains("--require-ba-success"))
    }

    func testRunOmitsSharedCameraWhenDisabled() async throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let toolchain = try TestToolchains.fastVggtToolchain(root: temp, createFiles: true)
        let imagesPath = temp.appendingPathComponent("images", isDirectory: true)
        let outSparse = temp.appendingPathComponent("sparse/0", isDirectory: true)

        try FileManager.default.createDirectory(at: imagesPath, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outSparse, withIntermediateDirectories: true)

        let config = FastVggtSfmConfig(
            device: "mps",
            dtype: "auto",
            vggtFixedResolution: 518,
            confidenceThreshold: 3.0,
            maxPoints: 100_000,
            merging: 0,
            mergeRatio: 0.9,
            sharedCamera: false,
            cameraType: "SIMPLE_PINHOLE"
        )

        var capturedArgs: [String] = []
        let mock = MockSubprocessRunner(scripts: [
            .init(path: toolchain.sfmTool.path, argsPrefix: ["--images", imagesPath.path], result: .init(exitCode: 0, terminationReason: .exit, stdout: "", stderr: ""), onRun: { args in
                capturedArgs = args
            })
        ])

        let runner = FastVggtSfmRunner(runner: mock)
        try await runner.run(
            toolchain: toolchain,
            images: imagesPath,
            outSparse: outSparse,
            config: config,
            onLog: { _, _ in }
        )

        XCTAssertFalse(capturedArgs.contains("--shared-camera"))
    }
}
#endif
