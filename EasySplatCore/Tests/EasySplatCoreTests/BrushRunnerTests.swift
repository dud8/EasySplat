import XCTest
@testable import EasySplatCore

final class BrushRunnerTests: XCTestCase {
    func testRunTrainFailsWhenBrushNotExecutable() async {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let brush = root.appendingPathComponent("brush")
        TestFileBuilder.createFile(at: brush, data: Data([0x00]))
        let dataset = root.appendingPathComponent("dataset", isDirectory: true)
        try? FileManager.default.createDirectory(at: dataset, withIntermediateDirectories: true)

        let runner = BrushRunner(runner: MockSubprocessRunner(scripts: []))
        do {
            try await runner.runTrain(brushPath: brush, datasetPath: dataset, onLog: { _, _ in })
            XCTFail("Expected failure")
        } catch let error as SubprocessFailure {
            XCTAssertTrue(error.stderrTail.contains("not executable"))
        } catch {
            XCTFail("Unexpected error")
        }
    }

    func testRunTrainFailsWhenDatasetMissing() async {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let brush = root.appendingPathComponent("brush")
        try? TestFileBuilder.createExecutable(at: brush)
        let dataset = root.appendingPathComponent("missing", isDirectory: true)

        let runner = BrushRunner(runner: MockSubprocessRunner(scripts: []))
        do {
            try await runner.runTrain(brushPath: brush, datasetPath: dataset, onLog: { _, _ in })
            XCTFail("Expected failure")
        } catch let error as SubprocessFailure {
            XCTAssertTrue(error.stderrTail.contains("Dataset path does not exist"))
        } catch {
            XCTFail("Unexpected error")
        }
    }

    func testRunTrainRetriesLegacySubcommand() async throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let brush = root.appendingPathComponent("brush")
        try TestFileBuilder.createExecutable(at: brush)
        let dataset = root.appendingPathComponent("dataset", isDirectory: true)
        try FileManager.default.createDirectory(at: dataset, withIntermediateDirectories: true)

        var calls: [[String]] = []
        let mock = MockSubprocessRunner(scripts: [
            .init(path: brush.path, argsPrefix: [dataset.path], result: .init(exitCode: 1, terminationReason: .exit, stdout: "", stderr: "unrecognized subcommand"), onRun: { args in
                calls.append(args)
            }),
            .init(path: brush.path, argsPrefix: ["train", dataset.path], result: .init(exitCode: 0, terminationReason: .exit, stdout: "", stderr: ""), onRun: { args in
                calls.append(args)
            })
        ])

        let runner = BrushRunner(runner: mock)
        try await runner.runTrain(brushPath: brush, datasetPath: dataset, onLog: { _, _ in })

        XCTAssertEqual(calls.count, 2)
        XCTAssertEqual(calls[1].first, "train")
    }

    func testRunTrainHonorsEnvOverrides() async throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let brush = root.appendingPathComponent("brush")
        try TestFileBuilder.createExecutable(at: brush)
        let dataset = root.appendingPathComponent("dataset", isDirectory: true)
        try FileManager.default.createDirectory(at: dataset, withIntermediateDirectories: true)

        setenv("EASYSPLAT_BRUSH_TOTAL_STEPS", "100", 1)
        setenv("EASYSPLAT_BRUSH_EXPORT_EVERY", "10", 1)
        defer {
            unsetenv("EASYSPLAT_BRUSH_TOTAL_STEPS")
            unsetenv("EASYSPLAT_BRUSH_EXPORT_EVERY")
        }

        var captured: [String] = []
        let mock = MockSubprocessRunner(scripts: [
            .init(path: brush.path, argsPrefix: ["--total-steps", "100", "--export-every", "10", dataset.path], result: .init(exitCode: 0, terminationReason: .exit, stdout: "", stderr: ""), onRun: { args in
                captured = args
            })
        ])

        let runner = BrushRunner(runner: mock)
        try await runner.runTrain(brushPath: brush, datasetPath: dataset, onLog: { _, _ in })

        XCTAssertTrue(captured.contains("--total-steps"))
        XCTAssertTrue(captured.contains("--export-every"))
    }
}
