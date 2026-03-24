#if canImport(XCTest)
import Foundation
import XCTest
@testable import EasySplatApp
@testable import EasySplatCore

@MainActor
final class AppModelTests: XCTestCase {
    func testStartProjectTransitionsToViewer() async throws {
        let tempBase = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempBase, withIntermediateDirectories: true)
        let input = tempBase.appendingPathComponent("input.mov")
        try Data("video".utf8).write(to: input)

        let mockToolchain = MockToolchainManager()
        let model = AppModel(
            toolchainManager: mockToolchain,
            projectBaseURL: tempBase
        ) { projectURL, config in
            MockPipelineRunner(projectURL: projectURL, config: config)
        }

        model.addInputs(urls: [input])
        model.startFromPendingSelection()

        try await waitForViewState(model: model, state: .viewer)

        XCTAssertEqual(model.viewState, .viewer)
        XCTAssertNotNil(model.currentProjectURL)
        XCTAssertNotNil(model.outputPlyURL)
        guard let projectURL = model.currentProjectURL else {
            XCTFail("Missing project URL")
            return
        }
        let metadataURL = projectURL.appendingPathComponent("project.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: metadataURL.path))
    }

    func testLivePreviewToggleResetsPerProjectStart() async throws {
        let tempBase = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempBase, withIntermediateDirectories: true)
        let input = tempBase.appendingPathComponent("input.mov")
        try Data("video".utf8).write(to: input)

        let mockToolchain = MockToolchainManager()
        let model = AppModel(
            toolchainManager: mockToolchain,
            projectBaseURL: tempBase
        ) { projectURL, config in
            MockPipelineRunner(projectURL: projectURL, config: config)
        }

        model.isLivePreviewEnabled = true
        model.addInputs(urls: [input])
        model.startFromPendingSelection()

        try await waitForViewState(model: model, state: .viewer)

        XCTAssertFalse(model.isLivePreviewEnabled)
    }

    func testAddInputsIgnoresNonVideoAndClearsWarning() {
        let tempBase = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: tempBase, withIntermediateDirectories: true)
        let video = tempBase.appendingPathComponent("input.mov")
        let text = tempBase.appendingPathComponent("note.txt")
        try? Data("video".utf8).write(to: video)
        try? Data("text".utf8).write(to: text)

        let model = AppModel(toolchainManager: MockToolchainManager(), projectBaseURL: tempBase) { _, config in
            MockPipelineRunner(projectURL: tempBase, config: config)
        }

        model.addInputs(urls: [video, text])
        XCTAssertEqual(model.pendingVideoURLs.count, 1)
        XCTAssertNotNil(model.selectionWarning)

        model.addInputs(urls: [video])
        XCTAssertNil(model.selectionWarning)
    }

    func testAddInputsDeduplicatesVideos() {
        let tempBase = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: tempBase, withIntermediateDirectories: true)
        let video = tempBase.appendingPathComponent("input.mov")
        try? Data("video".utf8).write(to: video)

        let model = AppModel(toolchainManager: MockToolchainManager(), projectBaseURL: tempBase) { _, config in
            MockPipelineRunner(projectURL: tempBase, config: config)
        }

        model.addInputs(urls: [video])
        model.addInputs(urls: [video])
        XCTAssertEqual(model.pendingVideoURLs.count, 1)
    }

    func testStartFromPendingSelectionWithNoInputsDoesNothing() {
        let tempBase = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let model = AppModel(toolchainManager: MockToolchainManager(), projectBaseURL: tempBase) { _, config in
            MockPipelineRunner(projectURL: tempBase, config: config)
        }
        model.startFromPendingSelection()
        XCTAssertEqual(model.viewState, .home)
    }

    func testResumeProjectShortCircuitsWhenOutputExists() async throws {
        let tempBase = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempBase, withIntermediateDirectories: true)
        let projectURL = tempBase.appendingPathComponent("Project.easysplatproj", isDirectory: true)
        try FileManager.default.createDirectory(at: projectURL, withIntermediateDirectories: true)
        let paths = ProjectPaths(root: projectURL)
        try paths.ensureDirectories()
        let output = paths.outputURL.appendingPathComponent("splat.ply")
        try FileManager.default.createDirectory(at: paths.outputURL, withIntermediateDirectories: true)
        try Data("ply".utf8).write(to: output)

        let metadata = ProjectMetadata(
            title: "Project",
            input: .photos(folder: "/tmp/photos"),
            preset: PresetSpec(mode: .object, quality: .standard),
            state: PipelineState(stage: .done, attempt: 0, lastError: nil, resumeToken: nil),
            outputs: OutputSpec(splatPlyPath: "Output/splat.ply", colmapModelPath: "SfM/colmap/sparse/0")
        )
        try ProjectMetadataStore.save(metadata, to: paths.metadataURL)

        let model = AppModel(toolchainManager: MockToolchainManager(), projectBaseURL: tempBase) { _, config in
            MockPipelineRunner(projectURL: projectURL, config: config)
        }

        model.resumeProject(at: projectURL)
        try await waitForViewState(model: model, state: .viewer)
        XCTAssertEqual(model.viewState, .viewer)
        XCTAssertEqual(model.outputPlyURL, output)
    }

    func testLoadPipelineLogTailWithInvalidUtf8() throws {
        let tempBase = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempBase, withIntermediateDirectories: true)
        let projectURL = tempBase.appendingPathComponent("Project.easysplatproj", isDirectory: true)
        try FileManager.default.createDirectory(at: projectURL, withIntermediateDirectories: true)
        let paths = ProjectPaths(root: projectURL)
        try paths.ensureDirectories()

        var logData = Data([0xF0, 0x9F])
        logData.append(contentsOf: "Hello log\n".utf8)
        try logData.write(to: paths.pipelineLogURL, options: [.atomic])

        let model = AppModel(toolchainManager: MockToolchainManager(), projectBaseURL: tempBase) { _, config in
            MockPipelineRunner(projectURL: projectURL, config: config)
        }

        let lines = model.test_loadPipelineLogTail(projectURL: projectURL)
        XCTAssertTrue(lines.contains { $0.contains("Hello log") })
    }

    func testRefreshProjectSummariesStatusMapping() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)

        let readyURL = try makeProject(at: base, name: "Ready", lastError: nil, withOutput: true)
        _ = readyURL
        let failedURL = try makeProject(at: base, name: "Failed", lastError: "boom", withOutput: false)
        _ = failedURL
        let inProgressURL = try makeProject(at: base, name: "Progress", lastError: nil, withOutput: false)
        _ = inProgressURL

        let model = AppModel(toolchainManager: MockToolchainManager(), projectBaseURL: base) { _, config in
            MockPipelineRunner(projectURL: base, config: config)
        }
        model.refreshProjectSummaries()

        let statusByTitle = Dictionary(model.projectSummaries.map { ($0.title, $0.status) }, uniquingKeysWith: { a, _ in a })
        XCTAssertEqual(statusByTitle["Ready"], .ready)
        XCTAssertEqual(statusByTitle["Failed"], .failed)
        XCTAssertEqual(statusByTitle["Progress"], .inProgress)
    }

    func testInterruptedProjectPromptDeferredPersistsAcrossRelaunch() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let interruptedURL = try makeProject(
            at: base,
            name: "Interrupted",
            lastError: nil,
            withOutput: false,
            checkpoint: PipelineCheckpoint(
                stage: .trainBrush,
                updatedAt: Date(),
                progressFraction: 0.4,
                message: "heartbeat",
                details: nil
            ),
            stage: .trainBrush
        )

        let model = AppModel(toolchainManager: MockToolchainManager(), projectBaseURL: base) { _, config in
            MockPipelineRunner(projectURL: base, config: config)
        }
        model.refreshProjectSummaries()
        guard let prompt = model.recoveryPromptProject else {
            XCTFail("Expected interrupted project prompt")
            return
        }
        XCTAssertEqual(prompt.title, "Interrupted")
        model.keepInterruptedProjectForLater(prompt)
        model.refreshProjectSummaries()
        XCTAssertNil(model.recoveryPromptProject)

        let relaunched = AppModel(toolchainManager: MockToolchainManager(), projectBaseURL: base) { _, config in
            MockPipelineRunner(projectURL: interruptedURL, config: config)
        }
        relaunched.refreshProjectSummaries()
        XCTAssertNil(relaunched.recoveryPromptProject)
        let interruptedSummary = relaunched.projectSummaries.first { $0.title == "Interrupted" }
        XCTAssertNotNil(interruptedSummary, "Suppressed project should remain listed.")
        XCTAssertEqual(interruptedSummary?.status, .inProgress)
    }

    func testDeleteInterruptedProjectRemovesDirectoryAcrossRelaunch() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let url = try makeProject(
            at: base,
            name: "InterruptedDelete",
            lastError: nil,
            withOutput: false,
            checkpoint: PipelineCheckpoint(
                stage: .sfmMatching,
                updatedAt: Date(),
                progressFraction: 0.1,
                message: "heartbeat",
                details: nil
            ),
            stage: .sfmMatching
        )

        let model = AppModel(toolchainManager: MockToolchainManager(), projectBaseURL: base) { _, config in
            MockPipelineRunner(projectURL: base, config: config)
        }
        model.refreshProjectSummaries()
        guard let prompt = model.recoveryPromptProject else {
            XCTFail("Expected interrupted project prompt")
            return
        }
        model.deleteInterruptedProject(prompt)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))

        let relaunched = AppModel(toolchainManager: MockToolchainManager(), projectBaseURL: base) { _, config in
            MockPipelineRunner(projectURL: base, config: config)
        }
        relaunched.refreshProjectSummaries()
        XCTAssertNil(relaunched.recoveryPromptProject)
        XCTAssertFalse(relaunched.projectSummaries.contains(where: { $0.url == url }))
    }

    func testReturningFromResumedInterruptedProjectSuppressesPromptAcrossRelaunch() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let projectURL = try makeProject(
            at: base,
            name: "InterruptedReturn",
            lastError: nil,
            withOutput: false,
            checkpoint: PipelineCheckpoint(
                stage: .trainBrush,
                updatedAt: Date(),
                progressFraction: 0.5,
                message: "heartbeat",
                details: nil
            ),
            stage: .trainBrush
        )

        let model = AppModel(toolchainManager: MockToolchainManager(), projectBaseURL: base) { _, _ in
            BlockingPipelineRunner()
        }

        model.resumeProject(at: projectURL)
        try await waitForViewState(model: model, state: .processing)

        model.cancelCurrentProject(deleteProject: false)
        try await waitForViewState(model: model, state: .home, timeout: 4.0)
        model.refreshProjectSummaries()

        XCTAssertNil(model.recoveryPromptProject)
        XCTAssertTrue(FileManager.default.fileExists(atPath: projectURL.path))

        let relaunched = AppModel(toolchainManager: MockToolchainManager(), projectBaseURL: base) { _, config in
            MockPipelineRunner(projectURL: projectURL, config: config)
        }
        relaunched.refreshProjectSummaries()
        XCTAssertNil(relaunched.recoveryPromptProject)
        let stoppedSummary = relaunched.projectSummaries.first { $0.title == "InterruptedReturn" }
        XCTAssertNotNil(stoppedSummary, "Stopped project should remain listed.")
        XCTAssertEqual(stoppedSummary?.status, .inProgress)
    }

    func testSuppressingOneInterruptedProjectStillPromptsForAnotherAfterRelaunch() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)

        let projectA = try makeProject(
            at: base,
            name: "InterruptedA",
            lastError: nil,
            withOutput: false,
            checkpoint: PipelineCheckpoint(
                stage: .trainBrush,
                updatedAt: Date(),
                progressFraction: 0.3,
                message: "heartbeat",
                details: nil
            ),
            stage: .trainBrush
        )
        _ = try makeProject(
            at: base,
            name: "InterruptedB",
            lastError: nil,
            withOutput: false,
            checkpoint: PipelineCheckpoint(
                stage: .sfmMatching,
                updatedAt: Date(),
                progressFraction: 0.2,
                message: "heartbeat",
                details: nil
            ),
            stage: .sfmMatching
        )

        let model = AppModel(toolchainManager: MockToolchainManager(), projectBaseURL: base) { _, config in
            MockPipelineRunner(projectURL: projectA, config: config)
        }
        model.refreshProjectSummaries()
        guard let summaryA = model.projectSummaries.first(where: { $0.title == "InterruptedA" }) else {
            XCTFail("Expected interrupted project A")
            return
        }
        model.keepInterruptedProjectForLater(summaryA)

        let relaunched = AppModel(toolchainManager: MockToolchainManager(), projectBaseURL: base) { _, config in
            MockPipelineRunner(projectURL: projectA, config: config)
        }
        relaunched.refreshProjectSummaries()
        XCTAssertEqual(relaunched.recoveryPromptProject?.title, "InterruptedB")
    }

    func testExplicitResumeClearsSuppressionForFutureInterruptions() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let projectURL = try makeProject(
            at: base,
            name: "InterruptedResume",
            lastError: nil,
            withOutput: false,
            checkpoint: PipelineCheckpoint(
                stage: .trainBrush,
                updatedAt: Date(),
                progressFraction: 0.25,
                message: "heartbeat",
                details: nil
            ),
            stage: .trainBrush,
            recoveryPromptSuppressed: true
        )

        let model = AppModel(toolchainManager: MockToolchainManager(), projectBaseURL: base) { _, _ in
            ImmediateCancellationPipelineRunner()
        }
        model.refreshProjectSummaries()
        XCTAssertNil(model.recoveryPromptProject)

        model.resumeProject(at: projectURL)
        try await Task.sleep(nanoseconds: 200_000_000)

        let metadataURL = ProjectPaths(root: projectURL).metadataURL
        var metadata = try ProjectMetadataStore.load(from: metadataURL)
        XCTAssertEqual(metadata.recoveryPromptSuppressed, false)

        metadata.state = PipelineState(stage: .trainBrush, attempt: metadata.state.attempt, lastError: nil, resumeToken: nil)
        metadata.checkpoint = PipelineCheckpoint(
            stage: .trainBrush,
            updatedAt: Date(),
            progressFraction: 0.4,
            message: "heartbeat",
            details: nil
        )
        metadata.lastRunStartedAt = Date()
        metadata.outputs = nil
        try ProjectMetadataStore.save(metadata, to: metadataURL)

        let relaunched = AppModel(toolchainManager: MockToolchainManager(), projectBaseURL: base) { _, config in
            MockPipelineRunner(projectURL: projectURL, config: config)
        }
        relaunched.refreshProjectSummaries()
        XCTAssertEqual(relaunched.recoveryPromptProject?.title, "InterruptedResume")
    }

    func testErrorDetailsTextCombinesFields() {
        let tempBase = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let model = AppModel(toolchainManager: MockToolchainManager(), projectBaseURL: tempBase) { _, config in
            MockPipelineRunner(projectURL: tempBase, config: config)
        }
        model.statusDetail = "detail"
        model.errorDetails = "error"
        model.logLines = ["a", "b"]
        model.errorLogLines = ["[err] traceback line"]

        let text = model.errorDetailsText ?? ""
        XCTAssertTrue(text.contains("detail"))
        XCTAssertTrue(text.contains("error"))
        XCTAssertTrue(text.contains("Error Logs:"))
        XCTAssertTrue(text.contains("Logs:"))
    }

    func testToolchainProgressLoggingBucketsAndMilestones() {
        let tempBase = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let model = AppModel(toolchainManager: MockToolchainManager(), projectBaseURL: tempBase) { _, config in
            MockPipelineRunner(projectURL: tempBase, config: config)
        }

        model.test_applyToolchainProgress(fraction: 0.01, message: "Downloading tools (core) 1 MB/100 MB (1 MB/s)")
        model.test_applyToolchainProgress(fraction: 0.04, message: "Downloading tools (core) 4 MB/100 MB (1 MB/s)")
        model.test_applyToolchainProgress(fraction: 0.09, message: "Downloading tools (core) 9 MB/100 MB (1 MB/s)")
        model.test_applyToolchainProgress(fraction: 0.11, message: "Downloading tools (core) 11 MB/100 MB (1 MB/s)")
        model.test_applyToolchainProgress(fraction: -1.0, message: "Verified download integrity (core)")
        model.test_applyToolchainProgress(fraction: -1.0, message: "Verified download integrity (core)")
        model.test_applyToolchainProgress(fraction: -1.0, message: "Unpacking tools (models)")
        model.test_applyToolchainProgress(fraction: -1.0, message: "Unpacking tools (models): found 2/2 expected files")
        model.test_applyToolchainProgress(fraction: 0.23, message: "Downloading tools (models) 23 MB/100 MB (1 MB/s)")
        model.test_applyToolchainProgress(fraction: 0.27, message: "Downloading tools (models) 27 MB/100 MB (1 MB/s)")

        XCTAssertEqual(model.statusDetail, "Downloading tools (models) 27 MB/100 MB (1 MB/s)")

        let coreDownloadLines = model.logLines.filter { $0.contains("[Tools] Downloading tools (core)") }
        XCTAssertEqual(coreDownloadLines.count, 2, "Expected one line per 10% bucket for core downloads.")

        XCTAssertTrue(model.logLines.contains("[Tools] Verified download integrity (core)"))
        XCTAssertTrue(model.logLines.contains("[Tools] Unpacking tools (models)"))
        XCTAssertTrue(model.logLines.contains("[Tools] Unpacking tools (models): found 2/2 expected files"))

        let duplicateIntegrityLines = model.logLines.filter { $0 == "[Tools] Verified download integrity (core)" }
        XCTAssertEqual(duplicateIntegrityLines.count, 1, "Indeterminate milestones should not be duplicated.")
    }

    func testShareCurrentSplatRecordsClickedMetricAndEvent() async throws {
        let tempBase = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempBase, withIntermediateDirectories: true)
        let input = tempBase.appendingPathComponent("input.mov")
        try Data("video".utf8).write(to: input)

        let model = AppModel(toolchainManager: MockToolchainManager(), projectBaseURL: tempBase) { projectURL, config in
            MockPipelineRunner(projectURL: projectURL, config: config)
        }

        model.addInputs(urls: [input])
        model.startFromPendingSelection()
        try await waitForViewState(model: model, state: .viewer)

        model.shareCurrentSplat()

        guard let projectURL = model.currentProjectURL else {
            XCTFail("Missing project URL")
            return
        }
        let metadata = try ProjectMetadataStore.load(from: ProjectPaths(root: projectURL).metadataURL)
        XCTAssertEqual(metadata.shareMetrics?.shareClickedCount, 1)
        XCTAssertEqual(metadata.shareMetrics?.shareCompletedCount, 0)
        XCTAssertFalse(model.shareStatusIsError)
        XCTAssertNotNil(model.shareStatusMessage)

        let events = model.test_shareEventsText(projectURL: projectURL)
        XCTAssertTrue(events.contains("share_clicked"))
        XCTAssertTrue(events.contains("share_caption_copied") || events.contains("share_sheet_opened"))
    }

    func testShareCurrentSplatReportsMissingOutputFile() async throws {
        let tempBase = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempBase, withIntermediateDirectories: true)
        let input = tempBase.appendingPathComponent("input.mov")
        try Data("video".utf8).write(to: input)

        let model = AppModel(toolchainManager: MockToolchainManager(), projectBaseURL: tempBase) { projectURL, config in
            MockPipelineRunner(projectURL: projectURL, config: config)
        }

        model.addInputs(urls: [input])
        model.startFromPendingSelection()
        try await waitForViewState(model: model, state: .viewer)

        guard let projectURL = model.currentProjectURL, let output = model.outputPlyURL else {
            XCTFail("Missing project state")
            return
        }
        try FileManager.default.removeItem(at: output)

        model.shareCurrentSplat()

        XCTAssertTrue(model.shareStatusIsError)
        XCTAssertTrue((model.shareStatusMessage ?? "").contains("Could not find"))
        XCTAssertEqual(model.shareMetrics.shareClickedCount, 0)

        let metadata = try ProjectMetadataStore.load(from: ProjectPaths(root: projectURL).metadataURL)
        XCTAssertNil(metadata.shareMetrics)

        let events = model.test_shareEventsText(projectURL: projectURL)
        XCTAssertTrue(events.contains("share_unavailable"))
        XCTAssertTrue(events.contains("missing_output_file"))
    }

    func testShareCurrentSplatReportsInvalidOutputDirectoryPath() async throws {
        let tempBase = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempBase, withIntermediateDirectories: true)
        let input = tempBase.appendingPathComponent("input.mov")
        try Data("video".utf8).write(to: input)

        let model = AppModel(toolchainManager: MockToolchainManager(), projectBaseURL: tempBase) { projectURL, config in
            MockPipelineRunner(projectURL: projectURL, config: config)
        }

        model.addInputs(urls: [input])
        model.startFromPendingSelection()
        try await waitForViewState(model: model, state: .viewer)

        guard let projectURL = model.currentProjectURL, let output = model.outputPlyURL else {
            XCTFail("Missing project state")
            return
        }
        try FileManager.default.removeItem(at: output)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

        model.shareCurrentSplat()

        XCTAssertTrue(model.shareStatusIsError)
        XCTAssertEqual(model.shareMetrics.shareClickedCount, 0)

        let events = model.test_shareEventsText(projectURL: projectURL)
        XCTAssertTrue(events.contains("share_unavailable"))
        XCTAssertTrue(events.contains("output_is_directory"))
    }

    func testShareCurrentSplatIgnoredWhileSessionAlreadyActive() async throws {
        let tempBase = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempBase, withIntermediateDirectories: true)
        let input = tempBase.appendingPathComponent("input.mov")
        try Data("video".utf8).write(to: input)

        let model = AppModel(toolchainManager: MockToolchainManager(), projectBaseURL: tempBase) { projectURL, config in
            MockPipelineRunner(projectURL: projectURL, config: config)
        }

        model.addInputs(urls: [input])
        model.startFromPendingSelection()
        try await waitForViewState(model: model, state: .viewer)

        guard let projectURL = model.currentProjectURL else {
            XCTFail("Missing project URL")
            return
        }
        model.test_activateShareSession(projectURL: projectURL)

        model.shareCurrentSplat()

        XCTAssertEqual(model.shareStatusMessage, "Finish the current share first.")
        XCTAssertFalse(model.shareStatusIsError)
        XCTAssertTrue(model.isShareSheetActive)
        XCTAssertEqual(model.shareMetrics.shareClickedCount, 0)
        let events = model.test_shareEventsText(projectURL: projectURL)
        XCTAssertTrue(events.contains("share_ignored"))
        XCTAssertTrue(events.contains("active_session"))
    }

    func testShareCompletionMetricPersistsToProjectMetadata() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let projectURL = try makeProject(at: base, name: "SharedProject", lastError: nil, withOutput: true)

        let model = AppModel(toolchainManager: MockToolchainManager(), projectBaseURL: base) { _, config in
            MockPipelineRunner(projectURL: projectURL, config: config)
        }

        _ = model.test_recordShareClicked(projectURL: projectURL)
        model.test_recordShareCompleted(projectURL: projectURL, serviceName: "Messages")

        let metadata = try ProjectMetadataStore.load(from: ProjectPaths(root: projectURL).metadataURL)
        XCTAssertEqual(metadata.shareMetrics?.shareClickedCount, 1)
        XCTAssertEqual(metadata.shareMetrics?.shareCompletedCount, 1)
        XCTAssertEqual(metadata.shareMetrics?.lastShareService, "Messages")
        XCTAssertNotNil(metadata.shareMetrics?.lastSharedAt)
        XCTAssertEqual(model.shareSummaryText, "Shared once. Last via Messages.")

        let events = model.test_shareEventsText(projectURL: projectURL)
        XCTAssertTrue(events.contains("share_completed"))
    }

    func testShareCompletionNormalizesEmptyServiceName() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let projectURL = try makeProject(at: base, name: "SharedProject2", lastError: nil, withOutput: true)

        let model = AppModel(toolchainManager: MockToolchainManager(), projectBaseURL: base) { _, config in
            MockPipelineRunner(projectURL: projectURL, config: config)
        }

        _ = model.test_recordShareClicked(projectURL: projectURL)
        model.test_recordShareCompleted(projectURL: projectURL, serviceName: "   ")

        let metadata = try ProjectMetadataStore.load(from: ProjectPaths(root: projectURL).metadataURL)
        XCTAssertEqual(metadata.shareMetrics?.lastShareService, "Share Service")
        XCTAssertEqual(model.shareSummaryText, "Shared once. Last via Share Service.")
    }

    func testShareCompletionIgnoredForInactiveSession() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let projectURL = try makeProject(at: base, name: "SharedProject3", lastError: nil, withOutput: true)

        let model = AppModel(toolchainManager: MockToolchainManager(), projectBaseURL: base) { _, config in
            MockPipelineRunner(projectURL: projectURL, config: config)
        }

        model.test_recordShareCompletedFromInactiveSession(projectURL: projectURL, serviceName: "Messages")

        let metadata = try ProjectMetadataStore.load(from: ProjectPaths(root: projectURL).metadataURL)
        XCTAssertNil(metadata.shareMetrics)
        XCTAssertEqual(model.shareMetrics.shareCompletedCount, 0)
    }

    func testTrainingConsentRememberedSkipsPrompt() async {
        let tempBase = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let model = AppModel(toolchainManager: MockToolchainManager(), projectBaseURL: tempBase) { _, config in
            MockPipelineRunner(projectURL: tempBase, config: config)
        }
        UserDefaults.standard.set(true, forKey: AppModel.trainingConsentRememberedKey)
        defer { UserDefaults.standard.removeObject(forKey: AppModel.trainingConsentRememberedKey) }

        let allowed = await model.awaitTrainingConsent()
        XCTAssertTrue(allowed)
        XCTAssertFalse(model.isShowingTrainingConsent)
    }

    func testTrainingConsentShowsAndResolves() async {
        let tempBase = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let model = AppModel(toolchainManager: MockToolchainManager(), projectBaseURL: tempBase) { _, config in
            MockPipelineRunner(projectURL: tempBase, config: config)
        }
        UserDefaults.standard.removeObject(forKey: AppModel.trainingConsentRememberedKey)

        let task = Task { await model.awaitTrainingConsent() }
        await Task.yield()

        XCTAssertTrue(model.isShowingTrainingConsent)
        model.resolveTrainingConsent(accepted: true, remember: false)
        let allowed = await task.value
        XCTAssertTrue(allowed)
    }

    func testTrainingConsentCancellationReturnsFalse() async {
        let tempBase = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let model = AppModel(toolchainManager: MockToolchainManager(), projectBaseURL: tempBase) { _, config in
            MockPipelineRunner(projectURL: tempBase, config: config)
        }
        UserDefaults.standard.removeObject(forKey: AppModel.trainingConsentRememberedKey)

        let task = Task { await model.awaitTrainingConsent() }
        await Task.yield()

        XCTAssertTrue(model.isShowingTrainingConsent)
        task.cancel()
        await Task.yield()

        let allowed = await task.value
        XCTAssertFalse(allowed)
        XCTAssertFalse(model.isShowingTrainingConsent)
    }

    func testErrorStageLogsBypassThrottle() async throws {
        let tempBase = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempBase, withIntermediateDirectories: true)
        let input = tempBase.appendingPathComponent("input.mov")
        try Data("video".utf8).write(to: input)

        let model = AppModel(
            toolchainManager: MockToolchainManager(),
            projectBaseURL: tempBase
        ) { _, _ in
            TracebackSpamPipelineRunner()
        }

        model.addInputs(urls: [input])
        model.startFromPendingSelection()

        let deadline = Date().addingTimeInterval(2.0)
        while Date() < deadline, model.lastError == nil {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertNotNil(model.lastError)
        try await Task.sleep(nanoseconds: 150_000_000)

        let tracebackLines = model.logLines.filter {
            $0.contains("Traceback (most recent call last):")
                || $0.contains("File \"run.py\"")
                || $0.contains("RuntimeError: MPS backend out of memory")
        }
        XCTAssertGreaterThanOrEqual(tracebackLines.count, 3)
        XCTAssertGreaterThanOrEqual(model.errorLogLines.count, 3)
        let details = model.errorDetailsText ?? ""
        XCTAssertTrue(details.contains("Traceback (most recent call last):"))
    }

    private func waitForViewState(model: AppModel, state: AppModel.ViewState, timeout: TimeInterval = 2.0) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if model.viewState == state {
                return
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTFail("Timed out waiting for viewState to become \(state)")
    }

    private func makeProject(
        at base: URL,
        name: String,
        lastError: String?,
        withOutput: Bool,
        checkpoint: PipelineCheckpoint? = nil,
        stage: PipelineStage = .done,
        recoveryPromptSuppressed: Bool? = nil,
        lastRunStartedAt: Date? = nil
    ) throws -> URL {
        let url = base.appendingPathComponent("\(name).easysplatproj", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let paths = ProjectPaths(root: url)
        try paths.ensureDirectories()
        if withOutput {
            try FileManager.default.createDirectory(at: paths.outputURL, withIntermediateDirectories: true)
            try Data("ply".utf8).write(to: paths.outputURL.appendingPathComponent("splat.ply"))
        }
        let metadata = ProjectMetadata(
            title: name,
            input: .photos(folder: "/tmp/photos"),
            preset: PresetSpec(mode: .object, quality: .standard),
            state: PipelineState(stage: stage, attempt: 0, lastError: lastError, resumeToken: nil),
            outputs: withOutput ? OutputSpec(splatPlyPath: "Output/splat.ply", colmapModelPath: "SfM/colmap/sparse/0") : nil,
            checkpoint: checkpoint,
            recoveryPromptSuppressed: recoveryPromptSuppressed,
            lastRunStartedAt: lastRunStartedAt
        )
        try ProjectMetadataStore.save(metadata, to: paths.metadataURL)
        return url
    }
}

final class MockToolchainManager: ToolchainManaging {
    func ensureToolchain(
        manifestURL: URL,
        publicKeyBase64: String,
        targetName: String,
        onProgress: @escaping @Sendable (Double, String) -> Void
    ) async throws -> ToolchainPaths {
        let vggt = VggtToolchain(
            root: URL(fileURLWithPath: "/mock/vggt_mps"),
            sfmTool: URL(fileURLWithPath: "/mock/vggt_mps/bin/easysplat_vggt_sfm"),
            python: URL(fileURLWithPath: "/mock/vggt_mps/python/bin/python3"),
            models: URL(fileURLWithPath: "/mock/vggt_mps/models")
        )
        let fastvggt = FastVggtToolchain(
            root: URL(fileURLWithPath: "/mock/fastvggt_mps"),
            sfmTool: URL(fileURLWithPath: "/mock/fastvggt_mps/bin/easysplat_fastvggt_sfm"),
            python: URL(fileURLWithPath: "/mock/fastvggt_mps/python/bin/python3"),
            models: URL(fileURLWithPath: "/mock/fastvggt_mps/models")
        )
        return ToolchainPaths(
            root: URL(fileURLWithPath: "/tmp/toolchain"),
            colmap: URL(fileURLWithPath: "/mock/colmap"),
            glomap: URL(fileURLWithPath: "/mock/glomap"),
            brush: URL(fileURLWithPath: "/mock/brush"),
            vggt: vggt,
            fastvggt: fastvggt
        )
    }
}

final class BlockingPipelineRunner: PipelineRunning {
    func run(resumeFrom lastCompletedStage: PipelineStage?, events: @escaping @Sendable (PipelineEvent) -> Void) async throws {
        events(.stageStarted(stage: .trainBrush))
        while true {
            try Task.checkCancellation()
            try await Task.sleep(nanoseconds: 50_000_000)
        }
    }
}

final class ImmediateCancellationPipelineRunner: PipelineRunning {
    func run(resumeFrom lastCompletedStage: PipelineStage?, events: @escaping @Sendable (PipelineEvent) -> Void) async throws {
        throw CancellationError()
    }
}

final class MockPipelineRunner: PipelineRunning {
    private let projectURL: URL
    private let config: PipelineRunner.PipelineConfig

    init(projectURL: URL, config: PipelineRunner.PipelineConfig) {
        self.projectURL = projectURL
        self.config = config
    }

    func run(resumeFrom lastCompletedStage: PipelineStage?, events: @escaping @Sendable (PipelineEvent) -> Void) async throws {
        events(.stageStarted(stage: .importInput))
        events(.stageFinished(stage: .importInput))

        let paths = ProjectPaths(root: projectURL)
        var metadata = try ProjectMetadataStore.load(from: paths.metadataURL)
        let outputURL = paths.outputURL.appendingPathComponent("splat.ply")
        try FileManager.default.createDirectory(at: paths.outputURL, withIntermediateDirectories: true)
        try Data("ply".utf8).write(to: outputURL)
        metadata.outputs = OutputSpec(splatPlyPath: "Output/splat.ply", colmapModelPath: "SfM/colmap/sparse/0")
        metadata.state = PipelineState(stage: .done, attempt: 0, lastError: nil, resumeToken: nil)
        try ProjectMetadataStore.save(metadata, to: paths.metadataURL)
    }
}

final class TracebackSpamPipelineRunner: PipelineRunning {
    func run(resumeFrom lastCompletedStage: PipelineStage?, events: @escaping @Sendable (PipelineEvent) -> Void) async throws {
        events(.stageStarted(stage: .sfmFeatures))
        events(.stageLog(stage: .sfmFeatures, line: "Traceback (most recent call last):", isError: true))
        events(.stageLog(stage: .sfmFeatures, line: "  File \"run.py\", line 287, in run_pipeline", isError: true))
        events(.stageLog(stage: .sfmFeatures, line: "RuntimeError: MPS backend out of memory", isError: true))
        events(.pipelineFailed(stage: .sfmFeatures, userMessage: "Pipeline failed", debugMessage: "traceback"))
        throw NSError(domain: "AppModelTests", code: 1)
    }
}
#endif
