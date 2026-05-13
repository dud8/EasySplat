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
        let restore = await scopedEnvironment([
            "EASYSPLAT_BRUSH_TOTAL_STEPS": nil,
            "EASYSPLAT_BRUSH_EXPORT_EVERY": nil
        ])
        defer { restore() }

        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let brush = root.appendingPathComponent("brush")
        try TestFileBuilder.createExecutable(at: brush)
        let dataset = root.appendingPathComponent("dataset", isDirectory: true)
        try FileManager.default.createDirectory(at: dataset, withIntermediateDirectories: true)

        var calls: [[String]] = []
        let mock = MockSubprocessRunner(scripts: [
            .init(path: brush.path, argsPrefix: ["--total-steps", "200", "--export-every", "20", dataset.path], result: .init(exitCode: 1, terminationReason: .exit, stdout: "", stderr: "unrecognized subcommand"), onRun: { args in
                calls.append(args)
            }),
            .init(path: brush.path, argsPrefix: ["train", "--total-steps", "200", "--export-every", "20", dataset.path], result: .init(exitCode: 0, terminationReason: .exit, stdout: "", stderr: ""), onRun: { args in
                calls.append(args)
            })
        ])

        let runner = BrushRunner(runner: mock)
        try await runner.runTrain(
            brushPath: brush,
            datasetPath: dataset,
            totalSteps: 200,
            exportEvery: 20,
            onLog: { _, _ in }
        )

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

        var captured: [String] = []
        try await withEnvironmentAsync([
            "EASYSPLAT_BRUSH_TOTAL_STEPS": "100",
            "EASYSPLAT_BRUSH_EXPORT_EVERY": "10"
        ]) {
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

    func testRunTrainUsesExplicitSettingsWhenEnvMissing() async throws {
        let restore = await scopedEnvironment([
            "EASYSPLAT_BRUSH_TOTAL_STEPS": nil,
            "EASYSPLAT_BRUSH_EXPORT_EVERY": nil
        ])
        defer { restore() }

        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let brush = root.appendingPathComponent("brush")
        try TestFileBuilder.createExecutable(at: brush)
        let dataset = root.appendingPathComponent("dataset", isDirectory: true)
        try FileManager.default.createDirectory(at: dataset, withIntermediateDirectories: true)

        var captured: [String] = []
        let mock = MockSubprocessRunner(scripts: [
            .init(path: brush.path, argsPrefix: ["--total-steps", "150", "--export-every", "25", dataset.path], result: .init(exitCode: 0, terminationReason: .exit, stdout: "", stderr: ""), onRun: { args in
                captured = args
            })
        ])

        let runner = BrushRunner(runner: mock)
        try await runner.runTrain(
            brushPath: brush,
            datasetPath: dataset,
            totalSteps: 150,
            exportEvery: 25,
            onLog: { _, _ in }
        )

        XCTAssertTrue(captured.contains("--total-steps"))
        XCTAssertTrue(captured.contains("--export-every"))
    }

    func testFindLatestExportablePlyIgnoresCompressedAndSnapshotFiles() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let exportOld = root.appendingPathComponent("export_00010.ply")
        let compressedNew = root.appendingPathComponent("export_99999.compressed.ply")
        let snapshotNew = root.appendingPathComponent("latest_snapshot.ply")
        try TestFileBuilder.writeMinimalPly(at: exportOld)
        try TestFileBuilder.writeMinimalPly(at: compressedNew)
        try TestFileBuilder.writeMinimalPly(at: snapshotNew)
        let now = Date()
        try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-100)], ofItemAtPath: exportOld.path)
        try FileManager.default.setAttributes([.modificationDate: now], ofItemAtPath: compressedNew.path)
        try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(100)], ofItemAtPath: snapshotNew.path)

        let runner = BrushRunner(runner: MockSubprocessRunner(scripts: []))

        XCTAssertEqual(
            runner.findLatestExportablePly(in: root)?.standardizedFileURL,
            exportOld.standardizedFileURL
        )
    }

    func testFindLatestExportablePlyHonorsCurrentRunCutoff() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let historical = root.appendingPathComponent("export_35000.ply")
        let current = root.appendingPathComponent("export_00010.ply")
        try TestFileBuilder.writeMinimalPly(at: historical)
        try TestFileBuilder.writeMinimalPly(at: current)
        let base = Date().addingTimeInterval(-600)
        try FileManager.default.setAttributes([.modificationDate: base], ofItemAtPath: historical.path)
        try FileManager.default.setAttributes([.modificationDate: base.addingTimeInterval(300)], ofItemAtPath: current.path)

        let runner = BrushRunner(runner: MockSubprocessRunner(scripts: []))

        XCTAssertEqual(
            runner.findLatestExportablePly(in: root, minModificationDate: base.addingTimeInterval(120))?.standardizedFileURL,
            current.standardizedFileURL
        )
        XCTAssertNil(runner.findLatestExportablePly(in: root, minModificationDate: Date()))
    }

    func testFindLatestExportablePlyBreaksModificationTimeTieByExportStep() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let lowerStep = root.appendingPathComponent("export_00010.ply")
        let higherStep = root.appendingPathComponent("export_00020.ply")
        try TestFileBuilder.writeMinimalPly(at: lowerStep)
        try TestFileBuilder.writeMinimalPly(at: higherStep)
        let tiedDate = Date(timeIntervalSince1970: 1_700_000_000)
        try FileManager.default.setAttributes([.modificationDate: tiedDate], ofItemAtPath: lowerStep.path)
        try FileManager.default.setAttributes([.modificationDate: tiedDate], ofItemAtPath: higherStep.path)

        let runner = BrushRunner(runner: MockSubprocessRunner(scripts: []))

        XCTAssertEqual(
            runner.findLatestExportablePly(in: root)?.standardizedFileURL,
            higherStep.standardizedFileURL
        )
    }
}
