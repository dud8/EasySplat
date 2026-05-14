import XCTest
@testable import EasySplatCore

final class MsplatRunnerTests: XCTestCase {
    func testRunTrainFailsWhenMsplatNotExecutable() async throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let msplat = root.appendingPathComponent("msplat-train")
        TestFileBuilder.createFile(at: msplat, data: Data([0x00]))
        let dataset = root.appendingPathComponent("dataset", isDirectory: true)
        try FileManager.default.createDirectory(at: dataset, withIntermediateDirectories: true)
        let output = root.appendingPathComponent("out/splat.ply")

        let runner = MsplatRunner(runner: MockSubprocessRunner(scripts: []))
        do {
            try await runner.runTrain(msplatPath: msplat, datasetPath: dataset, outputPath: output, onLog: { _, _ in })
            XCTFail("Expected failure")
        } catch let error as SubprocessFailure {
            XCTAssertTrue(error.stderrTail.contains("not executable"))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testRunTrainFailsWhenDatasetMissing() async throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let msplat = root.appendingPathComponent("msplat-train")
        try TestFileBuilder.createExecutable(at: msplat)
        let output = root.appendingPathComponent("out/splat.ply")

        let runner = MsplatRunner(runner: MockSubprocessRunner(scripts: []))
        do {
            try await runner.runTrain(
                msplatPath: msplat,
                datasetPath: root.appendingPathComponent("missing", isDirectory: true),
                outputPath: output,
                onLog: { _, _ in }
            )
            XCTFail("Expected failure")
        } catch let error as SubprocessFailure {
            XCTAssertTrue(error.stderrTail.contains("Dataset path does not exist"))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testRunTrainUsesExplicitSettingsAndCreatesOutputDirectory() async throws {
        let restore = await scopedEnvironment([
            "EASYSPLAT_MSPLAT_ITERS": nil,
            "EASYSPLAT_MSPLAT_NUM_DOWNSCALES": nil,
            "EASYSPLAT_MSPLAT_DOWNSCALE_FACTOR": nil
        ])
        defer { restore() }

        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let msplat = root.appendingPathComponent("msplat-train")
        try TestFileBuilder.createExecutable(at: msplat)
        let dataset = root.appendingPathComponent("dataset", isDirectory: true)
        try FileManager.default.createDirectory(at: dataset, withIntermediateDirectories: true)
        let output = root.appendingPathComponent("nested/out/splat.ply")

        let mock = MockSubprocessRunner(scripts: [
            .init(
                path: msplat.path,
                argsPrefix: [
                    "--input", dataset.path,
                    "--output", output.path,
                    "--num-iters", "7000",
                    "--num-downscales", "0",
                    "--downscale-factor", "1.0"
                ],
                result: .init(exitCode: 0, terminationReason: .exit, stdout: "", stderr: ""),
                onRun: nil
            )
        ])

        let runner = MsplatRunner(runner: mock)
        try await runner.runTrain(
            msplatPath: msplat,
            datasetPath: dataset,
            outputPath: output,
            iterations: 7_000,
            numDownscales: 0,
            downscaleFactor: 1.0,
            onLog: { _, _ in }
        )

        XCTAssertTrue(FileManager.default.fileExists(atPath: output.deletingLastPathComponent().path))
    }

    func testRunTrainHonorsEnvOverrides() async throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let msplat = root.appendingPathComponent("msplat-train")
        try TestFileBuilder.createExecutable(at: msplat)
        let dataset = root.appendingPathComponent("dataset", isDirectory: true)
        try FileManager.default.createDirectory(at: dataset, withIntermediateDirectories: true)
        let output = root.appendingPathComponent("out/splat.ply")

        try await withEnvironmentAsync([
            "EASYSPLAT_MSPLAT_ITERS": "1200",
            "EASYSPLAT_MSPLAT_NUM_DOWNSCALES": "2",
            "EASYSPLAT_MSPLAT_DOWNSCALE_FACTOR": "1.5"
        ]) {
            let mock = MockSubprocessRunner(scripts: [
                .init(
                    path: msplat.path,
                    argsPrefix: [
                        "--input", dataset.path,
                        "--output", output.path,
                        "--num-iters", "1200",
                        "--num-downscales", "2",
                        "--downscale-factor", "1.5"
                    ],
                    result: .init(exitCode: 0, terminationReason: .exit, stdout: "", stderr: ""),
                    onRun: nil
                )
            ])

            let runner = MsplatRunner(runner: mock)
            try await runner.runTrain(msplatPath: msplat, datasetPath: dataset, outputPath: output, onLog: { _, _ in })
        }
    }

    func testRunTrainThrowsSubprocessFailureOnNonZeroExit() async throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let msplat = root.appendingPathComponent("msplat-train")
        try TestFileBuilder.createExecutable(at: msplat)
        let dataset = root.appendingPathComponent("dataset", isDirectory: true)
        try FileManager.default.createDirectory(at: dataset, withIntermediateDirectories: true)
        let output = root.appendingPathComponent("out/splat.ply")

        let mock = MockSubprocessRunner(scripts: [
            .init(
                path: msplat.path,
                argsPrefix: ["--input", dataset.path],
                result: .init(exitCode: 2, terminationReason: .exit, stdout: "stdout", stderr: "bad scene"),
                onRun: nil
            )
        ])

        let runner = MsplatRunner(runner: mock)
        do {
            try await runner.runTrain(msplatPath: msplat, datasetPath: dataset, outputPath: output, onLog: { _, _ in })
            XCTFail("Expected failure")
        } catch let error as SubprocessFailure {
            XCTAssertEqual(error.exitCode, 2)
            XCTAssertTrue(error.stderrTail.contains("bad scene"))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }
}
