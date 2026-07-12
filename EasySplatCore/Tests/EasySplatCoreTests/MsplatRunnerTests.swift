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
                        "--checkpoint", context.checkpoint.path,
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
                onRun: { _ in TestFileBuilder.createFile(at: context.output, data: fixtureOutputData) }
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
            onLog: { _, _ in }
        )

        XCTAssertEqual(result.iterationLimit, 123)
        XCTAssertEqual(result.plateauWindow, 50)
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
                    "--checkpoint", context.checkpoint.path,
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

    func testRunTrainReportsTypedResumeRejectionBeforeStarted() async throws {
        for reason in MsplatResumeRejectionReason.allCases {
            let context = try makeContext()
            defer { context.cleanup() }
            try FileManager.default.createDirectory(
                at: context.checkpoint,
                withIntermediateDirectories: true
            )
            let stdout = """
            {"event":"resume_rejected","reason":"\(reason.rawValue)","schema_version":1,"sequence":1}
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
                    stdout: "{\"event\":\"resume_rejected\",\"reason\":\"geometry_changed\",\"schema_version\":1,\"sequence\":1}\n",
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
                    stdout: "{\"event\":\"resume_rejected\",\"reason\":\"trainer_changed\",\"schema_version\":1,\"sequence\":1}\n",
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
                argsPrefix: [
                    "--dataset", context.dataset.path,
                    "--output", context.output.path,
                    "--profile", "balanced",
                    "--checkpoint", context.checkpoint.path,
                    "--seed", "42",
                    "--events-fd", "1",
                    "--resume", context.checkpoint.path,
                ],
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
                onRun: { _ in TestFileBuilder.createFile(at: context.output, data: fixtureOutputData) }
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
            onLog: { _, _ in }
        )

        XCTAssertEqual(result.latestCheckpoint, receipt)
        XCTAssertEqual(result.inputDigest, receipt.inputDigest)
        XCTAssertEqual(result.geometryDigest, receipt.geometryDigest)
        XCTAssertEqual(mock.calls.count, 1)
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
                onCheckpoint: { receipt in checkpointEvents.withValue { $0.append(receipt) } },
                onLog: { _, _ in }
            )
            XCTFail("Expected resumable interruption")
        } catch let interruption as MsplatTrainingInterrupted {
            XCTAssertEqual(interruption.completedIteration, 575)
            XCTAssertEqual(interruption.checkpoint, receipt)
        }
        XCTAssertEqual(checkpointEvents.value, [receipt])
        XCTAssertFalse(FileManager.default.fileExists(atPath: context.output.path))
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
        let event = "{\"event\":\"resume_rejected\",\"reason\":\"input_changed\",\"schema_version\":1,\"sequence\":1}\n"

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
            onRun: { _ in TestFileBuilder.createFile(at: context.output, data: fixtureOutputData) }
        ),
    ])
}

private func validEvents(
    profile: String = "balanced",
    limit: Int = 7_000,
    plateau: Int = 800,
    seed: UInt64 = 42,
    includeProgressLoss: Bool = true,
    startIteration: Int = 0,
    resumed: Bool = false,
    checkpoint: MsplatCheckpointReceipt? = nil
) -> String {
    let checkpoint = checkpoint ?? MsplatCheckpointReceipt(
        iteration: 0,
        generation: "00000000-\(testGenerationDigest)",
        payloadSHA256: testPayloadDigest,
        payloadBytes: 128,
        gaussianCount: 750,
        inputDigest: testInputDigest,
        geometryDigest: testGeometryDigest,
        trainerBuildDigest: testTrainerDigest
    )
    let progressIteration = max(startIteration + 1, (startIteration + limit) / 2)
    let lossFields = includeProgressLoss
        ? ",\"loss\":0.12,\"loss_iteration\":\(progressIteration)"
        : ""
    let checkpointEvent = resumed ? "checkpoint_loaded" : "checkpoint_completed"
    return """
    {"camera_count":8,"checkpoint_schema":1,"event":"started","geometry_digest":"\(checkpoint.geometryDigest)","initial_gaussian_count":750,"input_digest":"\(checkpoint.inputDigest)","iteration":\(startIteration),"iteration_limit":\(limit),"payload_schema":2,"plateau_window":\(plateau),"profile":"\(profile)","resumed":\(resumed),"schema_version":1,"seed":\(seed),"sequence":1,"trainer_build_digest":"\(checkpoint.trainerBuildDigest)","version":"1.1.3 (git 106499b)"}
    {"checkpoint_generation":"\(checkpoint.generation)","checkpoint_payload_bytes":\(checkpoint.payloadBytes),"checkpoint_payload_sha256":"\(checkpoint.payloadSHA256)","event":"\(checkpointEvent)","gaussian_count":\(checkpoint.gaussianCount),"geometry_digest":"\(checkpoint.geometryDigest)","input_digest":"\(checkpoint.inputDigest)","iteration":\(checkpoint.iteration),"profile":"\(profile)","schema_version":1,"seed":\(seed),"sequence":2,"trainer_build_digest":"\(checkpoint.trainerBuildDigest)","version":"1.1.3 (git 106499b)"}
    {"elapsed_seconds":2.5,"eta_seconds":2.5,"event":"progress","gaussian_count":1000,"iteration":\(progressIteration),"iteration_limit":\(limit),"iterations_per_second":1400\(lossFields),"schema_version":1,"sequence":3}
    {"elapsed_seconds":5,"event":"completed","gaussian_count":1250,"geometry_digest":"\(checkpoint.geometryDigest)","input_digest":"\(checkpoint.inputDigest)","iteration":\(limit),"iteration_limit":\(limit),"output_bytes":4096,"plateau_window":\(plateau),"profile":"\(profile)","schema_version":1,"seed":\(seed),"sequence":4,"stop_reason":"iteration_limit","trainer_build_digest":"\(checkpoint.trainerBuildDigest)","version":"1.1.3 (git 106499b)"}
    """ + "\n"
}

private let fixtureOutputData = Data(repeating: 0, count: 4_096)
private let testInputDigest = String(repeating: "1", count: 64)
private let testGeometryDigest = String(repeating: "2", count: 64)
private let testTrainerDigest = String(repeating: "3", count: 64)
private let testPayloadDigest = String(repeating: "4", count: 64)
private let testGenerationDigest = String(repeating: "5", count: 64)

private func checkpointedArtifact(for receipt: MsplatCheckpointReceipt) -> TrainingArtifact {
    TrainingArtifact(
        trainerVersion: "1.1.3 (git 106499b)",
        runtimeVersion: "native-metal-cli-v1",
        trainerBuildDigest: receipt.trainerBuildDigest,
        inputDigest: receipt.inputDigest,
        geometryDigest: receipt.geometryDigest,
        detailProfile: .balanced,
        iterationLimit: 7_000,
        plateauWindow: 800,
        deterministicSeed: 42,
        completedIteration: receipt.iteration,
        checkpointPath: "Training/checkpoints/msplat",
        checkpointDigest: receipt.payloadSHA256,
        outputPath: nil,
        gaussianCount: receipt.gaussianCount,
        elapsedSeconds: nil,
        peakMemoryBytes: nil,
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
    geometryDigest: String = testGeometryDigest
) throws -> MsplatCheckpointReceipt {
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
        "elapsed_seconds": 1.25,
        "gaussian_count": 750,
        "geometry_digest": geometryDigest,
        "input_digest": inputDigest,
        "iteration": iteration,
        "iteration_limit": iterationLimit,
        "last_improvement_iteration": 500,
        "latest_loss": NSNull(),
        "latest_loss_iteration": 0,
        "payload_bytes": payload.count,
        "payload_file": "state.msplat",
        "payload_schema": 2,
        "payload_sha256": payloadDigest,
        "plateau_window": plateauWindow,
        "profile": profile,
        "schema_version": 1,
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
    {"camera_count":8,"checkpoint_schema":1,"event":"started","geometry_digest":"\(checkpoint.geometryDigest)","initial_gaussian_count":750,"input_digest":"\(checkpoint.inputDigest)","iteration":\(checkpoint.iteration),"iteration_limit":7000,"payload_schema":2,"plateau_window":800,"profile":"balanced","resumed":true,"schema_version":1,"seed":42,"sequence":1,"trainer_build_digest":"\(checkpoint.trainerBuildDigest)","version":"1.1.3 (git 106499b)"}
    {"checkpoint_generation":"\(checkpoint.generation)","checkpoint_payload_bytes":\(checkpoint.payloadBytes),"checkpoint_payload_sha256":"\(checkpoint.payloadSHA256)","event":"checkpoint_loaded","gaussian_count":\(checkpoint.gaussianCount),"geometry_digest":"\(checkpoint.geometryDigest)","input_digest":"\(checkpoint.inputDigest)","iteration":\(checkpoint.iteration),"profile":"balanced","schema_version":1,"seed":42,"sequence":2,"trainer_build_digest":"\(checkpoint.trainerBuildDigest)","version":"1.1.3 (git 106499b)"}
    {"event":"cancellation_requested","iteration":\(currentIteration),"schema_version":1,"sequence":3,"signal":2}
    {"checkpoint_generation":"\(checkpoint.generation)","checkpoint_iteration":\(checkpoint.iteration),"checkpoint_payload_sha256":"\(checkpoint.payloadSHA256)","event":"cancelled","geometry_digest":"\(checkpoint.geometryDigest)","input_digest":"\(checkpoint.inputDigest)","iteration":\(currentIteration),"schema_version":1,"sequence":4}
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
