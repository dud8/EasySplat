import XCTest
@testable import EasySplatCore

final class MsplatRunnerTests: XCTestCase {
    func testRunTrainFailsWhenMsplatNotExecutable() async throws {
        let context = try makeContext(executable: false)
        defer { context.cleanup() }

        do {
            _ = try await context.runner.runTrain(
                msplatPath: context.executable,
                datasetPath: context.dataset,
                outputPath: context.output,
                profile: .balanced,
                seed: 42,
                onLog: { _, _ in }
            )
            XCTFail("Expected failure")
        } catch let error as SubprocessFailure {
            XCTAssertTrue(error.stderrTail.contains("not executable"))
        }
    }

    func testRunTrainFailsWhenDatasetMissing() async throws {
        let context = try makeContext()
        defer { context.cleanup() }

        do {
            _ = try await context.runner.runTrain(
                msplatPath: context.executable,
                datasetPath: context.root.appendingPathComponent("missing", isDirectory: true),
                outputPath: context.output,
                profile: .balanced,
                seed: 42,
                onLog: { _, _ in }
            )
            XCTFail("Expected failure")
        } catch let error as SubprocessFailure {
            XCTAssertTrue(error.stderrTail.contains("Dataset path does not exist"))
        }
    }

    func testRunTrainUsesClosedProfileContractsAndReturnsCompletion() async throws {
        for (profile, argument, limit, plateau) in [
            (DetailProfile.fast, "fast", 3_000, 400),
            (.balanced, "balanced", 7_000, 800),
            (.highDetail, "high-detail", 15_000, 1_500),
        ] {
            let context = try makeContext()
            defer { context.cleanup() }
            let stdout = validEvents(
                profile: argument,
                limit: limit,
                plateau: plateau,
                seed: 9
            )
            let mock = MockSubprocessRunner(scripts: [
                .init(
                    path: context.executable.path,
                    argsPrefix: [
                        "--dataset", context.dataset.path,
                        "--output", context.output.path,
                        "--profile", argument,
                        "--seed", "9",
                        "--events-fd", "1",
                    ],
                    result: .init(exitCode: 0, terminationReason: .exit, stdout: stdout, stderr: ""),
                    onRun: { _ in TestFileBuilder.createFile(at: context.output, data: fixtureOutputData) }
                ),
            ])

            let result = try await MsplatRunner(runner: mock).runTrain(
                msplatPath: context.executable,
                datasetPath: context.dataset,
                outputPath: context.output,
                profile: profile,
                seed: 9,
                onLog: { _, _ in }
            )

            XCTAssertEqual(result.profile, profile)
            XCTAssertEqual(result.iterationLimit, limit)
            XCTAssertEqual(result.plateauWindow, plateau)
            XCTAssertEqual(result.completedIteration, limit)
            XCTAssertEqual(result.stopReason, .iterationLimit)
            XCTAssertEqual(result.gaussianCount, 1_250)
            XCTAssertTrue(FileManager.default.fileExists(atPath: context.output.deletingLastPathComponent().path))
        }
    }

    func testRunTrainIgnoresRemovedEnvironmentOverrides() async throws {
        let context = try makeContext()
        defer { context.cleanup() }
        let mock = MockSubprocessRunner(scripts: [
            .init(
                path: context.executable.path,
                argsPrefix: [
                    "--dataset", context.dataset.path,
                    "--output", context.output.path,
                    "--profile", "fast",
                    "--seed", "42",
                    "--events-fd", "1",
                ],
                result: .init(
                    exitCode: 0,
                    terminationReason: .exit,
                    stdout: validEvents(profile: "fast", limit: 3_000, plateau: 400, seed: 42),
                    stderr: ""
                ),
                onRun: { _ in TestFileBuilder.createFile(at: context.output, data: fixtureOutputData) }
            ),
        ])

        try await withEnvironmentAsync([
            "EASYSPLAT_MSPLAT_ITERS": "1",
            "EASYSPLAT_MSPLAT_NUM_DOWNSCALES": "9",
            "EASYSPLAT_MSPLAT_DOWNSCALE_FACTOR": "32",
        ]) {
            _ = try await MsplatRunner(runner: mock).runTrain(
                msplatPath: context.executable,
                datasetPath: context.dataset,
                outputPath: context.output,
                profile: .fast,
                seed: 42,
                onLog: { _, _ in }
            )
        }

        XCTAssertFalse(mock.calls[0].1.contains("--num-iters"))
        XCTAssertFalse(mock.calls[0].1.contains("--num-downscales"))
        XCTAssertFalse(mock.calls[0].1.contains("--downscale-factor"))
    }

    func testRunTrainReportsTypedProgress() async throws {
        let context = try makeContext()
        defer { context.cleanup() }
        let mock = successfulMock(context: context)
        let progress = LockedBox<[MsplatTrainingProgress]>([])

        _ = try await MsplatRunner(runner: mock).runTrain(
            msplatPath: context.executable,
            datasetPath: context.dataset,
            outputPath: context.output,
            profile: .balanced,
            seed: 42,
            onProgress: { update in progress.withValue { $0.append(update) } },
            onLog: { _, _ in }
        )

        XCTAssertEqual(progress.value.map(\.iteration), [3_500])
        XCTAssertEqual(progress.value.first?.iterationLimit, 7_000)
        XCTAssertEqual(progress.value.first?.gaussianCount, 1_000)
        XCTAssertEqual(progress.value.first?.lossIteration, 3_500)
    }

    func testRunTrainAcceptsProgressBeforeFirstLossWindow() async throws {
        let context = try makeContext()
        defer { context.cleanup() }
        let progress = LockedBox<[MsplatTrainingProgress]>([])
        let mock = MockSubprocessRunner(scripts: [
            .init(
                path: context.executable.path,
                argsPrefix: ["--dataset", context.dataset.path],
                result: .init(
                    exitCode: 0,
                    terminationReason: .exit,
                    stdout: validEvents(includeProgressLoss: false),
                    stderr: ""
                ),
                onRun: { _ in TestFileBuilder.createFile(at: context.output, data: fixtureOutputData) }
            ),
        ])

        _ = try await MsplatRunner(runner: mock).runTrain(
            msplatPath: context.executable,
            datasetPath: context.dataset,
            outputPath: context.output,
            profile: .balanced,
            seed: 42,
            onProgress: { update in progress.withValue { $0.append(update) } },
            onLog: { _, _ in }
        )

        XCTAssertNil(progress.value.first?.loss)
        XCTAssertNil(progress.value.first?.lossIteration)
    }

    func testRunTrainRejectsMalformedOrIncompleteEventStreams() async throws {
        let cases: [(String, String)] = [
            ("malformed", "not json\n"),
            ("wrong schema", validEvents().replacingOccurrences(of: "\"schema_version\":1", with: "\"schema_version\":2")),
            ("skipped sequence", validEvents().replacingOccurrences(of: "\"sequence\":2", with: "\"sequence\":4")),
            ("wrong version", validEvents().replacingOccurrences(of: "1.1.3 (git 106499b)", with: "1.1.4 (git deadbee)")),
            ("profile mismatch", validEvents().replacingOccurrences(of: "\"profile\":\"balanced\"", with: "\"profile\":\"fast\"")),
            ("plateau without early stop", validEvents().replacingOccurrences(of: "\"stop_reason\":\"iteration_limit\"", with: "\"stop_reason\":\"plateau\"")),
            ("missing completion", validEvents().split(separator: "\n").dropLast().joined(separator: "\n") + "\n"),
        ]

        for (name, stdout) in cases {
            let context = try makeContext()
            defer { context.cleanup() }
            let mock = MockSubprocessRunner(scripts: [
                .init(
                    path: context.executable.path,
                    argsPrefix: ["--dataset", context.dataset.path],
                    result: .init(exitCode: 0, terminationReason: .exit, stdout: stdout, stderr: ""),
                    onRun: { _ in TestFileBuilder.createFile(at: context.output, data: fixtureOutputData) }
                ),
            ])

            do {
                _ = try await MsplatRunner(runner: mock).runTrain(
                    msplatPath: context.executable,
                    datasetPath: context.dataset,
                    outputPath: context.output,
                    profile: .balanced,
                    seed: 42,
                    onLog: { _, _ in }
                )
                XCTFail("Expected protocol failure for \(name)")
            } catch {
                XCTAssertTrue(error.localizedDescription.lowercased().contains("event"), "\(name): \(error)")
            }
        }
    }

    func testRunTrainRejectsExitZeroWithoutOutput() async throws {
        let context = try makeContext()
        defer { context.cleanup() }
        let mock = MockSubprocessRunner(scripts: [
            .init(
                path: context.executable.path,
                argsPrefix: ["--dataset", context.dataset.path],
                result: .init(exitCode: 0, terminationReason: .exit, stdout: validEvents(), stderr: ""),
                onRun: nil
            ),
        ])

        do {
            _ = try await MsplatRunner(runner: mock).runTrain(
                msplatPath: context.executable,
                datasetPath: context.dataset,
                outputPath: context.output,
                profile: .balanced,
                seed: 42,
                onLog: { _, _ in }
            )
            XCTFail("Expected missing-output failure")
        } catch {
            XCTAssertTrue(error.localizedDescription.lowercased().contains("output"))
        }
    }

    func testRunTrainThrowsSubprocessFailureOnNonZeroExit() async throws {
        let context = try makeContext()
        defer { context.cleanup() }
        let mock = MockSubprocessRunner(scripts: [
            .init(
                path: context.executable.path,
                argsPrefix: ["--dataset", context.dataset.path],
                result: .init(exitCode: 2, terminationReason: .exit, stdout: "", stderr: "bad scene"),
                onRun: nil
            ),
        ])

        do {
            _ = try await MsplatRunner(runner: mock).runTrain(
                msplatPath: context.executable,
                datasetPath: context.dataset,
                outputPath: context.output,
                profile: .balanced,
                seed: 42,
                onLog: { _, _ in }
            )
            XCTFail("Expected failure")
        } catch let error as SubprocessFailure {
            XCTAssertEqual(error.exitCode, 2)
            XCTAssertTrue(error.stderrTail.contains("bad scene"))
        }
    }
}

private struct MsplatTestContext {
    let root: URL
    let executable: URL
    let dataset: URL
    let output: URL
    let runner: MsplatRunner

    func cleanup() {
        try? FileManager.default.removeItem(at: root)
    }
}

private func makeContext(executable: Bool = true) throws -> MsplatTestContext {
    let root = try TestFileBuilder.makeTempDir()
    let binary = root.appendingPathComponent("easysplat-train")
    if executable {
        try TestFileBuilder.createExecutable(at: binary)
    } else {
        TestFileBuilder.createFile(at: binary, data: Data([0x00]))
    }
    let dataset = root.appendingPathComponent("dataset", isDirectory: true)
    try FileManager.default.createDirectory(at: dataset, withIntermediateDirectories: true)
    return MsplatTestContext(
        root: root,
        executable: binary,
        dataset: dataset,
        output: root.appendingPathComponent("nested/out/splat.ply"),
        runner: MsplatRunner(runner: MockSubprocessRunner(scripts: []))
    )
}

private func successfulMock(context: MsplatTestContext) -> MockSubprocessRunner {
    MockSubprocessRunner(scripts: [
        .init(
            path: context.executable.path,
            argsPrefix: ["--dataset", context.dataset.path],
            result: .init(exitCode: 0, terminationReason: .exit, stdout: validEvents(), stderr: ""),
            onRun: { _ in TestFileBuilder.createFile(at: context.output, data: fixtureOutputData) }
        ),
    ])
}

private func validEvents(
    profile: String = "balanced",
    limit: Int = 7_000,
    plateau: Int = 800,
    seed: UInt64 = 42,
    includeProgressLoss: Bool = true
) -> String {
    let lossFields = includeProgressLoss
        ? ",\"loss\":0.12,\"loss_iteration\":\(limit / 2)"
        : ""
    return """
    {"camera_count":8,"event":"started","initial_gaussian_count":750,"iteration":0,"iteration_limit":\(limit),"plateau_window":\(plateau),"profile":"\(profile)","schema_version":1,"seed":\(seed),"sequence":1,"version":"1.1.3 (git 106499b)"}
    {"elapsed_seconds":2.5,"eta_seconds":2.5,"event":"progress","gaussian_count":1000,"iteration":\(limit / 2),"iteration_limit":\(limit),"iterations_per_second":1400\(lossFields),"schema_version":1,"sequence":2}
    {"elapsed_seconds":5,"event":"completed","gaussian_count":1250,"iteration":\(limit),"iteration_limit":\(limit),"output_bytes":4096,"plateau_window":\(plateau),"profile":"\(profile)","schema_version":1,"seed":\(seed),"sequence":3,"stop_reason":"iteration_limit"}
    """ + "\n"
}

private let fixtureOutputData = Data(repeating: 0, count: 4_096)

private final class LockedBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: Value

    init(_ value: Value) {
        storage = value
    }

    var value: Value {
        lock.withLock { storage }
    }

    func withValue(_ body: (inout Value) -> Void) {
        lock.withLock { body(&storage) }
    }
}
