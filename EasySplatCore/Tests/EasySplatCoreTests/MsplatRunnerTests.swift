import CryptoKit
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
                memoryBudgetBytes: testMemoryBudgetBytes,
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
                memoryBudgetBytes: testMemoryBudgetBytes,
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
                    argsPrefix: ["--dataset", context.dataset.path],
                    result: .init(exitCode: 0, terminationReason: .exit, stdout: stdout, stderr: ""),
                    onRun: { arguments in
                        XCTAssertEqual(argumentValue("--profile", in: arguments), argument)
                        XCTAssertEqual(argumentValue("--checkpoint", in: arguments), context.checkpoint.path)
                        XCTAssertEqual(argumentValue("--seed", in: arguments), "9")
                        XCTAssertEqual(
                            argumentValue("--memory-budget-bytes", in: arguments),
                            String(testMemoryBudgetBytes)
                        )
                        XCTAssertEqual(
                            argumentValue("--expected-input-digest", in: arguments),
                            testInputDigest
                        )
                        XCTAssertEqual(
                            argumentValue("--expected-geometry-digest", in: arguments),
                            testGeometryDigest
                        )
                        try? writeFixtureOutput(arguments: arguments)
                    }
                ),
            ])

            let result = try await MsplatRunner(runner: mock).runTrain(
                msplatPath: context.executable,
                datasetPath: context.dataset,
                outputPath: context.output,
                profile: profile,
                seed: 9,
                memoryBudgetBytes: testMemoryBudgetBytes,
                onLog: { _, _ in }
            )

            XCTAssertEqual(result.profile, profile)
            XCTAssertEqual(result.iterationLimit, limit)
            XCTAssertEqual(result.plateauWindow, plateau)
            XCTAssertEqual(result.completedIteration, limit)
            XCTAssertEqual(result.stopReason, .iterationLimit)
            XCTAssertEqual(result.gaussianCount, 1_250)
            XCTAssertEqual(
                result.sceneBounds,
                SplatSceneBounds(
                    center: .init(x: 1.25, y: -2.5, z: 3.75),
                    radius: 8.5
                )
            )
            XCTAssertEqual(result.peakMemoryBytes, testCompletionPeakMemoryBytes)
            XCTAssertEqual(
                result.latestCheckpoint?.peakMemoryBytes,
                testCheckpointPeakMemoryBytes
            )
            XCTAssertTrue(FileManager.default.fileExists(atPath: context.output.deletingLastPathComponent().path))
        }
    }

    func testRunTrainPassesMemoryBudgetAndReportsExactRasterFallback() async throws {
        let context = try makeContext()
        defer { context.cleanup() }
        let fallbacks = LockedBox<[MsplatRasterFallback]>([])
        let mock = MockSubprocessRunner(scripts: [
            .init(
                path: context.executable.path,
                argsPrefix: ["--dataset", context.dataset.path],
                result: .init(
                    exitCode: 0,
                    terminationReason: .exit,
                    stdout: validEvents(rasterFallbackCount: 1, includeRasterReplay: true),
                    stderr: ""
                ),
                onRun: { arguments in
                    guard let output = argumentValue("--output", in: arguments) else {
                        return XCTFail("Missing staged output argument")
                    }
                    XCTAssertTrue(output.hasSuffix(".training.tmp.ply"))
                    XCTAssertNotEqual(output, context.output.path)
                    try? writeFixtureOutput(arguments: arguments)
                }
            ),
        ])

        let result = try await MsplatRunner(runner: mock).runTrain(
            msplatPath: context.executable,
            datasetPath: context.dataset,
            outputPath: context.output,
            profile: .balanced,
            seed: 42,
            memoryBudgetBytes: testMemoryBudgetBytes,
            onRasterFallback: { fallback in fallbacks.withValue { $0.append(fallback) } },
            onLog: { _, _ in }
        )

        XCTAssertEqual(result.memoryBudgetBytes, testMemoryBudgetBytes)
        XCTAssertEqual(result.rasterFallbackCount, 1)
        XCTAssertEqual(result.rasterExactFallbackElapsedSeconds, 0.25)
        XCTAssertEqual(result.rasterExactBufferGrowthCount, 1)
        XCTAssertEqual(result.rasterExactBufferBytesAdded, 65_536)
        XCTAssertEqual(result.rasterReplayElapsedSeconds, 0.5)
        XCTAssertEqual(result.rasterPeakExactIntersectionCapacity, 4_096)
        XCTAssertEqual(result.droppedIntersectionCount, 0)
        XCTAssertEqual(
            fallbacks.value,
            [
                MsplatRasterFallback(
                    iteration: 3_500,
                    fallbackCount: 1,
                    intersectionCount: 4_096,
                    allocationBytes: 65_536
                ),
            ]
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: context.output.path))
        XCTAssertFalse(try containsStagingOutput(in: context.output.deletingLastPathComponent()))
    }

    func testRunTrainAcceptsNativeRasterReplayBeforeFallback() async throws {
        let context = try makeContext()
        defer { context.cleanup() }
        let mock = MockSubprocessRunner(scripts: [
            .init(
                path: context.executable.path,
                argsPrefix: ["--dataset", context.dataset.path],
                result: .init(
                    exitCode: 0,
                    terminationReason: .exit,
                    stdout: validEvents(
                        rasterFallbackCount: 1,
                        includeRasterReplay: true
                    ),
                    stderr: ""
                ),
                onRun: { arguments in try? writeFixtureOutput(arguments: arguments) }
            ),
        ])

        let result = try await MsplatRunner(runner: mock).runTrain(
            msplatPath: context.executable,
            datasetPath: context.dataset,
            outputPath: context.output,
            profile: .balanced,
            seed: 42,
            memoryBudgetBytes: testMemoryBudgetBytes,
            onLog: { _, _ in }
        )

        XCTAssertEqual(result.rasterFallbackCount, 1)
        XCTAssertEqual(result.droppedIntersectionCount, 0)
    }

    func testMemoryBudgetFailureIsTypedAndPreservesExistingOutput() async throws {
        let context = try makeContext()
        defer { context.cleanup() }
        let prior = Data("previous validated output".utf8)
        try FileManager.default.createDirectory(
            at: context.output.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try prior.write(to: context.output)
        let stdout = """
        {"camera_count":8,"checkpoint_schema":3,"event":"started","geometry_digest":"\(testGeometryDigest)","initial_gaussian_count":750,"input_digest":"\(testInputDigest)","iteration":0,"iteration_limit":7000,"memory_budget_bytes":\(testMemoryBudgetBytes),"payload_schema":2,"plateau_window":800,"profile":"balanced","raster_exact_buffer_bytes_added":0,"raster_exact_buffer_growth_count":0,"raster_exact_fallback_elapsed_seconds":0,"raster_fallback_count":0,"raster_peak_exact_intersection_capacity":0,"raster_replay_elapsed_seconds":0,"resumed":false,"schema_version":2,"seed":42,"sequence":1,"trainer_build_digest":"\(testTrainerDigest)","version":"1.1.3 (git 106499b)"}
        {"budget_bytes":\(testMemoryBudgetBytes),"event":"raster_memory_budget_exceeded","iteration":12,"required_bytes":\(testMemoryBudgetBytes + 1),"schema_version":2,"sequence":2}
        """ + "\n"
        let mock = MockSubprocessRunner(scripts: [
            .init(
                path: context.executable.path,
                argsPrefix: ["--dataset", context.dataset.path],
                result: .init(exitCode: 75, terminationReason: .exit, stdout: stdout, stderr: ""),
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
                memoryBudgetBytes: testMemoryBudgetBytes,
                onLog: { _, _ in }
            )
            XCTFail("Expected raster memory budget failure")
        } catch let failure as MsplatRasterMemoryBudgetExceeded {
            XCTAssertEqual(failure.iteration, 12)
            XCTAssertEqual(failure.requiredBytes, testMemoryBudgetBytes + 1)
            XCTAssertEqual(failure.budgetBytes, testMemoryBudgetBytes)
        }
        XCTAssertEqual(try Data(contentsOf: context.output), prior)
        XCTAssertFalse(try containsStagingOutput(in: context.output.deletingLastPathComponent()))
    }

    func testSetupMemoryBudgetFailureIsTypedBeforeStartedEvent() async throws {
        let context = try makeContext()
        defer { context.cleanup() }
        let stdout = """
        {"budget_bytes":\(testMemoryBudgetBytes),"event":"raster_memory_budget_exceeded","iteration":0,"required_bytes":\(testMemoryBudgetBytes + 1),"schema_version":2,"sequence":1}
        """ + "\n"
        let mock = MockSubprocessRunner(scripts: [
            .init(
                path: context.executable.path,
                argsPrefix: ["--dataset", context.dataset.path],
                result: .init(exitCode: 75, terminationReason: .exit, stdout: stdout, stderr: ""),
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
                memoryBudgetBytes: testMemoryBudgetBytes,
                onLog: { _, _ in }
            )
            XCTFail("Expected setup memory budget failure")
        } catch let failure as MsplatRasterMemoryBudgetExceeded {
            XCTAssertEqual(failure.iteration, 0)
            XCTAssertEqual(failure.requiredBytes, testMemoryBudgetBytes + 1)
            XCTAssertEqual(failure.budgetBytes, testMemoryBudgetBytes)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: context.output.path))
        XCTAssertFalse(try containsStagingOutput(in: context.output.deletingLastPathComponent()))
    }

    func testResumeSetupMemoryBudgetFailureIsTypedAtIterationZero() async throws {
        let context = try makeContext()
        defer { context.cleanup() }
        _ = try makeMsplatCheckpointFixture(at: context.checkpoint, iteration: 500)
        let stdout = """
        {"budget_bytes":\(testMemoryBudgetBytes),"event":"raster_memory_budget_exceeded","intersection_count":4000001,"iteration":0,"required_bytes":\(testMemoryBudgetBytes + 1),"schema_version":2,"sequence":1}
        """ + "\n"
        let mock = MockSubprocessRunner(scripts: [
            .init(
                path: context.executable.path,
                argsPrefix: ["--dataset", context.dataset.path],
                result: .init(exitCode: 75, terminationReason: .exit, stdout: stdout, stderr: ""),
                onRun: nil
            ),
        ])

        do {
            _ = try await MsplatRunner(runner: mock).runTrain(
                msplatPath: context.executable,
                datasetPath: context.dataset,
                outputPath: context.output,
                checkpointPath: context.checkpoint,
                resumeFrom: context.checkpoint,
                profile: .balanced,
                seed: 42,
                memoryBudgetBytes: testMemoryBudgetBytes,
                onLog: { _, _ in }
            )
            XCTFail("Expected resumed setup memory budget failure")
        } catch let failure as MsplatRasterMemoryBudgetExceeded {
            XCTAssertEqual(failure.iteration, 0)
            XCTAssertEqual(failure.intersectionCount, 4_000_001)
            XCTAssertEqual(failure.requiredBytes, testMemoryBudgetBytes + 1)
            XCTAssertEqual(failure.budgetBytes, testMemoryBudgetBytes)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: context.output.path))
        XCTAssertFalse(try containsStagingOutput(in: context.output.deletingLastPathComponent()))
    }

    func testResumeSetupResourceLimitFailureIsTypedAtIterationZero() async throws {
        let context = try makeContext()
        defer { context.cleanup() }
        _ = try makeMsplatCheckpointFixture(at: context.checkpoint, iteration: 500)
        let maximumBufferBytes: Int64 = 4_294_967_296
        let requiredBytes = maximumBufferBytes + 4_096
        let stdout = """
        {"event":"raster_resource_limit_exceeded","intersection_count":4000001,"iteration":0,"max_buffer_bytes":\(maximumBufferBytes),"required_bytes":\(requiredBytes),"schema_version":2,"sequence":1}
        """ + "\n"
        let mock = MockSubprocessRunner(scripts: [
            .init(
                path: context.executable.path,
                argsPrefix: ["--dataset", context.dataset.path],
                result: .init(exitCode: 75, terminationReason: .exit, stdout: stdout, stderr: ""),
                onRun: nil
            ),
        ])

        do {
            _ = try await MsplatRunner(runner: mock).runTrain(
                msplatPath: context.executable,
                datasetPath: context.dataset,
                outputPath: context.output,
                checkpointPath: context.checkpoint,
                resumeFrom: context.checkpoint,
                profile: .balanced,
                seed: 42,
                memoryBudgetBytes: testMemoryBudgetBytes,
                onLog: { _, _ in }
            )
            XCTFail("Expected resumed setup resource limit failure")
        } catch let failure as MsplatRasterResourceLimitExceeded {
            XCTAssertEqual(failure.iteration, 0)
            XCTAssertEqual(failure.intersectionCount, 4_000_001)
            XCTAssertEqual(failure.requiredBytes, requiredBytes)
            XCTAssertEqual(failure.maximumBufferBytes, maximumBufferBytes)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: context.output.path))
        XCTAssertFalse(try containsStagingOutput(in: context.output.deletingLastPathComponent()))
    }

    func testRasterResourceLimitFailureIsTypedAndPreservesExistingOutput() async throws {
        let context = try makeContext()
        defer { context.cleanup() }
        let prior = Data("previous validated output".utf8)
        try FileManager.default.createDirectory(
            at: context.output.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try prior.write(to: context.output)
        let maximumBufferBytes: Int64 = 4_294_967_296
        let requiredBytes = maximumBufferBytes + 4_096
        XCTAssertLessThan(requiredBytes, testMemoryBudgetBytes)
        let stdout = """
        {"camera_count":8,"checkpoint_schema":3,"event":"started","geometry_digest":"\(testGeometryDigest)","initial_gaussian_count":750,"input_digest":"\(testInputDigest)","iteration":0,"iteration_limit":7000,"memory_budget_bytes":\(testMemoryBudgetBytes),"payload_schema":2,"plateau_window":800,"profile":"balanced","raster_exact_buffer_bytes_added":0,"raster_exact_buffer_growth_count":0,"raster_exact_fallback_elapsed_seconds":0,"raster_fallback_count":0,"raster_peak_exact_intersection_capacity":0,"raster_replay_elapsed_seconds":0,"resumed":false,"schema_version":2,"seed":42,"sequence":1,"trainer_build_digest":"\(testTrainerDigest)","version":"1.1.3 (git 106499b)"}
        {"event":"raster_resource_limit_exceeded","intersection_count":4096,"iteration":12,"max_buffer_bytes":\(maximumBufferBytes),"required_bytes":\(requiredBytes),"schema_version":2,"sequence":2}
        """ + "\n"
        let mock = MockSubprocessRunner(scripts: [
            .init(
                path: context.executable.path,
                argsPrefix: ["--dataset", context.dataset.path],
                result: .init(exitCode: 75, terminationReason: .exit, stdout: stdout, stderr: ""),
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
                memoryBudgetBytes: testMemoryBudgetBytes,
                onLog: { _, _ in }
            )
            XCTFail("Expected raster resource limit failure")
        } catch let failure as MsplatRasterResourceLimitExceeded {
            XCTAssertEqual(failure.iteration, 12)
            XCTAssertEqual(failure.requiredBytes, requiredBytes)
            XCTAssertEqual(failure.maximumBufferBytes, maximumBufferBytes)
            XCTAssertEqual(failure.intersectionCount, 4_096)
        }
        XCTAssertEqual(try Data(contentsOf: context.output), prior)
        XCTAssertFalse(try containsStagingOutput(in: context.output.deletingLastPathComponent()))
    }

    func testSetupResourceLimitFailureIsTypedBeforeStartedEvent() async throws {
        let context = try makeContext()
        defer { context.cleanup() }
        let maximumBufferBytes: Int64 = 4_294_967_296
        let requiredBytes = maximumBufferBytes + 4_096
        let stdout = """
        {"event":"raster_resource_limit_exceeded","iteration":0,"max_buffer_bytes":\(maximumBufferBytes),"required_bytes":\(requiredBytes),"schema_version":2,"sequence":1}
        """ + "\n"
        let mock = MockSubprocessRunner(scripts: [
            .init(
                path: context.executable.path,
                argsPrefix: ["--dataset", context.dataset.path],
                result: .init(exitCode: 75, terminationReason: .exit, stdout: stdout, stderr: ""),
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
                memoryBudgetBytes: testMemoryBudgetBytes,
                onLog: { _, _ in }
            )
            XCTFail("Expected setup resource limit failure")
        } catch let failure as MsplatRasterResourceLimitExceeded {
            XCTAssertEqual(failure.iteration, 0)
            XCTAssertEqual(failure.requiredBytes, requiredBytes)
            XCTAssertEqual(failure.maximumBufferBytes, maximumBufferBytes)
            XCTAssertNil(failure.intersectionCount)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: context.output.path))
        XCTAssertFalse(try containsStagingOutput(in: context.output.deletingLastPathComponent()))
    }

    func testDroppedIntersectionsRejectCompletionBeforeReplacingExistingOutput() async throws {
        let context = try makeContext()
        defer { context.cleanup() }
        let prior = Data("previous validated output".utf8)
        try FileManager.default.createDirectory(
            at: context.output.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try prior.write(to: context.output)
        let mock = MockSubprocessRunner(scripts: [
            .init(
                path: context.executable.path,
                argsPrefix: ["--dataset", context.dataset.path],
                result: .init(
                    exitCode: 0,
                    terminationReason: .exit,
                    stdout: validEvents(droppedIntersectionCount: 1),
                    stderr: ""
                ),
                onRun: { arguments in
                    try? writeFixtureOutput(arguments: arguments)
                }
            ),
        ])

        await XCTAssertThrowsErrorAsync {
            _ = try await MsplatRunner(runner: mock).runTrain(
                msplatPath: context.executable,
                datasetPath: context.dataset,
                outputPath: context.output,
                profile: .balanced,
                seed: 42,
                memoryBudgetBytes: testMemoryBudgetBytes,
                onLog: { _, _ in }
            )
        }
        XCTAssertEqual(try Data(contentsOf: context.output), prior)
        XCTAssertFalse(try containsStagingOutput(in: context.output.deletingLastPathComponent()))
    }

    func testRunTrainValidatesEventsAgainstResolvedBudget() async throws {
        let context = try makeContext()
        defer { context.cleanup() }
        let mock = MockSubprocessRunner(scripts: [
            .init(
                path: context.executable.path,
                argsPrefix: ["--dataset", context.dataset.path],
                result: .init(
                    exitCode: 0,
                    terminationReason: .exit,
                    stdout: validEvents(
                        profile: "balanced",
                        limit: 123,
                        plateau: 50,
                        seed: 7
                    ),
                    stderr: ""
                ),
                onRun: { arguments in try? writeFixtureOutput(arguments: arguments) }
            )
        ])

        let result = try await MsplatRunner(runner: mock).runTrain(
            msplatPath: context.executable,
            datasetPath: context.dataset,
            outputPath: context.output,
            profile: .balanced,
            seed: 7,
            iterationLimit: 123,
            plateauWindow: 50,
            memoryBudgetBytes: testMemoryBudgetBytes,
            onLog: { _, _ in }
        )

        XCTAssertEqual(result.iterationLimit, 123)
        XCTAssertEqual(result.plateauWindow, 50)
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
            memoryBudgetBytes: testMemoryBudgetBytes,
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
                onRun: { arguments in try? writeFixtureOutput(arguments: arguments) }
            ),
        ])

        _ = try await MsplatRunner(runner: mock).runTrain(
            msplatPath: context.executable,
            datasetPath: context.dataset,
            outputPath: context.output,
            profile: .balanced,
            seed: 42,
            memoryBudgetBytes: testMemoryBudgetBytes,
            onProgress: { update in progress.withValue { $0.append(update) } },
            onLog: { _, _ in }
        )

        XCTAssertNil(progress.value.first?.loss)
        XCTAssertNil(progress.value.first?.lossIteration)
    }

    func testRunTrainAcceptsNativeEarlyStopFields() async throws {
        let context = try makeContext()
        defer { context.cleanup() }
        var records = validEvents().split(separator: "\n").map(String.init)
        records[3] = records[3]
            .replacingOccurrences(of: "\"iteration\":7000", with: "\"iteration\":3500")
            .replacingOccurrences(of: "\"sequence\":4", with: "\"sequence\":5")
            .replacingOccurrences(
                of: "\"stop_reason\":\"iteration_limit\"",
                with: "\"stop_reason\":\"plateau\""
            )
        records.insert(
            "{\"event\":\"early_stop\",\"iteration\":3500,\"last_improvement_iteration\":2700,\"loss\":0.12,\"loss_iteration\":3500,\"plateau_window\":800,\"reason\":\"plateau\",\"schema_version\":2,\"sequence\":4}",
            at: 3
        )
        let mock = MockSubprocessRunner(scripts: [
            .init(
                path: context.executable.path,
                argsPrefix: ["--dataset", context.dataset.path],
                result: .init(
                    exitCode: 0,
                    terminationReason: .exit,
                    stdout: records.joined(separator: "\n") + "\n",
                    stderr: ""
                ),
                onRun: { arguments in try? writeFixtureOutput(arguments: arguments) }
            ),
        ])

        let result = try await MsplatRunner(runner: mock).runTrain(
            msplatPath: context.executable,
            datasetPath: context.dataset,
            outputPath: context.output,
            profile: .balanced,
            seed: 42,
            memoryBudgetBytes: testMemoryBudgetBytes,
            onLog: { _, _ in }
        )

        XCTAssertEqual(result.completedIteration, 3_500)
        XCTAssertEqual(result.stopReason, .plateau)
    }

    func testRunTrainRejectsEarlyStopWithoutPlateauEvidence() async throws {
        var records = validEvents().split(separator: "\n").map(String.init)
        records[3] = records[3]
            .replacingOccurrences(of: "\"iteration\":7000", with: "\"iteration\":3500")
            .replacingOccurrences(of: "\"sequence\":4", with: "\"sequence\":5")
            .replacingOccurrences(
                of: "\"stop_reason\":\"iteration_limit\"",
                with: "\"stop_reason\":\"plateau\""
            )
        records.insert(
            "{\"event\":\"early_stop\",\"iteration\":3500,\"last_improvement_iteration\":2800,\"loss\":0.12,\"loss_iteration\":3500,\"plateau_window\":800,\"reason\":\"plateau\",\"schema_version\":2,\"sequence\":4}",
            at: 3
        )
        let context = try makeContext()
        defer { context.cleanup() }
        let mock = MockSubprocessRunner(scripts: [
            .init(
                path: context.executable.path,
                argsPrefix: ["--dataset", context.dataset.path],
                result: .init(
                    exitCode: 0,
                    terminationReason: .exit,
                    stdout: records.joined(separator: "\n") + "\n",
                    stderr: ""
                ),
                onRun: { arguments in try? writeFixtureOutput(arguments: arguments) }
            ),
        ])

        do {
            _ = try await MsplatRunner(runner: mock).runTrain(
                msplatPath: context.executable,
                datasetPath: context.dataset,
                outputPath: context.output,
                profile: .balanced,
                seed: 42,
                memoryBudgetBytes: testMemoryBudgetBytes,
                onLog: { _, _ in }
            )
            XCTFail("Expected insufficient plateau evidence to fail")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("early_stop"))
        }
    }

    func testRunTrainRejectsMalformedOrIncompleteEventStreams() async throws {
        let cases: [(String, String)] = [
            ("malformed", "not json\n"),
            ("wrong schema", validEvents().replacingOccurrences(of: "\"schema_version\":2", with: "\"schema_version\":1")),
            ("invented payload schema", validEvents().replacingOccurrences(of: "\"payload_schema\":2", with: "\"payload_schema\":3")),
            ("skipped sequence", validEvents().replacingOccurrences(of: "\"sequence\":2", with: "\"sequence\":4")),
            ("wrong version", validEvents().replacingOccurrences(of: "1.1.3 (git 106499b)", with: "1.1.4 (git deadbee)")),
            ("profile mismatch", validEvents().replacingOccurrences(of: "\"profile\":\"balanced\"", with: "\"profile\":\"fast\"")),
            ("plateau without early stop", validEvents().replacingOccurrences(of: "\"stop_reason\":\"iteration_limit\"", with: "\"stop_reason\":\"plateau\"")),
            (
                "fallback beyond event iteration",
                validEvents(rasterFallbackCount: 3_501, includeRasterReplay: true)
            ),
            (
                "fallback beyond native counter",
                validEvents(
                    rasterFallbackCount: Int(UInt32.max) + 1,
                    includeRasterReplay: true
                )
            ),
            (
                "fallback without exact timing",
                validEvents(rasterFallbackCount: 1, includeRasterReplay: true)
                    .replacingOccurrences(
                        of: "\"raster_exact_fallback_elapsed_seconds\":0.25",
                        with: "\"raster_exact_fallback_elapsed_seconds\":0"
                    )
            ),
            (
                "fallback without replay timing",
                validEvents(rasterFallbackCount: 1, includeRasterReplay: true)
                    .replacingOccurrences(
                        of: "\"raster_replay_elapsed_seconds\":0.5",
                        with: "\"raster_replay_elapsed_seconds\":0"
                    )
            ),
            (
                "exact capacity beyond native range",
                validEvents(rasterFallbackCount: 1, includeRasterReplay: true)
                    .replacingOccurrences(
                        of: "\"raster_peak_exact_intersection_capacity\":4096",
                        with: "\"raster_peak_exact_intersection_capacity\":4294967296"
                    )
            ),
            (
                "one growth beyond memory budget",
                validEvents(rasterFallbackCount: 1, includeRasterReplay: true)
                    .replacingOccurrences(
                        of: "\"raster_exact_buffer_bytes_added\":65536",
                        with: "\"raster_exact_buffer_bytes_added\":\(testMemoryBudgetBytes + 1)"
                    )
            ),
            (
                "peak memory overflow",
                validEvents().replacingOccurrences(
                    of: "\"peak_memory_bytes\":\(testCheckpointPeakMemoryBytes)",
                    with: "\"peak_memory_bytes\":9223372036854775808"
                )
            ),
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
                    onRun: { arguments in try? writeFixtureOutput(arguments: arguments) }
                ),
            ])

            do {
                _ = try await MsplatRunner(runner: mock).runTrain(
                    msplatPath: context.executable,
                    datasetPath: context.dataset,
                    outputPath: context.output,
                    profile: .balanced,
                    seed: 42,
                    memoryBudgetBytes: testMemoryBudgetBytes,
                    onLog: { _, _ in }
                )
                XCTFail("Expected protocol failure for \(name)")
            } catch {
                XCTAssertTrue(error.localizedDescription.lowercased().contains("event"), "\(name): \(error)")
            }
        }
    }

    func testRunTrainRejectsUnknownEventField() async throws {
        let context = try makeContext()
        defer { context.cleanup() }
        let stdout = validEvents().replacingOccurrences(
            of: "\"elapsed_seconds\":2.5,",
            with: "\"elapsed_seconds\":2.5,\"mystery_field\":true,"
        )
        let mock = MockSubprocessRunner(scripts: [
            .init(
                path: context.executable.path,
                argsPrefix: ["--dataset", context.dataset.path],
                result: .init(exitCode: 0, terminationReason: .exit, stdout: stdout, stderr: ""),
                onRun: { arguments in try? writeFixtureOutput(arguments: arguments) }
            ),
        ])

        do {
            _ = try await MsplatRunner(runner: mock).runTrain(
                msplatPath: context.executable,
                datasetPath: context.dataset,
                outputPath: context.output,
                profile: .balanced,
                seed: 42,
                memoryBudgetBytes: testMemoryBudgetBytes,
                onLog: { _, _ in }
            )
            XCTFail("Expected unknown event field to fail")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("mystery_field"))
        }
    }

    func testRunTrainRejectsCompletedSceneBoundsOnProgressEvent() async throws {
        let context = try makeContext()
        defer { context.cleanup() }
        let stdout = validEvents().replacingOccurrences(
            of: "\"elapsed_seconds\":2.5,",
            with: "\"elapsed_seconds\":2.5,\"scene_center\":[0,0,0],\"scene_radius\":1,"
        )
        let mock = MockSubprocessRunner(scripts: [
            .init(
                path: context.executable.path,
                argsPrefix: ["--dataset", context.dataset.path],
                result: .init(exitCode: 0, terminationReason: .exit, stdout: stdout, stderr: ""),
                onRun: { arguments in try? writeFixtureOutput(arguments: arguments) }
            ),
        ])

        do {
            _ = try await MsplatRunner(runner: mock).runTrain(
                msplatPath: context.executable,
                datasetPath: context.dataset,
                outputPath: context.output,
                profile: .balanced,
                seed: 42,
                memoryBudgetBytes: testMemoryBudgetBytes,
                onLog: { _, _ in }
            )
            XCTFail("Expected completed-only fields on progress to fail")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("scene_center"))
        }
    }

    func testRunTrainRejectsInvalidPeakMemoryEvidence() async throws {
        let cases: [(String, Int64?, Int64?)] = [
            ("missing checkpoint", nil, testCompletionPeakMemoryBytes),
            ("zero checkpoint", 0, testCompletionPeakMemoryBytes),
            ("missing completion", testCheckpointPeakMemoryBytes, nil),
            ("zero completion", testCheckpointPeakMemoryBytes, 0),
            ("decreasing completion", testCheckpointPeakMemoryBytes, 1),
        ]

        for (name, checkpointPeakMemoryBytes, completionPeakMemoryBytes) in cases {
            let context = try makeContext()
            defer { context.cleanup() }
            let mock = MockSubprocessRunner(scripts: [
                .init(
                    path: context.executable.path,
                    argsPrefix: ["--dataset", context.dataset.path],
                    result: .init(
                        exitCode: 0,
                        terminationReason: .exit,
                        stdout: validEvents(
                            checkpointPeakMemoryBytes: checkpointPeakMemoryBytes,
                            completionPeakMemoryBytes: completionPeakMemoryBytes
                        ),
                        stderr: ""
                    ),
                    onRun: { arguments in try? writeFixtureOutput(arguments: arguments) }
                ),
            ])

            do {
                _ = try await MsplatRunner(runner: mock).runTrain(
                    msplatPath: context.executable,
                    datasetPath: context.dataset,
                    outputPath: context.output,
                    profile: .balanced,
                    seed: 42,
                    memoryBudgetBytes: testMemoryBudgetBytes,
                    onLog: { _, _ in }
                )
                XCTFail("Expected peak-memory protocol failure for \(name)")
            } catch {
                XCTAssertTrue(
                    error.localizedDescription.lowercased().contains("event"),
                    "\(name): \(error)"
                )
            }
        }
    }

    func testRunTrainRejectsMissingOrInvalidSceneBounds() async throws {
        let validCenter = "\"scene_center\":[1.25,-2.5,3.75]"
        let validRadius = "\"scene_radius\":8.5"
        let cases: [(String, String)] = [
            ("missing center", validEvents().replacingOccurrences(of: validCenter + ",", with: "")),
            ("short center", validEvents().replacingOccurrences(of: validCenter, with: "\"scene_center\":[1.25,-2.5]")),
            ("non-finite center", validEvents().replacingOccurrences(of: validCenter, with: "\"scene_center\":[1.25,1e999,3.75]")),
            ("missing radius", validEvents().replacingOccurrences(of: validRadius + ",", with: "")),
            ("zero radius", validEvents().replacingOccurrences(of: validRadius, with: "\"scene_radius\":0")),
            ("non-finite radius", validEvents().replacingOccurrences(of: validRadius, with: "\"scene_radius\":1e999")),
        ]

        for (name, stdout) in cases {
            let context = try makeContext()
            defer { context.cleanup() }
            let mock = MockSubprocessRunner(scripts: [
                .init(
                    path: context.executable.path,
                    argsPrefix: ["--dataset", context.dataset.path],
                    result: .init(exitCode: 0, terminationReason: .exit, stdout: stdout, stderr: ""),
                    onRun: { arguments in try? writeFixtureOutput(arguments: arguments) }
                ),
            ])

            do {
                _ = try await MsplatRunner(runner: mock).runTrain(
                    msplatPath: context.executable,
                    datasetPath: context.dataset,
                    outputPath: context.output,
                    profile: .balanced,
                    seed: 42,
                    memoryBudgetBytes: testMemoryBudgetBytes,
                    onLog: { _, _ in }
                )
                XCTFail("Expected scene-bounds protocol failure for \(name)")
            } catch {
                XCTAssertTrue(
                    error.localizedDescription.lowercased().contains("event"),
                    "\(name): \(error)"
                )
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
                memoryBudgetBytes: testMemoryBudgetBytes,
                onLog: { _, _ in }
            )
            XCTFail("Expected missing-output failure")
        } catch {
            XCTAssertTrue(error.localizedDescription.lowercased().contains("output"))
        }
    }

    func testRunTrainRejectsStagedOutputSymlinkBeforeReadingIt() async throws {
        let context = try makeContext()
        defer { context.cleanup() }
        let externalOutput = context.output.deletingLastPathComponent()
            .appendingPathComponent("untrusted-target.ply")
        try FileManager.default.createDirectory(
            at: externalOutput.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try fixtureOutputData.write(to: externalOutput)
        let mock = MockSubprocessRunner(scripts: [
            .init(
                path: context.executable.path,
                argsPrefix: ["--dataset", context.dataset.path],
                result: .init(
                    exitCode: 0,
                    terminationReason: .exit,
                    stdout: validEvents(),
                    stderr: ""
                ),
                onRun: { arguments in
                    guard let output = argumentValue("--output", in: arguments) else {
                        return XCTFail("Missing staged output argument")
                    }
                    try? FileManager.default.createSymbolicLink(
                        at: URL(fileURLWithPath: output),
                        withDestinationURL: externalOutput
                    )
                }
            ),
        ])

        do {
            _ = try await MsplatRunner(runner: mock).runTrain(
                msplatPath: context.executable,
                datasetPath: context.dataset,
                outputPath: context.output,
                profile: .balanced,
                seed: 42,
                memoryBudgetBytes: testMemoryBudgetBytes,
                onLog: { _, _ in }
            )
            XCTFail("Expected staged-symlink rejection")
        } catch {
            XCTAssertTrue(error.localizedDescription.lowercased().contains("regular file"))
        }

        XCTAssertEqual(try Data(contentsOf: externalOutput), fixtureOutputData)
        XCTAssertFalse(FileManager.default.fileExists(atPath: context.output.path))
    }

    func testRunTrainRejectsWrongDatasetIdentityBeforeReplacingExistingOutput() async throws {
        let context = try makeContext()
        defer { context.cleanup() }
        try FileManager.default.createDirectory(
            at: context.output.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let previousOutput = Data("previous validated output".utf8)
        try previousOutput.write(to: context.output)
        let wrongIdentityReceipt = MsplatCheckpointReceipt(
            iteration: 0,
            generation: "00000000-\(testGenerationDigest)",
            payloadSHA256: testPayloadDigest,
            payloadBytes: 128,
            gaussianCount: 750,
            peakMemoryBytes: testCheckpointPeakMemoryBytes,
            memoryBudgetBytes: testMemoryBudgetBytes,
            rasterFallbackCount: 0,
            rasterExactFallbackElapsedSeconds: 0,
            rasterExactBufferGrowthCount: 0,
            rasterExactBufferBytesAdded: 0,
            rasterReplayElapsedSeconds: 0,
            rasterPeakExactIntersectionCapacity: 0,
            droppedIntersectionCount: 0,
            inputDigest: String(repeating: "a", count: 64),
            geometryDigest: String(repeating: "b", count: 64),
            trainerBuildDigest: testTrainerDigest
        )
        let checkpointCallbacks = LockedBox(0)
        let mock = MockSubprocessRunner(scripts: [
            .init(
                path: context.executable.path,
                argsPrefix: ["--dataset", context.dataset.path],
                result: .init(
                    exitCode: 0,
                    terminationReason: .exit,
                    stdout: validEvents(checkpoint: wrongIdentityReceipt),
                    stderr: ""
                ),
                onRun: { arguments in try? writeFixtureOutput(arguments: arguments) }
            ),
        ])

        do {
            _ = try await MsplatRunner(runner: mock).runTrain(
                msplatPath: context.executable,
                datasetPath: context.dataset,
                outputPath: context.output,
                expectedIdentity: testDatasetIdentity,
                profile: .balanced,
                seed: 42,
                memoryBudgetBytes: testMemoryBudgetBytes,
                onCheckpoint: { _ in checkpointCallbacks.withValue { $0 += 1 } },
                onLog: { _, _ in }
            )
            XCTFail("Expected dataset identity mismatch to fail")
        } catch {
            XCTAssertTrue(error.localizedDescription.lowercased().contains("identity"))
        }

        XCTAssertEqual(try Data(contentsOf: context.output), previousOutput)
        XCTAssertEqual(checkpointCallbacks.value, 0)
        XCTAssertFalse(try containsStagingOutput(in: context.output.deletingLastPathComponent()))
    }

    func testRunTrainPreservesDanglingExistingOutputSymlink() async throws {
        let context = try makeContext()
        defer { context.cleanup() }
        try FileManager.default.createDirectory(
            at: context.output.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let missingTarget = context.output.deletingLastPathComponent()
            .appendingPathComponent("missing-output.ply")
        try FileManager.default.createSymbolicLink(
            at: context.output,
            withDestinationURL: missingTarget
        )
        let mock = successfulMock(context: context)

        do {
            _ = try await MsplatRunner(runner: mock).runTrain(
                msplatPath: context.executable,
                datasetPath: context.dataset,
                outputPath: context.output,
                profile: .balanced,
                seed: 42,
                memoryBudgetBytes: testMemoryBudgetBytes,
                onLog: { _, _ in }
            )
            XCTFail("Expected existing-output symlink rejection")
        } catch {
            XCTAssertTrue(error.localizedDescription.lowercased().contains("regular file"))
        }

        XCTAssertEqual(
            try FileManager.default.destinationOfSymbolicLink(atPath: context.output.path),
            missingTarget.path
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: missingTarget.path))
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
                memoryBudgetBytes: testMemoryBudgetBytes,
                onLog: { _, _ in }
            )
            XCTFail("Expected failure")
        } catch let error as SubprocessFailure {
            XCTAssertEqual(error.exitCode, 2)
            XCTAssertTrue(error.stderrTail.contains("bad scene"))
        }
    }

    func testRunTrainReportsTypedResumeRejectionBeforeStarted() async throws {
        for reason in MsplatResumeRejectionReason.allCases {
            let context = try makeContext()
            defer { context.cleanup() }
            try FileManager.default.createDirectory(
                at: context.checkpoint,
                withIntermediateDirectories: true
            )
            let stdout = """
            {"event":"resume_rejected","reason":"\(reason.rawValue)","schema_version":2,"sequence":1}
            """ + "\n"
            let mock = MockSubprocessRunner(scripts: [
                .init(
                    path: context.executable.path,
                    argsPrefix: ["--dataset", context.dataset.path],
                    result: .init(
                        exitCode: 78,
                        terminationReason: .exit,
                        stdout: stdout,
                        stderr: "saved optimizer state is incompatible"
                    ),
                    onRun: nil
                ),
            ])

            do {
                _ = try await MsplatRunner(runner: mock).runTrain(
                    msplatPath: context.executable,
                    datasetPath: context.dataset,
                    outputPath: context.output,
                    checkpointPath: context.checkpoint,
                    resumeFrom: context.checkpoint,
                    profile: .balanced,
                    seed: 42,
                    memoryBudgetBytes: testMemoryBudgetBytes,
                    onLog: { _, _ in }
                )
                XCTFail("Expected typed resume rejection for \(reason.rawValue)")
            } catch let rejection as MsplatResumeRejected {
                XCTAssertEqual(rejection.reason, reason)
            } catch {
                XCTFail("Expected typed resume rejection, got \(error)")
            }
        }
    }

    func testRunTrainRejectsResumeRejectionWithoutResumeRequest() async throws {
        let context = try makeContext()
        defer { context.cleanup() }
        let mock = MockSubprocessRunner(scripts: [
            .init(
                path: context.executable.path,
                argsPrefix: ["--dataset", context.dataset.path],
                result: .init(
                    exitCode: 78,
                    terminationReason: .exit,
                    stdout: "{\"event\":\"resume_rejected\",\"reason\":\"geometry_changed\",\"schema_version\":2,\"sequence\":1}\n",
                    stderr: "invalid event"
                ),
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
                memoryBudgetBytes: testMemoryBudgetBytes,
                onLog: { _, _ in }
            )
            XCTFail("Expected event protocol failure")
        } catch is MsplatResumeRejected {
            XCTFail("A fresh run cannot reject a resume")
        } catch {
            XCTAssertTrue(error.localizedDescription.lowercased().contains("event"))
        }
    }

    func testRunTrainRejectsResumeRejectionWithWrongExitStatus() async throws {
        let context = try makeContext()
        defer { context.cleanup() }
        try FileManager.default.createDirectory(
            at: context.checkpoint,
            withIntermediateDirectories: true
        )
        let mock = MockSubprocessRunner(scripts: [
            .init(
                path: context.executable.path,
                argsPrefix: ["--dataset", context.dataset.path],
                result: .init(
                    exitCode: 0,
                    terminationReason: .exit,
                    stdout: "{\"event\":\"resume_rejected\",\"reason\":\"trainer_changed\",\"schema_version\":2,\"sequence\":1}\n",
                    stderr: ""
                ),
                onRun: nil
            ),
        ])

        do {
            _ = try await MsplatRunner(runner: mock).runTrain(
                msplatPath: context.executable,
                datasetPath: context.dataset,
                outputPath: context.output,
                checkpointPath: context.checkpoint,
                resumeFrom: context.checkpoint,
                profile: .balanced,
                seed: 42,
                memoryBudgetBytes: testMemoryBudgetBytes,
                onLog: { _, _ in }
            )
            XCTFail("Expected event protocol failure")
        } catch is MsplatResumeRejected {
            XCTFail("A successful process cannot reject a resume")
        } catch {
            XCTAssertTrue(error.localizedDescription.lowercased().contains("event"))
        }
    }

    func testRunTrainResumesOnlyFromExplicitCheckpoint() async throws {
        let context = try makeContext()
        defer { context.cleanup() }
        let receipt = try makeMsplatCheckpointFixture(at: context.checkpoint, iteration: 500)
        let mock = MockSubprocessRunner(scripts: [
            .init(
                path: context.executable.path,
                argsPrefix: ["--dataset", context.dataset.path],
                result: .init(
                    exitCode: 0,
                    terminationReason: .exit,
                    stdout: validEvents(
                        startIteration: 500,
                        resumed: true,
                        checkpoint: receipt
                    ),
                    stderr: ""
                ),
                onRun: { arguments in
                    XCTAssertEqual(argumentValue("--resume", in: arguments), context.checkpoint.path)
                    try? writeFixtureOutput(arguments: arguments)
                }
            ),
        ])

        let result = try await MsplatRunner(runner: mock).runTrain(
            msplatPath: context.executable,
            datasetPath: context.dataset,
            outputPath: context.output,
            checkpointPath: context.checkpoint,
            resumeFrom: context.checkpoint,
            profile: .balanced,
            seed: 42,
            memoryBudgetBytes: testMemoryBudgetBytes,
            onLog: { _, _ in }
        )

        XCTAssertEqual(result.latestCheckpoint, receipt)
        XCTAssertEqual(result.inputDigest, receipt.inputDigest)
        XCTAssertEqual(result.geometryDigest, receipt.geometryDigest)
        XCTAssertEqual(mock.calls.count, 1)
    }

    func testResumePreservesCumulativeRasterFallbackCount() async throws {
        let context = try makeContext()
        defer { context.cleanup() }
        let receipt = try makeMsplatCheckpointFixture(
            at: context.checkpoint,
            iteration: 500,
            rasterFallbackCount: 3
        )
        let fallbacks = LockedBox<[MsplatRasterFallback]>([])
        let mock = MockSubprocessRunner(scripts: [
            .init(
                path: context.executable.path,
                argsPrefix: ["--dataset", context.dataset.path],
                result: .init(
                    exitCode: 0,
                    terminationReason: .exit,
                    stdout: validEvents(
                        startIteration: 500,
                        resumed: true,
                        checkpoint: receipt
                    ),
                    stderr: ""
                ),
                onRun: { arguments in
                    try? writeFixtureOutput(arguments: arguments)
                }
            ),
        ])

        let result = try await MsplatRunner(runner: mock).runTrain(
            msplatPath: context.executable,
            datasetPath: context.dataset,
            outputPath: context.output,
            checkpointPath: context.checkpoint,
            resumeFrom: context.checkpoint,
            profile: .balanced,
            seed: 42,
            memoryBudgetBytes: testMemoryBudgetBytes,
            onRasterFallback: { fallback in fallbacks.withValue { $0.append(fallback) } },
            onLog: { _, _ in }
        )

        XCTAssertEqual(result.rasterFallbackCount, 3)
        XCTAssertEqual(result.latestCheckpoint?.rasterFallbackCount, 3)
        XCTAssertEqual(
            result.rasterExactFallbackElapsedSeconds,
            receipt.rasterExactFallbackElapsedSeconds
        )
        XCTAssertEqual(result.rasterExactBufferGrowthCount, receipt.rasterExactBufferGrowthCount)
        XCTAssertEqual(result.rasterExactBufferBytesAdded, receipt.rasterExactBufferBytesAdded)
        XCTAssertEqual(result.rasterReplayElapsedSeconds, receipt.rasterReplayElapsedSeconds)
        XCTAssertEqual(
            result.rasterPeakExactIntersectionCapacity,
            receipt.rasterPeakExactIntersectionCapacity
        )
        XCTAssertTrue(fallbacks.value.isEmpty)
    }

    func testCancelledRunReturnsOnlyVerifiedCheckpointEvidence() async throws {
        let context = try makeContext()
        defer { context.cleanup() }
        let receipt = try makeMsplatCheckpointFixture(at: context.checkpoint, iteration: 500)
        let checkpointEvents = LockedBox<[MsplatCheckpointReceipt]>([])
        let runner = CancellingSubprocessRunner(
            events: interruptedEvents(checkpoint: receipt, currentIteration: 575)
        )

        do {
            _ = try await MsplatRunner(runner: runner).runTrain(
                msplatPath: context.executable,
                datasetPath: context.dataset,
                outputPath: context.output,
                checkpointPath: context.checkpoint,
                resumeFrom: context.checkpoint,
                profile: .balanced,
                seed: 42,
                memoryBudgetBytes: testMemoryBudgetBytes,
                onCheckpoint: { receipt in checkpointEvents.withValue { $0.append(receipt) } },
                onLog: { _, _ in }
            )
            XCTFail("Expected resumable interruption")
        } catch let interruption as MsplatTrainingInterrupted {
            XCTAssertEqual(interruption.completedIteration, 500)
            XCTAssertEqual(interruption.checkpoint, receipt)
        }
        XCTAssertEqual(checkpointEvents.value, [receipt])
        XCTAssertFalse(FileManager.default.fileExists(atPath: context.output.path))
    }

    func testImmediateCancellationAfterResumePreservesExactRasterReceipt() async throws {
        let context = try makeContext()
        defer { context.cleanup() }
        let receipt = try makeMsplatCheckpointFixture(
            at: context.checkpoint,
            iteration: 500,
            rasterFallbackCount: 1,
            peakExactIntersectionCapacity: 2_305
        )
        let runner = CancellingSubprocessRunner(
            events: interruptedEvents(checkpoint: receipt, currentIteration: 500)
        )

        do {
            _ = try await MsplatRunner(runner: runner).runTrain(
                msplatPath: context.executable,
                datasetPath: context.dataset,
                outputPath: context.output,
                checkpointPath: context.checkpoint,
                resumeFrom: context.checkpoint,
                profile: .balanced,
                seed: 42,
                memoryBudgetBytes: testMemoryBudgetBytes,
                onLog: { _, _ in }
            )
            XCTFail("Expected resumable interruption")
        } catch let interruption as MsplatTrainingInterrupted {
            XCTAssertEqual(interruption.completedIteration, 500)
            XCTAssertEqual(interruption.checkpoint, receipt)
            XCTAssertEqual(
                interruption.checkpoint.rasterPeakExactIntersectionCapacity,
                2_305
            )
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: context.output.path))
        XCTAssertFalse(try containsStagingOutput(in: context.output.deletingLastPathComponent()))
    }

    func testCancellationAfterCompletedEventStreamStaysCancellation() async throws {
        let context = try makeContext()
        defer { context.cleanup() }

        do {
            _ = try await MsplatRunner(
                runner: CancellingSubprocessRunner(events: validEvents())
            ).runTrain(
                msplatPath: context.executable,
                datasetPath: context.dataset,
                outputPath: context.output,
                checkpointPath: context.checkpoint,
                profile: .balanced,
                seed: 42,
                memoryBudgetBytes: testMemoryBudgetBytes,
                onLog: { _, _ in }
            )
            XCTFail("Expected cancellation to win the completion race")
        } catch is CancellationError {
        } catch {
            XCTFail("Expected CancellationError, got \(error)")
        }
    }

    func testCancellationAfterResumeRejectionStaysCancellation() async throws {
        let context = try makeContext()
        defer { context.cleanup() }
        try FileManager.default.createDirectory(
            at: context.checkpoint,
            withIntermediateDirectories: true
        )
        let event = "{\"event\":\"resume_rejected\",\"reason\":\"input_changed\",\"schema_version\":2,\"sequence\":1}\n"

        do {
            _ = try await MsplatRunner(
                runner: CancellingSubprocessRunner(events: event)
            ).runTrain(
                msplatPath: context.executable,
                datasetPath: context.dataset,
                outputPath: context.output,
                checkpointPath: context.checkpoint,
                resumeFrom: context.checkpoint,
                profile: .balanced,
                seed: 42,
                memoryBudgetBytes: testMemoryBudgetBytes,
                onLog: { _, _ in }
            )
            XCTFail("Expected cancellation to win the resume-rejection race")
        } catch is CancellationError {
        } catch {
            XCTFail("Expected CancellationError, got \(error)")
        }
    }

    func testCancelledRunRejectsTamperedCheckpointEvidence() async throws {
        let context = try makeContext()
        defer { context.cleanup() }
        let receipt = try makeMsplatCheckpointFixture(at: context.checkpoint, iteration: 500)
        let payload = context.checkpoint
            .appendingPathComponent("generations/\(receipt.generation)/state.msplat")
        let handle = try FileHandle(forWritingTo: payload)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("tamper".utf8))
        try handle.close()

        do {
            _ = try await MsplatRunner(
                runner: CancellingSubprocessRunner(
                    events: interruptedEvents(checkpoint: receipt, currentIteration: 575)
                )
            ).runTrain(
                msplatPath: context.executable,
                datasetPath: context.dataset,
                outputPath: context.output,
                checkpointPath: context.checkpoint,
                resumeFrom: context.checkpoint,
                profile: .balanced,
                seed: 42,
                memoryBudgetBytes: testMemoryBudgetBytes,
                onLog: { _, _ in }
            )
            XCTFail("Expected checkpoint validation failure")
        } catch is MsplatTrainingInterrupted {
            XCTFail("Tampered checkpoint must not be reported as resumable")
        } catch {
            XCTAssertTrue(error.localizedDescription.lowercased().contains("checkpoint"))
        }
    }

    func testResumePreflightAcceptsCurrentBoundCheckpoint() throws {
        let context = try makeContext()
        defer { context.cleanup() }
        let receipt = try makeMsplatCheckpointFixture(at: context.checkpoint, iteration: 500)

        XCTAssertEqual(
            try MsplatCheckpointValidator.validateResume(
                checkpointURL: context.checkpoint,
                artifact: checkpointedArtifact(for: receipt)
            ),
            receipt
        )
    }

    func testResumePreflightRejectsCheckpointWithoutMeasuredPeakMemory() throws {
        let context = try makeContext()
        defer { context.cleanup() }
        let receipt = try makeMsplatCheckpointFixture(at: context.checkpoint, iteration: 500)
        var artifact = checkpointedArtifact(for: receipt)
        artifact.peakMemoryBytes = 0

        XCTAssertThrowsError(
            try MsplatCheckpointValidator.validateResume(
                checkpointURL: context.checkpoint,
                artifact: artifact
            )
        )
    }

    func testResumePreflightRejectsFallbackCountsBeyondCheckpointIterationAndNativeRange() throws {
        for invalidCount in [501, Int(UInt32.max) + 1] {
            let context = try makeContext()
            defer { context.cleanup() }
            let receipt = try makeMsplatCheckpointFixture(
                at: context.checkpoint,
                iteration: 500,
                rasterFallbackCount: invalidCount
            )

            XCTAssertThrowsError(
                try MsplatCheckpointValidator.validateResume(
                    checkpointURL: context.checkpoint,
                    artifact: checkpointedArtifact(for: receipt)
                ),
                "Accepted raster fallback count \(invalidCount) at iteration 500"
            )
        }
    }

    func testResumePreflightRejectsImpossibleRasterRecoveryHistory() throws {
        let context = try makeContext()
        defer { context.cleanup() }
        let receipt = try makeMsplatCheckpointFixture(
            at: context.checkpoint,
            iteration: 500,
            rasterFallbackCount: 1,
            exactFallbackElapsedSeconds: 0,
            exactBufferGrowthCount: 0,
            exactBufferBytesAdded: 0,
            replayElapsedSeconds: 0,
            peakExactIntersectionCapacity: 0
        )

        XCTAssertThrowsError(
            try MsplatCheckpointValidator.validateResume(
                checkpointURL: context.checkpoint,
                artifact: checkpointedArtifact(for: receipt)
            )
        )
    }

    func testResumePreflightRejectsRasterTimingsBeyondCheckpointElapsedTime() throws {
        for (exact, replay) in [(1.26, 0.5), (0.25, 1.26)] {
            let context = try makeContext()
            defer { context.cleanup() }
            let receipt = try makeMsplatCheckpointFixture(
                at: context.checkpoint,
                iteration: 500,
                rasterFallbackCount: 1,
                exactFallbackElapsedSeconds: exact,
                replayElapsedSeconds: replay,
                checkpointElapsedSeconds: 1.25
            )

            XCTAssertThrowsError(
                try MsplatCheckpointValidator.validateResume(
                    checkpointURL: context.checkpoint,
                    artifact: checkpointedArtifact(for: receipt)
                ),
                "Accepted exact=\(exact), replay=\(replay) beyond checkpoint elapsed time"
            )
        }
    }

    func testResumePreflightBoundsRasterAllocationEvidence() throws {
        let invalidCases: [(bytes: Int64, growths: Int, peak: Int64)] = [
            (testMemoryBudgetBytes + 1, 1, 4_096),
            (65_536, 1, Int64(UInt32.max) + 1),
        ]
        for values in invalidCases {
            let context = try makeContext()
            defer { context.cleanup() }
            let receipt = try makeMsplatCheckpointFixture(
                at: context.checkpoint,
                iteration: 500,
                rasterFallbackCount: 3,
                exactBufferGrowthCount: values.growths,
                exactBufferBytesAdded: values.bytes,
                peakExactIntersectionCapacity: values.peak
            )
            XCTAssertThrowsError(
                try MsplatCheckpointValidator.validateResume(
                    checkpointURL: context.checkpoint,
                    artifact: checkpointedArtifact(for: receipt)
                )
            )
        }
    }

    func testResumePreflightAllowsCumulativeAllocationAcrossGrowths() throws {
        let context = try makeContext()
        defer { context.cleanup() }
        let receipt = try makeMsplatCheckpointFixture(
            at: context.checkpoint,
            iteration: 500,
            rasterFallbackCount: 3,
            exactBufferGrowthCount: 2,
            exactBufferBytesAdded: testMemoryBudgetBytes + 1
        )

        XCTAssertEqual(
            try MsplatCheckpointValidator.validateResume(
                checkpointURL: context.checkpoint,
                artifact: checkpointedArtifact(for: receipt)
            ),
            receipt
        )
    }

    func testResumePreflightRejectsSymlinkedGenerationsDirectory() throws {
        let context = try makeContext()
        defer { context.cleanup() }
        let receipt = try makeMsplatCheckpointFixture(at: context.checkpoint, iteration: 500)
        let generations = context.checkpoint.appendingPathComponent("generations", isDirectory: true)
        let outside = context.root.appendingPathComponent("outside-generations", isDirectory: true)
        try FileManager.default.moveItem(at: generations, to: outside)
        try FileManager.default.createSymbolicLink(at: generations, withDestinationURL: outside)

        XCTAssertThrowsError(
            try MsplatCheckpointValidator.validateResume(
                checkpointURL: context.checkpoint,
                artifact: checkpointedArtifact(for: receipt)
            )
        )
    }
}

private extension MsplatRunner {
    func runTrain(
        msplatPath: URL,
        datasetPath: URL,
        outputPath: URL,
        checkpointPath: URL? = nil,
        resumeFrom: URL? = nil,
        profile: DetailProfile,
        seed: UInt64,
        iterationLimit: Int? = nil,
        plateauWindow: Int? = nil,
        memoryBudgetBytes: Int64,
        onProgress: @escaping @Sendable (MsplatTrainingProgress) -> Void = { _ in },
        onCheckpoint: @escaping @Sendable (MsplatCheckpointReceipt) -> Void = { _ in },
        onRasterFallback: @escaping @Sendable (MsplatRasterFallback) -> Void = { _ in },
        onLog: @escaping @Sendable (String, Bool) -> Void
    ) async throws -> MsplatTrainingResult {
        try await runTrain(
            msplatPath: msplatPath,
            datasetPath: datasetPath,
            outputPath: outputPath,
            expectedIdentity: testDatasetIdentity,
            checkpointPath: checkpointPath,
            resumeFrom: resumeFrom,
            profile: profile,
            seed: seed,
            iterationLimit: iterationLimit,
            plateauWindow: plateauWindow,
            memoryBudgetBytes: memoryBudgetBytes,
            onProgress: onProgress,
            onCheckpoint: onCheckpoint,
            onRasterFallback: onRasterFallback,
            onLog: onLog
        )
    }
}

private struct MsplatTestContext {
    let root: URL
    let executable: URL
    let dataset: URL
    let output: URL
    let checkpoint: URL
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
        checkpoint: root.appendingPathComponent("nested/out/checkpoint", isDirectory: true),
        runner: MsplatRunner(runner: MockSubprocessRunner(scripts: []))
    )
}

private func successfulMock(context: MsplatTestContext) -> MockSubprocessRunner {
    MockSubprocessRunner(scripts: [
        .init(
            path: context.executable.path,
            argsPrefix: ["--dataset", context.dataset.path],
            result: .init(exitCode: 0, terminationReason: .exit, stdout: validEvents(), stderr: ""),
            onRun: { arguments in try? writeFixtureOutput(arguments: arguments) }
        ),
    ])
}

private func argumentValue(_ name: String, in arguments: [String]) -> String? {
    guard let index = arguments.firstIndex(of: name), index + 1 < arguments.count else {
        return nil
    }
    return arguments[index + 1]
}

private func writeFixtureOutput(arguments: [String]) throws {
    let outputPath = try XCTUnwrap(argumentValue("--output", in: arguments))
    let output = URL(fileURLWithPath: outputPath)
    try FileManager.default.createDirectory(
        at: output.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    try fixtureOutputData.write(to: output)
}

private func containsStagingOutput(in directory: URL) throws -> Bool {
    try FileManager.default.contentsOfDirectory(
        at: directory,
        includingPropertiesForKeys: nil
    ).contains { $0.lastPathComponent.hasSuffix(".training.tmp.ply") }
}

private func validEvents(
    profile: String = "balanced",
    limit: Int = 7_000,
    plateau: Int = 800,
    seed: UInt64 = 42,
    includeProgressLoss: Bool = true,
    startIteration: Int = 0,
    resumed: Bool = false,
    checkpoint: MsplatCheckpointReceipt? = nil,
    checkpointPeakMemoryBytes: Int64? = testCheckpointPeakMemoryBytes,
    completionPeakMemoryBytes: Int64? = testCompletionPeakMemoryBytes,
    rasterFallbackCount: Int = 0,
    includeRasterReplay: Bool = false,
    droppedIntersectionCount: Int = 0,
    memoryBudgetBytes: Int64 = testMemoryBudgetBytes
) -> String {
    let checkpoint = checkpoint ?? MsplatCheckpointReceipt(
        iteration: 0,
        generation: "00000000-\(testGenerationDigest)",
        payloadSHA256: testPayloadDigest,
        payloadBytes: 128,
        gaussianCount: 750,
        peakMemoryBytes: testCheckpointPeakMemoryBytes,
        memoryBudgetBytes: memoryBudgetBytes,
        rasterFallbackCount: 0,
        rasterExactFallbackElapsedSeconds: 0,
        rasterExactBufferGrowthCount: 0,
        rasterExactBufferBytesAdded: 0,
        rasterReplayElapsedSeconds: 0,
        rasterPeakExactIntersectionCapacity: 0,
        droppedIntersectionCount: 0,
        inputDigest: testInputDigest,
        geometryDigest: testGeometryDigest,
        trainerBuildDigest: testTrainerDigest
    )
    let progressIteration = max(startIteration + 1, (startIteration + limit) / 2)
    let lossFields = includeProgressLoss
        ? ",\"loss\":0.12,\"loss_iteration\":\(progressIteration)"
        : ""
    let checkpointEvent = resumed ? "checkpoint_loaded" : "checkpoint_completed"
    let checkpointMemoryField = checkpointPeakMemoryBytes.map {
        ",\"peak_memory_bytes\":\($0)"
    } ?? ""
    let completionMemoryField = completionPeakMemoryBytes.map {
        ",\"peak_memory_bytes\":\($0)"
    } ?? ""
    let replayEvent: String
    let fallbackEvent: String
    let progressSequence: Int
    let completionSequence: Int
    let completedRasterFallbackCount = max(
        rasterFallbackCount,
        checkpoint.rasterFallbackCount
    )
    let addedFallback = completedRasterFallbackCount > checkpoint.rasterFallbackCount
    let completedExactFallbackElapsed = checkpoint.rasterExactFallbackElapsedSeconds
        + (addedFallback ? 0.25 : 0)
    let completedGrowthCount = addedFallback
        ? max(1, checkpoint.rasterExactBufferGrowthCount)
        : checkpoint.rasterExactBufferGrowthCount
    let completedBytesAdded: Int64 = addedFallback
        ? max(65_536, checkpoint.rasterExactBufferBytesAdded)
        : checkpoint.rasterExactBufferBytesAdded
    let completedReplayElapsed = checkpoint.rasterReplayElapsedSeconds
        + (addedFallback && includeRasterReplay ? 0.5 : 0)
    let completedPeakCapacity: Int64 = addedFallback
        ? max(4_096, checkpoint.rasterPeakExactIntersectionCapacity)
        : checkpoint.rasterPeakExactIntersectionCapacity
    if completedRasterFallbackCount > checkpoint.rasterFallbackCount {
        replayEvent = includeRasterReplay
            ? """
            {"budget_bytes":\(memoryBudgetBytes),"camera_index":2,"event":"raster_replay","first_overflow_iteration":12,"intersection_count":4096,"iteration":11,"required_bytes":65536,"schema_version":2,"sequence":3}
            """ + "\n"
            : ""
        let fallbackSequence = includeRasterReplay ? 4 : 3
        fallbackEvent = """
        {"allocation_bytes":65536,"event":"raster_fallback","fallback_count":\(completedRasterFallbackCount),"intersection_count":4096,"iteration":\(progressIteration),"raster_exact_buffer_bytes_added":\(completedBytesAdded),"raster_exact_buffer_growth_count":\(completedGrowthCount),"raster_exact_fallback_elapsed_seconds":\(completedExactFallbackElapsed),"raster_peak_exact_intersection_capacity":\(completedPeakCapacity),"raster_replay_elapsed_seconds":\(completedReplayElapsed),"schema_version":2,"sequence":\(fallbackSequence)}
        """ + "\n"
        progressSequence = fallbackSequence + 1
        completionSequence = fallbackSequence + 2
    } else {
        replayEvent = ""
        fallbackEvent = ""
        progressSequence = 3
        completionSequence = 4
    }
    let startedEvent = """
    {"camera_count":8,"checkpoint_schema":3,"dropped_intersection_count":0,"event":"started","geometry_digest":"\(checkpoint.geometryDigest)","initial_gaussian_count":750,"input_digest":"\(checkpoint.inputDigest)","iteration":\(startIteration),"iteration_limit":\(limit),"memory_budget_bytes":\(memoryBudgetBytes),"payload_schema":2,"plateau_window":\(plateau),"profile":"\(profile)","raster_exact_buffer_bytes_added":\(checkpoint.rasterExactBufferBytesAdded),"raster_exact_buffer_growth_count":\(checkpoint.rasterExactBufferGrowthCount),"raster_exact_fallback_elapsed_seconds":\(checkpoint.rasterExactFallbackElapsedSeconds),"raster_fallback_count":\(checkpoint.rasterFallbackCount),"raster_peak_exact_intersection_capacity":\(checkpoint.rasterPeakExactIntersectionCapacity),"raster_replay_elapsed_seconds":\(checkpoint.rasterReplayElapsedSeconds),"resumed":\(resumed),"schema_version":2,"seed":\(seed),"sequence":1,"trainer_build_digest":"\(checkpoint.trainerBuildDigest)","version":"1.1.3 (git 106499b)"}
    """
    let checkpointRecord = """
    {"checkpoint_generation":"\(checkpoint.generation)","checkpoint_payload_bytes":\(checkpoint.payloadBytes),"checkpoint_payload_sha256":"\(checkpoint.payloadSHA256)","dropped_intersection_count":0,"event":"\(checkpointEvent)","gaussian_count":\(checkpoint.gaussianCount),"geometry_digest":"\(checkpoint.geometryDigest)","input_digest":"\(checkpoint.inputDigest)","iteration":\(checkpoint.iteration)\(checkpointMemoryField),"memory_budget_bytes":\(memoryBudgetBytes),"profile":"\(profile)","raster_exact_buffer_bytes_added":\(checkpoint.rasterExactBufferBytesAdded),"raster_exact_buffer_growth_count":\(checkpoint.rasterExactBufferGrowthCount),"raster_exact_fallback_elapsed_seconds":\(checkpoint.rasterExactFallbackElapsedSeconds),"raster_fallback_count":\(checkpoint.rasterFallbackCount),"raster_peak_exact_intersection_capacity":\(checkpoint.rasterPeakExactIntersectionCapacity),"raster_replay_elapsed_seconds":\(checkpoint.rasterReplayElapsedSeconds),"schema_version":2,"seed":\(seed),"sequence":2,"trainer_build_digest":"\(checkpoint.trainerBuildDigest)","version":"1.1.3 (git 106499b)"}
    """
    let progressRecord = """
    {"elapsed_seconds":2.5,"eta_seconds":2.5,"event":"progress","gaussian_count":1000,"iteration":\(progressIteration),"iteration_limit":\(limit),"iterations_per_second":1400\(lossFields),"schema_version":2,"sequence":\(progressSequence)}
    """
    let completedRecord = """
    {"dropped_intersection_count":\(droppedIntersectionCount),"elapsed_seconds":5,"event":"completed","gaussian_count":1250,"geometry_digest":"\(checkpoint.geometryDigest)","input_digest":"\(checkpoint.inputDigest)","iteration":\(limit),"iteration_limit":\(limit),"memory_budget_bytes":\(memoryBudgetBytes),"output_bytes":\(fixtureOutputData.count)\(completionMemoryField),"plateau_window":\(plateau),"profile":"\(profile)","raster_exact_buffer_bytes_added":\(completedBytesAdded),"raster_exact_buffer_growth_count":\(completedGrowthCount),"raster_exact_fallback_elapsed_seconds":\(completedExactFallbackElapsed),"raster_fallback_count":\(completedRasterFallbackCount),"raster_peak_exact_intersection_capacity":\(completedPeakCapacity),"raster_replay_elapsed_seconds":\(completedReplayElapsed),"scene_center":[1.25,-2.5,3.75],"scene_radius":8.5,"schema_version":2,"seed":\(seed),"sequence":\(completionSequence),"stop_reason":"iteration_limit","trainer_build_digest":"\(checkpoint.trainerBuildDigest)","version":"1.1.3 (git 106499b)"}
    """
    return startedEvent + "\n" + checkpointRecord + "\n" + replayEvent + fallbackEvent
        + progressRecord + "\n" + completedRecord + "\n"
}

private let fixtureOutputData: Data = {
    let body = Array(
        repeating: "0 0 0 1 1 1 -4 -4 -4 1 1 0 0 0",
        count: 1_250
    ).joined(separator: "\n")
    return Data("""
    ply
    format ascii 1.0
    element vertex 1250
    property float x
    property float y
    property float z
    property float f_dc_0
    property float f_dc_1
    property float f_dc_2
    property float scale_0
    property float scale_1
    property float scale_2
    property float opacity
    property float rot_0
    property float rot_1
    property float rot_2
    property float rot_3
    end_header
    \(body)
    """.utf8)
}()
private let testInputDigest = String(repeating: "1", count: 64)
private let testGeometryDigest = String(repeating: "2", count: 64)
private let testTrainerDigest = String(repeating: "3", count: 64)
private let testPayloadDigest = String(repeating: "4", count: 64)
private let testGenerationDigest = String(repeating: "5", count: 64)
private let testDatasetIdentity = MsplatDatasetIdentity(
    inputDigest: testInputDigest,
    geometryDigest: testGeometryDigest
)
private let testCheckpointPeakMemoryBytes: Int64 = 268_435_456
private let testCompletionPeakMemoryBytes: Int64 = 536_870_912
private let testMemoryBudgetBytes: Int64 = 8_589_934_592

private func checkpointedArtifact(for receipt: MsplatCheckpointReceipt) -> TrainingArtifact {
    TrainingArtifact(
        trainerVersion: "1.1.3 (git 106499b)",
        runtimeVersion: "native-metal-cli-v2",
        trainerBuildDigest: receipt.trainerBuildDigest,
        inputDigest: receipt.inputDigest,
        geometryDigest: receipt.geometryDigest,
        detailProfile: .balanced,
        iterationLimit: 7_000,
        plateauWindow: 800,
        cameraOrderSeed: 42,
        completedIteration: receipt.iteration,
        checkpointPath: "Training/checkpoints/msplat",
        checkpointDigest: receipt.payloadSHA256,
        outputPath: nil,
        gaussianCount: receipt.gaussianCount,
        elapsedSeconds: nil,
        peakMemoryBytes: receipt.peakMemoryBytes,
        memoryBudgetBytes: receipt.memoryBudgetBytes,
        rasterFallbackCount: receipt.rasterFallbackCount,
        rasterExactFallbackElapsedSeconds: receipt.rasterExactFallbackElapsedSeconds,
        rasterExactBufferGrowthCount: receipt.rasterExactBufferGrowthCount,
        rasterExactBufferBytesAdded: receipt.rasterExactBufferBytesAdded,
        rasterReplayElapsedSeconds: receipt.rasterReplayElapsedSeconds,
        rasterPeakExactIntersectionCapacity: receipt.rasterPeakExactIntersectionCapacity,
        droppedIntersectionCount: receipt.droppedIntersectionCount,
        completionStatus: .checkpointed
    )
}

func makeMsplatCheckpointFixture(
    at root: URL,
    iteration: Int,
    profile: String = "balanced",
    iterationLimit: Int = 7_000,
    plateauWindow: Int = 800,
    inputDigest: String = testInputDigest,
    geometryDigest: String = testGeometryDigest,
    memoryBudgetBytes: Int64 = testMemoryBudgetBytes,
    rasterFallbackCount: Int = 0,
    exactFallbackElapsedSeconds: Double? = nil,
    exactBufferGrowthCount: Int? = nil,
    exactBufferBytesAdded: Int64? = nil,
    replayElapsedSeconds: Double? = nil,
    peakExactIntersectionCapacity: Int64? = nil,
    checkpointElapsedSeconds: Double = 1.25
) throws -> MsplatCheckpointReceipt {
    let exactFallbackElapsedSeconds = exactFallbackElapsedSeconds
        ?? (rasterFallbackCount > 0 ? 0.25 : 0)
    let exactBufferGrowthCount = exactBufferGrowthCount ?? (rasterFallbackCount > 0 ? 1 : 0)
    let exactBufferBytesAdded = exactBufferBytesAdded ?? (rasterFallbackCount > 0 ? 65_536 : 0)
    let replayElapsedSeconds = replayElapsedSeconds ?? (rasterFallbackCount > 0 ? 0.5 : 0)
    let peakExactIntersectionCapacity = peakExactIntersectionCapacity
        ?? (rasterFallbackCount > 0 ? 4_096 : 0)
    let fileManager = FileManager.default
    let generations = root.appendingPathComponent("generations", isDirectory: true)
    try fileManager.createDirectory(at: generations, withIntermediateDirectories: true)
    let payload = Data("checkpoint-state-\(iteration)".utf8)
    let payloadDigest = SHA256.hash(data: payload).hexString
    let manifestObject: [String: Any] = [
        "backing_capacity": 3_000,
        "best_camera_losses": Array(repeating: NSNull(), count: 8),
        "camera_count": 8,
        "camera_draw_count": iteration,
        "dropped_intersection_count": 0,
        "elapsed_seconds": checkpointElapsedSeconds,
        "gaussian_count": 750,
        "geometry_digest": geometryDigest,
        "input_digest": inputDigest,
        "iteration": iteration,
        "iteration_limit": iterationLimit,
        "last_improvement_iteration": 500,
        "latest_loss": NSNull(),
        "latest_loss_iteration": 0,
        "memory_budget_bytes": memoryBudgetBytes,
        "payload_bytes": payload.count,
        "payload_file": "state.msplat",
        "payload_schema": 2,
        "payload_sha256": payloadDigest,
        "plateau_window": plateauWindow,
        "profile": profile,
        "raster_exact_buffer_bytes_added": exactBufferBytesAdded,
        "raster_exact_buffer_growth_count": exactBufferGrowthCount,
        "raster_exact_fallback_elapsed_seconds": exactFallbackElapsedSeconds,
        "raster_fallback_count": rasterFallbackCount,
        "raster_peak_exact_intersection_capacity": peakExactIntersectionCapacity,
        "raster_replay_elapsed_seconds": replayElapsedSeconds,
        "schema_version": 3,
        "seed": 42,
        "trainer_build_digest": testTrainerDigest,
        "trainer_version": "1.1.3 (git 106499b)",
    ]
    var manifest = try JSONSerialization.data(
        withJSONObject: manifestObject,
        options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    )
    manifest.append(0x0a)
    let generation = String(format: "%08d", iteration) + "-" + SHA256.hash(data: manifest).hexString
    let generationURL = generations.appendingPathComponent(generation, isDirectory: true)
    try fileManager.createDirectory(at: generationURL, withIntermediateDirectories: false)
    try payload.write(to: generationURL.appendingPathComponent("state.msplat"))
    try manifest.write(to: generationURL.appendingPathComponent("manifest.json"))
    try Data("\(generation)\n".utf8).write(to: root.appendingPathComponent("CURRENT"))
    return MsplatCheckpointReceipt(
        iteration: iteration,
        generation: generation,
        payloadSHA256: payloadDigest,
        payloadBytes: Int64(payload.count),
        gaussianCount: 750,
        peakMemoryBytes: testCheckpointPeakMemoryBytes,
        memoryBudgetBytes: memoryBudgetBytes,
        rasterFallbackCount: rasterFallbackCount,
        rasterExactFallbackElapsedSeconds: exactFallbackElapsedSeconds,
        rasterExactBufferGrowthCount: exactBufferGrowthCount,
        rasterExactBufferBytesAdded: exactBufferBytesAdded,
        rasterReplayElapsedSeconds: replayElapsedSeconds,
        rasterPeakExactIntersectionCapacity: peakExactIntersectionCapacity,
        droppedIntersectionCount: 0,
        inputDigest: inputDigest,
        geometryDigest: geometryDigest,
        trainerBuildDigest: testTrainerDigest
    )
}

private func interruptedEvents(
    checkpoint: MsplatCheckpointReceipt,
    currentIteration: Int
) -> String {
    """
    {"camera_count":8,"checkpoint_schema":3,"event":"started","geometry_digest":"\(checkpoint.geometryDigest)","initial_gaussian_count":750,"input_digest":"\(checkpoint.inputDigest)","iteration":\(checkpoint.iteration),"iteration_limit":7000,"memory_budget_bytes":\(checkpoint.memoryBudgetBytes),"payload_schema":2,"plateau_window":800,"profile":"balanced","raster_exact_buffer_bytes_added":\(checkpoint.rasterExactBufferBytesAdded),"raster_exact_buffer_growth_count":\(checkpoint.rasterExactBufferGrowthCount),"raster_exact_fallback_elapsed_seconds":\(checkpoint.rasterExactFallbackElapsedSeconds),"raster_fallback_count":\(checkpoint.rasterFallbackCount),"raster_peak_exact_intersection_capacity":\(checkpoint.rasterPeakExactIntersectionCapacity),"raster_replay_elapsed_seconds":\(checkpoint.rasterReplayElapsedSeconds),"resumed":true,"schema_version":2,"seed":42,"sequence":1,"trainer_build_digest":"\(checkpoint.trainerBuildDigest)","version":"1.1.3 (git 106499b)"}
    {"checkpoint_generation":"\(checkpoint.generation)","checkpoint_payload_bytes":\(checkpoint.payloadBytes),"checkpoint_payload_sha256":"\(checkpoint.payloadSHA256)","dropped_intersection_count":0,"event":"checkpoint_loaded","gaussian_count":\(checkpoint.gaussianCount),"geometry_digest":"\(checkpoint.geometryDigest)","input_digest":"\(checkpoint.inputDigest)","iteration":\(checkpoint.iteration),"memory_budget_bytes":\(checkpoint.memoryBudgetBytes),"peak_memory_bytes":\(checkpoint.peakMemoryBytes),"profile":"balanced","raster_exact_buffer_bytes_added":\(checkpoint.rasterExactBufferBytesAdded),"raster_exact_buffer_growth_count":\(checkpoint.rasterExactBufferGrowthCount),"raster_exact_fallback_elapsed_seconds":\(checkpoint.rasterExactFallbackElapsedSeconds),"raster_fallback_count":\(checkpoint.rasterFallbackCount),"raster_peak_exact_intersection_capacity":\(checkpoint.rasterPeakExactIntersectionCapacity),"raster_replay_elapsed_seconds":\(checkpoint.rasterReplayElapsedSeconds),"schema_version":2,"seed":42,"sequence":2,"trainer_build_digest":"\(checkpoint.trainerBuildDigest)","version":"1.1.3 (git 106499b)"}
    {"event":"cancellation_requested","iteration":\(currentIteration),"schema_version":2,"sequence":3,"signal":2}
    {"checkpoint_generation":"\(checkpoint.generation)","checkpoint_iteration":\(checkpoint.iteration),"checkpoint_payload_sha256":"\(checkpoint.payloadSHA256)","dropped_intersection_count":0,"event":"cancelled","geometry_digest":"\(checkpoint.geometryDigest)","input_digest":"\(checkpoint.inputDigest)","iteration":\(currentIteration),"memory_budget_bytes":\(checkpoint.memoryBudgetBytes),"raster_exact_buffer_bytes_added":\(checkpoint.rasterExactBufferBytesAdded),"raster_exact_buffer_growth_count":\(checkpoint.rasterExactBufferGrowthCount),"raster_exact_fallback_elapsed_seconds":\(checkpoint.rasterExactFallbackElapsedSeconds),"raster_fallback_count":\(checkpoint.rasterFallbackCount),"raster_peak_exact_intersection_capacity":\(checkpoint.rasterPeakExactIntersectionCapacity),"raster_replay_elapsed_seconds":\(checkpoint.rasterReplayElapsedSeconds),"schema_version":2,"sequence":4}
    """ + "\n"
}

private final class CancellingSubprocessRunner: @unchecked Sendable, SubprocessRunning {
    private let events: String

    init(events: String) {
        self.events = events
    }

    func run(
        _ launchPath: String,
        _ arguments: [String],
        currentDirectory: URL?,
        environment: [String: String],
        removingEnvironmentKeys: Set<String>,
        onStdout: @escaping @Sendable (String) -> Void,
        onStderr: @escaping @Sendable (String) -> Void
    ) throws -> SubprocessResult {
        throw CancellationError()
    }

    func runAsync(
        _ launchPath: String,
        _ arguments: [String],
        currentDirectory: URL?,
        environment: [String: String],
        removingEnvironmentKeys: Set<String>,
        onStdout: @escaping @Sendable (String) -> Void,
        onStderr: @escaping @Sendable (String) -> Void
    ) async throws -> SubprocessResult {
        for line in events.split(whereSeparator: \.isNewline) {
            onStdout(String(line))
        }
        throw CancellationError()
    }
}

private extension Digest {
    var hexString: String {
        map { String(format: "%02x", $0) }.joined()
    }
}

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
