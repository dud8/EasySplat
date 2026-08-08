#if canImport(XCTest)
import Foundation
import XCTest
@testable import EasySplatApp
@testable import EasySplatCore

@MainActor
final class AppModelMetadataPersistenceTests: XCTestCase {
    func testPipelineMetadataFailureUsesCoreStageInOneCheckedUpdate() async throws {
        let fixture = try makeProjectFixture(stage: .sfmFeatures)
        defer { try? FileManager.default.removeItem(at: fixture.baseURL) }

        let updateProbe = MetadataUpdateProbe()
        let coreFailure = makePersistenceFailure(
            operation: .stageCompletion,
            stage: .sfmMapping
        )
        let model = AppModel(
            toolchainManager: MockToolchainManager(),
            projectBaseURL: fixture.baseURL,
            pipelineRunnerFactory: { _, _ in
                MetadataFailurePipelineRunner(failure: coreFailure)
            },
            projectMetadataUpdater: { metadataURL, mutation in
                let updated = try ProjectMetadataStore.update(at: metadataURL, mutation)
                updateProbe.record(updated)
                return updated
            }
        )

        await model.resumeProjectTask(at: fixture.projectURL)

        XCTAssertEqual(updateProbe.callCount, 1)
        XCTAssertEqual(updateProbe.lastMetadata?.state.stage, .sfmMapping)
        XCTAssertEqual(updateProbe.lastMetadata?.state.lastError, "The mapper stopped")
        XCTAssertEqual(model.currentProjectURL, fixture.projectURL)
        XCTAssertEqual(model.viewState, .processing)
        XCTAssertEqual(model.lastError, "The mapper stopped")
        XCTAssertFalse(model.isRunActive)

        let saved = try ProjectMetadataStore.load(from: fixture.paths.metadataURL)
        XCTAssertEqual(saved.state.stage, .sfmMapping)
        XCTAssertEqual(saved.state.lastError, "The mapper stopped")
        XCTAssertNil(saved.checkpoint)
        XCTAssertNil(saved.lastRunStartedAt)
        XCTAssertNotNil(saved.lastFailureAt)
    }

    func testFallbackWriteFailureKeepsProcessingStateAndCancelsPendingExit() async throws {
        let fixture = try makeProjectFixture(stage: .sfmFeatures)
        defer { try? FileManager.default.removeItem(at: fixture.baseURL) }
        let originalBytes = try Data(contentsOf: fixture.paths.metadataURL)

        let updateProbe = MetadataUpdateProbe()
        let trashProbe = TrashProbe()
        let fallbackError = NSError(
            domain: NSPOSIXErrorDomain,
            code: Int(ENOSPC),
            userInfo: [NSLocalizedDescriptionKey: "No space left on device"]
        )
        let coreFailure = makePersistenceFailure(
            operation: .terminalFailure,
            stage: .trainSplat
        )
        weak var weakModel: AppModel?
        let model = AppModel(
            toolchainManager: MockToolchainManager(),
            projectBaseURL: fixture.baseURL,
            pipelineRunnerFactory: { _, _ in
                MetadataFailurePipelineRunner(
                    failure: coreFailure,
                    beforeThrow: {
                        guard let model = weakModel else { return }
                        model.stopAction = .deleteProject
                        model.exitIntent = .quit
                        model.forcedExitTask = Task {
                            try? await Task.sleep(nanoseconds: 60_000_000_000)
                        }
                    }
                )
            },
            projectTrashHandler: { url in
                trashProbe.record(url)
            },
            projectMetadataUpdater: { _, _ in
                updateProbe.recordAttempt()
                throw fallbackError
            }
        )
        weakModel = model
        model.replyToTerminationRequest = { _ in }

        await model.resumeProjectTask(at: fixture.projectURL)

        let expectedMessage = "Project state wasn’t saved. Free up disk space or restore write access, then try again. Work after the last saved stage may repeat."
        XCTAssertEqual(updateProbe.callCount, 1)
        XCTAssertEqual(model.currentProjectURL, fixture.projectURL)
        XCTAssertEqual(model.viewState, .processing)
        XCTAssertEqual(model.lastError, expectedMessage)
        XCTAssertEqual(model.statusTitle, expectedMessage)
        XCTAssertNil(model.statusDetail)
        XCTAssertNil(model.progress)
        XCTAssertFalse(model.isRunActive)
        XCTAssertNil(model.stopAction)
        XCTAssertNil(model.forcedExitTask)
        if case .none = model.exitIntent {
            // Expected.
        } else {
            XCTFail("The pending automatic exit was not cancelled")
        }
        XCTAssertTrue(trashProbe.urls.isEmpty)
        XCTAssertEqual(try Data(contentsOf: fixture.paths.metadataURL), originalBytes)
        XCTAssertTrue(model.errorDetails?.contains("terminalFailure") == true)
        XCTAssertTrue(model.errorDetails?.contains("trainSplat") == true)
        XCTAssertTrue(model.errorDetails?.contains("No space left on device") == true)
        XCTAssertTrue(model.errorDetails?.contains("The mapper stopped") == true)
        XCTAssertTrue(model.errorDetails?.contains("COLMAP exited with status 9") == true)
    }

    func testAlreadyPersistedTerminalFailureDoesNotWriteFallbackAgain() async throws {
        let fixture = try makeProjectFixture(stage: .sfmFeatures)
        defer { try? FileManager.default.removeItem(at: fixture.baseURL) }
        _ = try ProjectMetadataStore.update(at: fixture.paths.metadataURL) {
            $0.state = PipelineState(
                stage: .sfmMapping,
                lastError: "The mapper stopped"
            )
            $0.checkpoint = nil
            $0.lastRunStartedAt = nil
            $0.lastFailureAt = Date()
        }

        let updateProbe = MetadataUpdateProbe()
        let coreFailure = makePersistenceFailure(
            operation: .stageCompletion,
            stage: .sfmMapping
        ).recordingPersistedTerminalFailure()
        let model = AppModel(
            toolchainManager: MockToolchainManager(),
            projectBaseURL: fixture.baseURL,
            pipelineRunnerFactory: { _, _ in
                MetadataFailurePipelineRunner(failure: coreFailure)
            },
            projectMetadataUpdater: { metadataURL, mutation in
                updateProbe.recordAttempt()
                return try ProjectMetadataStore.update(at: metadataURL, mutation)
            }
        )

        await model.resumeProjectTask(at: fixture.projectURL)

        XCTAssertEqual(updateProbe.callCount, 0)
        XCTAssertEqual(model.lastError, "The mapper stopped")
        XCTAssertNotEqual(
            model.statusTitle,
            "Project state wasn’t saved. Free up disk space or restore write access, then try again. Work after the last saved stage may repeat."
        )
        let persisted = try ProjectMetadataStore.load(
            from: fixture.paths.metadataURL
        )
        XCTAssertEqual(persisted.state.stage, .sfmMapping)
        XCTAssertEqual(persisted.state.lastError, "The mapper stopped")
    }

    func testOrdinaryRunnerFailureDoesNotPerformStageLessFallbackWrite() async throws {
        let fixture = try makeProjectFixture(stage: .sfmFeatures)
        defer { try? FileManager.default.removeItem(at: fixture.baseURL) }
        _ = try ProjectMetadataStore.update(at: fixture.paths.metadataURL) {
            $0.state = PipelineState(
                stage: .sfmMapping,
                lastError: "The camera solve was unstable"
            )
            $0.checkpoint = nil
            $0.lastRunStartedAt = nil
            $0.lastFailureAt = Date()
        }
        let updateProbe = MetadataUpdateProbe()
        let runnerError = NSError(
            domain: "AppModelMetadataPersistenceTests",
            code: 91,
            userInfo: [
                NSLocalizedDescriptionKey: "The camera solve was unstable",
            ]
        )
        let model = AppModel(
            toolchainManager: MockToolchainManager(),
            projectBaseURL: fixture.baseURL,
            pipelineRunnerFactory: { _, _ in
                MetadataFailurePipelineRunner(failure: runnerError)
            },
            projectMetadataUpdater: { metadataURL, mutation in
                updateProbe.recordAttempt()
                return try ProjectMetadataStore.update(at: metadataURL, mutation)
            }
        )

        await model.resumeProjectTask(at: fixture.projectURL)

        XCTAssertEqual(
            updateProbe.callCount,
            0,
            "Core owns terminal persistence after runner start."
        )
        let persisted = try ProjectMetadataStore.load(
            from: fixture.paths.metadataURL
        )
        XCTAssertEqual(persisted.state.stage, .sfmMapping)
        XCTAssertEqual(
            persisted.state.lastError,
            "The camera solve was unstable"
        )
    }

    func testOutputMissingFailureDoesNotSwallowFallbackWriteFailure() throws {
        let fixture = try makeProjectFixture(stage: .done)
        defer { try? FileManager.default.removeItem(at: fixture.baseURL) }
        let fallbackError = NSError(
            domain: NSPOSIXErrorDomain,
            code: Int(EACCES),
            userInfo: [NSLocalizedDescriptionKey: "Permission denied"]
        )
        let updateProbe = MetadataUpdateProbe()
        let model = AppModel(
            toolchainManager: MockToolchainManager(),
            projectBaseURL: fixture.baseURL,
            projectMetadataUpdater: { _, _ in
                updateProbe.recordAttempt()
                throw fallbackError
            }
        )

        model.presentOutputMissingFailure(projectURL: fixture.projectURL)

        let expected = "Project state wasn’t saved. Free up disk space or restore write access, then try again. Work after the last saved stage may repeat."
        XCTAssertEqual(updateProbe.callCount, 1)
        XCTAssertEqual(model.lastError, expected)
        XCTAssertEqual(model.statusTitle, expected)
        XCTAssertEqual(model.viewState, .processing)
        XCTAssertTrue(
            model.errorDetails?.contains("could not find a valid output PLY") == true
        )
        XCTAssertTrue(model.errorDetails?.contains("Permission denied") == true)
    }

    private func makePersistenceFailure(
        operation: PipelineMetadataWriteOperation,
        stage: PipelineStage
    ) -> PipelineMetadataPersistenceFailure {
        PipelineMetadataPersistenceFailure(
            operation: operation,
            stage: stage,
            persistenceError: NSError(
                domain: NSPOSIXErrorDomain,
                code: Int(EACCES),
                userInfo: [NSLocalizedDescriptionKey: "Permission denied"]
            ),
            originalProcessingFailure: PipelinePresentedProcessingFailure(
                userMessage: "The mapper stopped",
                technicalMessage: "COLMAP exited with status 9"
            )
        )
    }

    private func makeProjectFixture(
        stage: PipelineStage
    ) throws -> (baseURL: URL, projectURL: URL, paths: ProjectPaths) {
        let baseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let projectURL = baseURL
            .appendingPathComponent("Metadata Failure.easysplatproj", isDirectory: true)
        try FileManager.default.createDirectory(
            at: projectURL,
            withIntermediateDirectories: true
        )
        let paths = ProjectPaths(root: projectURL)
        try paths.ensureDirectories()
        var metadata = ProjectMetadata(
            title: "Metadata Failure",
            input: .video(files: []),
            requestedRunOptions: RequestedRunOptions(
                capturePath: .orbit,
                detailProfile: .balanced
            ),
            state: PipelineState(stage: stage, lastError: nil),
            checkpoint: PipelineCheckpoint(
                stage: stage,
                updatedAt: Date(timeIntervalSince1970: 1_700_000_000),
                progressFraction: 0.5,
                message: "Saved work",
                details: nil
            ),
            lastRunStartedAt: Date(timeIntervalSince1970: 1_700_000_100)
        )
        metadata.resolvedRunPlan = RunPlanResolver.resolve(
            requestedOptions: metadata.requestedRunOptions,
            input: metadata.input,
            hardware: HardwareProfile(memoryGB: 48, cpuCount: 16, gpuWorkingSetGB: 36),
            developmentOverrides: .none
        )
        try ProjectMetadataStore.save(metadata, to: paths.metadataURL)
        return (baseURL, projectURL, paths)
    }
}

private final class MetadataFailurePipelineRunner: PipelineRunning {
    private let failure: Error
    private let beforeThrow: @MainActor () -> Void

    init(
        failure: Error,
        beforeThrow: @escaping @MainActor () -> Void = {}
    ) {
        self.failure = failure
        self.beforeThrow = beforeThrow
    }

    func run(
        resumeFrom lastCompletedStage: PipelineStage?,
        events: @escaping @Sendable (PipelineEvent) -> Void
    ) async throws {
        await beforeThrow()
        throw failure
    }
}

private final class MetadataUpdateProbe {
    private(set) var callCount = 0
    private(set) var lastMetadata: ProjectMetadata?

    func record(_ metadata: ProjectMetadata) {
        callCount += 1
        lastMetadata = metadata
    }

    func recordAttempt() {
        callCount += 1
    }
}

private final class TrashProbe {
    private(set) var urls: [URL] = []

    func record(_ url: URL) {
        urls.append(url)
    }
}
#endif
