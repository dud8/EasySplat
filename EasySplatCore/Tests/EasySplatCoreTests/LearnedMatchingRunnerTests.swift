import XCTest
@testable import EasySplatCore

final class LearnedMatchingRunnerTests: XCTestCase {
    func testRunFailsWhenToolMissing() async {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let toolchain = LearnedSfmToolchain(
            root: root,
            matchTool: root.appendingPathComponent("bin/easysplat_match"),
            python: root.appendingPathComponent("python/bin/python3"),
            models: root.appendingPathComponent("models", isDirectory: true)
        )
        let runner = LearnedMatchingRunner(runner: MockSubprocessRunner(scripts: []))
        do {
            try await runner.run(
                toolchain: toolchain,
                images: root,
                outDatabase: root.appendingPathComponent("db"),
                outFeatures: root.appendingPathComponent("features"),
                outMatchList: root.appendingPathComponent("matches.txt"),
                config: LearnedMatchingConfig(device: "mps", maxImageSize: 512, sequentialOverlap: 5, stride: 1, loopK: 1, pairing: "sequential", cameraModel: "SIMPLE_RADIAL"),
                onLog: { _, _ in }
            )
            XCTFail("Expected missingTool error")
        } catch let error as LearnedMatchingError {
            guard case .missingTool = error else { return XCTFail("Expected missingTool") }
        } catch {
            XCTFail("Unexpected error")
        }
    }

    func testRunFailsWhenModelsMissing() async throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let matchTool = root.appendingPathComponent("bin/easysplat_match")
        try TestFileBuilder.createExecutable(at: matchTool)
        let toolchain = LearnedSfmToolchain(
            root: root,
            matchTool: matchTool,
            python: root.appendingPathComponent("python/bin/python3"),
            models: root.appendingPathComponent("models", isDirectory: true)
        )
        let runner = LearnedMatchingRunner(runner: MockSubprocessRunner(scripts: []))
        do {
            try await runner.run(
                toolchain: toolchain,
                images: root,
                outDatabase: root.appendingPathComponent("db"),
                outFeatures: root.appendingPathComponent("features"),
                outMatchList: root.appendingPathComponent("matches.txt"),
                config: LearnedMatchingConfig(device: "mps", maxImageSize: 512, sequentialOverlap: 5, stride: 1, loopK: 1, pairing: "sequential", cameraModel: "SIMPLE_RADIAL"),
                onLog: { _, _ in }
            )
            XCTFail("Expected missingModels error")
        } catch let error as LearnedMatchingError {
            guard case .missingModels = error else { return XCTFail("Expected missingModels") }
        } catch {
            XCTFail("Unexpected error")
        }
    }

    func testRunBuildsArgsWithPairsFile() async throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let matchTool = root.appendingPathComponent("bin/easysplat_match")
        try TestFileBuilder.createExecutable(at: matchTool)
        let models = root.appendingPathComponent("models", isDirectory: true)
        try FileManager.default.createDirectory(at: models, withIntermediateDirectories: true)
        let toolchain = LearnedSfmToolchain(
            root: root,
            matchTool: matchTool,
            python: root.appendingPathComponent("python/bin/python3"),
            models: models
        )

        let pairsFile = root.appendingPathComponent("pairs.txt")
        TestFileBuilder.createFile(at: pairsFile, data: Data([0x00]))

        var captured: [String] = []
        let mock = MockSubprocessRunner(scripts: [
            .init(path: matchTool.path, argsPrefix: ["--images"], result: .init(exitCode: 0, terminationReason: .exit, stdout: "", stderr: ""), onRun: { args in
                captured = args
            })
        ])

        let runner = LearnedMatchingRunner(runner: mock)
        try await runner.run(
            toolchain: toolchain,
            images: root,
            outDatabase: root.appendingPathComponent("db"),
            outFeatures: root.appendingPathComponent("features"),
            outMatchList: root.appendingPathComponent("matches.txt"),
            config: LearnedMatchingConfig(
                device: "mps",
                maxImageSize: 512,
                sequentialOverlap: 5,
                stride: 1,
                loopK: 1,
                pairing: "sequential",
                cameraModel: "SIMPLE_RADIAL",
                requireDevice: true,
                offline: false,
                pairsFile: pairsFile
            ),
            onLog: { _, _ in }
        )

        XCTAssertTrue(captured.contains("--pairs"))
        XCTAssertTrue(captured.contains(pairsFile.path))
        XCTAssertTrue(captured.contains("--require-device"))
        XCTAssertFalse(captured.contains("--offline"))
    }
}
