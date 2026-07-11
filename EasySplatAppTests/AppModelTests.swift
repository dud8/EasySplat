#if canImport(XCTest)
import AppKit
import Foundation
import XCTest
@testable import EasySplatApp
@testable import EasySplatCore

@MainActor
final class AppModelTests: XCTestCase {
    override func setUp() {
        super.setUp()
        // Capture-mode and quality-preset persistence is per-user in production but
        // bleeds across XCTest cases otherwise — strip the keys so each test starts
        // from the documented defaults instead of the previous case's tail state.
        UserDefaults.standard.removeObject(forKey: AppModel.captureModeUserDefaultsKey)
        UserDefaults.standard.removeObject(forKey: AppModel.qualityPresetUserDefaultsKey)
    }
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

    func testCountRecentPipelineErrorsTailsBoundedAndCountsErrLines() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let logURL = dir.appendingPathComponent("pipeline.log")
        var data = Data()
        // 200 KB of mixed lines, last ~16 KB exercised by the tail.
        for index in 0..<2_000 {
            let line = "[\(index)] some routine progress\n"
            data.append(line.data(using: .utf8)!)
        }
        // Append a known burst of error-level lines at the tail.
        for _ in 0..<7 {
            data.append("[err] Failed thing happened\n".data(using: .utf8)!)
        }
        try data.write(to: logURL)

        let count = AppModel.countRecentPipelineErrors(at: logURL)
        XCTAssertEqual(count, 7)
    }

    func testCountRecentPipelineErrorsReturnsNilForMissingLog() {
        let logURL = FileManager.default.temporaryDirectory.appendingPathComponent("missing-\(UUID().uuidString).log")
        XCTAssertNil(AppModel.countRecentPipelineErrors(at: logURL))
    }

    func testCountImageFilesIgnoresUnsupportedAndHidden() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for ext in ["jpg", "JPEG", "png", "heic", "HEIF"] {
            try Data("img".utf8).write(to: folder.appendingPathComponent("photo.\(ext)"))
        }
        try Data("notes".utf8).write(to: folder.appendingPathComponent("README.txt"))
        try Data("hidden".utf8).write(to: folder.appendingPathComponent(".hidden.png"))
        let count = AppModel.countImageFiles(in: folder)
        XCTAssertEqual(count, 5)
    }

    func testCountImageFilesRecursesIntoSubfolders() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let sub = folder.appendingPathComponent("burst", isDirectory: true)
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        for index in 0..<4 {
            try Data("img".utf8).write(to: sub.appendingPathComponent("burst\(index).jpg"))
        }
        try Data("img".utf8).write(to: folder.appendingPathComponent("hero.jpg"))
        let count = AppModel.countImageFiles(in: folder)
        XCTAssertEqual(count, 5, "Recursive count should include images in subfolders.")
    }

    func testCountImageFilesReturnsNilForMissingFolder() {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("missing-\(UUID().uuidString)")
        XCTAssertNil(AppModel.countImageFiles(in: folder))
    }

    func testAddInputsWarnsForThinPhotoFolder() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let folder = base.appendingPathComponent("Thin", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for index in 0..<3 {
            try Data("img".utf8).write(to: folder.appendingPathComponent("img\(index).jpg"))
        }
        let model = AppModel(toolchainManager: MockToolchainManager(), projectBaseURL: base) { url, config in
            MockPipelineRunner(projectURL: url, config: config)
        }
        model.addInputs(urls: [folder])
        let warning = try XCTUnwrap(model.selectionWarning)
        XCTAssertTrue(warning.contains("Thin"), "Warning should name the folder, got: \(warning)")
        XCTAssertTrue(warning.contains("3 image"), "Warning should mention the actual count, got: \(warning)")
    }

    func testMarkProjectOpenedWritesSidecarAndDoesNotTouchMainMetadata() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let projectURL = base.appendingPathComponent("OpenStamp.easysplatproj", isDirectory: true)
        try FileManager.default.createDirectory(at: projectURL, withIntermediateDirectories: true)
        let originalMetadata = ProjectMetadata(
            title: "OpenStamp",
            input: .photos(folder: "/tmp/photos"),
            preset: PresetSpec(mode: .object, quality: .standard)
        )
        let paths = ProjectPaths(root: projectURL)
        try ProjectMetadataStore.save(originalMetadata, to: paths.metadataURL)
        // Capture the metadata file's bytes so we can prove markProjectOpened
        // did NOT rewrite project.json (and so cannot race a pipeline writer).
        let metadataBytesBefore = try Data(contentsOf: paths.metadataURL)

        let model = AppModel(toolchainManager: MockToolchainManager(), projectBaseURL: base) { url, config in
            MockPipelineRunner(projectURL: url, config: config)
        }
        let stamp = Date(timeIntervalSince1970: 1_800_000_000)
        model.markProjectOpened(at: projectURL, at: stamp)

        let sidecarMoment = LastOpenedSidecar.load(from: paths.lastOpenedSidecarURL)
        XCTAssertEqual(sidecarMoment, stamp, "Sidecar must hold the persisted timestamp.")

        let metadataBytesAfter = try Data(contentsOf: paths.metadataURL)
        XCTAssertEqual(metadataBytesAfter, metadataBytesBefore,
                       "markProjectOpened must not rewrite project.json — that's the race-fix guarantee.")
    }

    func testFlushPendingNotesSaveLandsLastEdit() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let projectURL = base.appendingPathComponent("FlushTest.easysplatproj", isDirectory: true)
        try FileManager.default.createDirectory(at: projectURL, withIntermediateDirectories: true)
        try ProjectMetadataStore.save(
            ProjectMetadata(
                title: "FlushTest",
                input: .photos(folder: "/tmp/photos"),
                preset: PresetSpec(mode: .object, quality: .standard)
            ),
            to: ProjectPaths(root: projectURL).metadataURL
        )

        let model = AppModel(toolchainManager: MockToolchainManager(), projectBaseURL: base) { url, config in
            MockPipelineRunner(projectURL: url, config: config)
        }
        model.currentProjectURL = projectURL
        // Schedule a save — the debounce timer has not fired yet.
        model.scheduleNotesSave(at: projectURL, to: "last edit")
        // Flush bypasses the debounce, so the value should land synchronously.
        model.flushPendingNotesSave()
        let reloaded = try ProjectMetadataStore.load(from: ProjectPaths(root: projectURL).metadataURL)
        XCTAssertEqual(reloaded.notes, "last edit",
                       "flushPendingNotesSave must persist the pending value, not lose it.")
    }

    func testUpdateProjectNotesDoesNotAlterCurrentProjectNotesProperty() throws {
        // Regression: a previous version of updateProjectNotes reassigned
        // currentProjectNotes to the trimmed persisted value, which fired
        // through the SwiftUI binding and erased trailing whitespace the
        // user was still typing.
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let projectURL = base.appendingPathComponent("NotesRace.easysplatproj", isDirectory: true)
        try FileManager.default.createDirectory(at: projectURL, withIntermediateDirectories: true)
        try ProjectMetadataStore.save(
            ProjectMetadata(
                title: "NotesRace",
                input: .photos(folder: "/tmp/photos"),
                preset: PresetSpec(mode: .object, quality: .standard)
            ),
            to: ProjectPaths(root: projectURL).metadataURL
        )

        let model = AppModel(toolchainManager: MockToolchainManager(), projectBaseURL: base) { url, config in
            MockPipelineRunner(projectURL: url, config: config)
        }
        model.currentProjectURL = projectURL
        model.currentProjectNotes = "Captured  " // trailing whitespace mid-typing

        XCTAssertTrue(model.updateProjectNotes(at: projectURL, to: "Captured  "))
        XCTAssertEqual(model.currentProjectNotes, "Captured  ",
                       "Saving must not rewrite the in-memory binding value with the trimmed text.")
    }

    func testFreshProcessingRunExposesActivePresetAndInput() async throws {
        let tempBase = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempBase) }
        try FileManager.default.createDirectory(at: tempBase, withIntermediateDirectories: true)
        let input = tempBase.appendingPathComponent("clip.mov")
        try Data("video".utf8).write(to: input)

        let model = AppModel(toolchainManager: MockToolchainManager(), projectBaseURL: tempBase) { _, _ in
            BlockingPipelineRunner()
        }
        model.captureMode = .room
        model.qualityPreset = .ultra
        model.addInputs(urls: [input])
        model.startFromPendingSelection()

        try await waitForViewState(model: model, state: .processing)

        XCTAssertEqual(model.currentPreset?.mode, .room)
        XCTAssertEqual(model.currentPreset?.quality, .ultra)
        if case .video(let files) = model.currentInput {
            XCTAssertEqual(files, [input.path])
        } else {
            XCTFail("Expected active video input while processing.")
        }

        model.cancelCurrentProject(deleteProject: false)
        try await waitForViewState(model: model, state: .home, timeout: 4.0)
    }

    func testStartProjectPersistsRequestedOptionsMatchingLegacyControls() async throws {
        let tempBase = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempBase) }
        try FileManager.default.createDirectory(at: tempBase, withIntermediateDirectories: true)
        let input = tempBase.appendingPathComponent("clip.mov")
        try Data("video".utf8).write(to: input)

        let model = AppModel(toolchainManager: MockToolchainManager(), projectBaseURL: tempBase) { projectURL, config in
            MockPipelineRunner(projectURL: projectURL, config: config)
        }
        model.captureMode = .room
        model.qualityPreset = .ultra

        await model.startProject(input: .video(files: [input.path]), title: "Walkthrough")

        let projectURL = try XCTUnwrap(model.currentProjectURL)
        let metadata = try ProjectMetadataStore.load(from: ProjectPaths(root: projectURL).metadataURL)
        XCTAssertEqual(metadata.requestedRunOptions?.capturePath, .walkthrough)
        XCTAssertEqual(metadata.requestedRunOptions?.detailProfile, .highDetail)
    }

    func testResumedProcessingRunExposesPersistedPresetAndInput() async throws {
        let tempBase = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempBase) }
        try FileManager.default.createDirectory(at: tempBase, withIntermediateDirectories: true)
        let url = try makeProject(at: tempBase, name: "ResumeConfig", lastError: nil, withOutput: false, stage: .sfmFeatures)

        let model = AppModel(toolchainManager: MockToolchainManager(), projectBaseURL: tempBase) { _, _ in
            BlockingPipelineRunner()
        }
        model.resumeProject(at: url)

        try await waitForViewState(model: model, state: .processing)

        XCTAssertEqual(model.currentPreset?.mode, .object)
        XCTAssertEqual(model.currentPreset?.quality, .standard)
        if case .photos(let folder) = model.currentInput {
            XCTAssertEqual(folder, "/tmp/photos")
        } else {
            XCTFail("Expected resumed photo-folder input while processing.")
        }

        model.cancelCurrentProject(deleteProject: false)
        try await waitForViewState(model: model, state: .home, timeout: 4.0)
    }

    func testUpdateProjectNotesPersistsAndClearsWhenEmpty() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let projectURL = base.appendingPathComponent("NoteTest.easysplatproj", isDirectory: true)
        try FileManager.default.createDirectory(at: projectURL, withIntermediateDirectories: true)
        try ProjectMetadataStore.save(
            ProjectMetadata(
                title: "NoteTest",
                input: .photos(folder: "/tmp/photos"),
                preset: PresetSpec(mode: .object, quality: .standard)
            ),
            to: ProjectPaths(root: projectURL).metadataURL
        )

        let model = AppModel(toolchainManager: MockToolchainManager(), projectBaseURL: base) { url, config in
            MockPipelineRunner(projectURL: url, config: config)
        }

        XCTAssertTrue(model.updateProjectNotes(at: projectURL, to: "  captured at noon "))
        var reloaded = try ProjectMetadataStore.load(from: ProjectPaths(root: projectURL).metadataURL)
        XCTAssertEqual(reloaded.notes, "captured at noon")

        // Identical text returns false (no-op) and does not rewrite.
        XCTAssertFalse(model.updateProjectNotes(at: projectURL, to: "captured at noon"))

        XCTAssertTrue(model.updateProjectNotes(at: projectURL, to: "   "))
        reloaded = try ProjectMetadataStore.load(from: ProjectPaths(root: projectURL).metadataURL)
        XCTAssertNil(reloaded.notes)
    }

    func testRenameProjectUpdatesPersistedTitle() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let projectURL = base.appendingPathComponent("Original.easysplatproj", isDirectory: true)
        try FileManager.default.createDirectory(at: projectURL, withIntermediateDirectories: true)
        let metadata = ProjectMetadata(
            title: "Original",
            input: .photos(folder: "/tmp/photos"),
            preset: PresetSpec(mode: .object, quality: .standard)
        )
        try ProjectMetadataStore.save(metadata, to: ProjectPaths(root: projectURL).metadataURL)

        let model = AppModel(toolchainManager: MockToolchainManager(), projectBaseURL: base) { url, config in
            MockPipelineRunner(projectURL: url, config: config)
        }

        XCTAssertTrue(model.renameProject(at: projectURL, to: "  New Title  "))
        let reloaded = try ProjectMetadataStore.load(from: ProjectPaths(root: projectURL).metadataURL)
        XCTAssertEqual(reloaded.title, "New Title")
    }

    func testRenameProjectRejectsEmptyOrUnchangedTitles() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let projectURL = base.appendingPathComponent("Same.easysplatproj", isDirectory: true)
        try FileManager.default.createDirectory(at: projectURL, withIntermediateDirectories: true)
        let metadata = ProjectMetadata(
            title: "Same",
            input: .photos(folder: "/tmp/photos"),
            preset: PresetSpec(mode: .object, quality: .standard)
        )
        try ProjectMetadataStore.save(metadata, to: ProjectPaths(root: projectURL).metadataURL)

        let model = AppModel(toolchainManager: MockToolchainManager(), projectBaseURL: base) { url, config in
            MockPipelineRunner(projectURL: url, config: config)
        }

        XCTAssertFalse(model.renameProject(at: projectURL, to: ""))
        XCTAssertFalse(model.renameProject(at: projectURL, to: "   "))
        XCTAssertFalse(model.renameProject(at: projectURL, to: "Same"))
    }

    func testStartProjectUsesFastProfileByDefault() async throws {
        let tempBase = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempBase) }
        try FileManager.default.createDirectory(at: tempBase, withIntermediateDirectories: true)
        let input = tempBase.appendingPathComponent("input.mov")
        try Data("video".utf8).write(to: input)
        var capturedSpeedProfile: PipelineRunner.SpeedProfile?

        let model = AppModel(
            toolchainManager: MockToolchainManager(),
            projectBaseURL: tempBase
        ) { projectURL, config in
            capturedSpeedProfile = config.speedProfile
            return MockPipelineRunner(projectURL: projectURL, config: config)
        }

        XCTAssertEqual(model.qualityPreset, .draft)
        await model.startProject(input: .video(files: [input.path]), title: "FastDefault")

        XCTAssertEqual(capturedSpeedProfile, .fast)
        let projectURL = try XCTUnwrap(model.currentProjectURL)
        let metadata = try ProjectMetadataStore.load(from: ProjectPaths(root: projectURL).metadataURL)
        XCTAssertEqual(metadata.preset.quality, .draft)
    }

    func testStartProjectUsesStandardSpeedProfileForBalancedQuality() async throws {
        let tempBase = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempBase) }
        try FileManager.default.createDirectory(at: tempBase, withIntermediateDirectories: true)
        let input = tempBase.appendingPathComponent("input.mov")
        try Data("video".utf8).write(to: input)
        var capturedSpeedProfile: PipelineRunner.SpeedProfile?

        let model = AppModel(
            toolchainManager: MockToolchainManager(),
            projectBaseURL: tempBase
        ) { projectURL, config in
            capturedSpeedProfile = config.speedProfile
            return MockPipelineRunner(projectURL: projectURL, config: config)
        }

        model.qualityPreset = .standard
        await model.startProject(input: .video(files: [input.path]), title: "Balanced")

        XCTAssertEqual(capturedSpeedProfile, .standard)
    }

    func testStartProjectReportsFailureWhenRunnerFinishesWithoutReadyOutput() async throws {
        let tempBase = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempBase) }
        try FileManager.default.createDirectory(at: tempBase, withIntermediateDirectories: true)
        let input = tempBase.appendingPathComponent("input.mov")
        try Data("video".utf8).write(to: input)

        let model = AppModel(
            toolchainManager: MockToolchainManager(),
            projectBaseURL: tempBase
        ) { projectURL, _ in
            MissingOutputPipelineRunner(projectURL: projectURL)
        }

        await model.startProject(input: .video(files: [input.path]), title: "MissingOutput")

        XCTAssertEqual(model.viewState, .processing)
        XCTAssertNil(model.outputPlyURL)
        XCTAssertEqual(model.lastError, "Processing failed. Expected outputs were missing.")
        XCTAssertEqual(model.statusTitle, "Processing failed. Expected outputs were missing.")
        guard let projectURL = model.currentProjectURL else {
            XCTFail("Missing project URL")
            return
        }
        let metadata = try ProjectMetadataStore.load(from: ProjectPaths(root: projectURL).metadataURL)
        XCTAssertEqual(metadata.state.lastError, "Processing failed. Expected outputs were missing.")
    }

    func testStartProjectPersistsToolchainFailureAsFailedSummary() async throws {
        let tempBase = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempBase) }
        try FileManager.default.createDirectory(at: tempBase, withIntermediateDirectories: true)
        let input = tempBase.appendingPathComponent("input.mov")
        try Data("video".utf8).write(to: input)

        let model = AppModel(toolchainManager: FailingToolchainManager(message: "manifest unreachable"), projectBaseURL: tempBase) { _, _ in
            XCTFail("Pipeline runner should not start when toolchain setup fails.")
            return BlockingPipelineRunner()
        }
        model.addInputs(urls: [input])
        model.startFromPendingSelection()

        try await waitForLastError(model: model, timeout: 4.0)
        model.refreshProjectSummaries()

        let summary = try XCTUnwrap(model.projectSummaries.first)
        XCTAssertEqual(summary.status, .failed)
        XCTAssertEqual(summary.lastError, "manifest unreachable")
        XCTAssertNotNil(summary.lastFailureAt)
        let metadata = try ProjectMetadataStore.load(from: ProjectPaths(root: summary.url).metadataURL)
        XCTAssertEqual(metadata.state.lastError, "manifest unreachable")
        XCTAssertNotNil(metadata.lastFailureAt)
        XCTAssertNil(metadata.checkpoint)
        XCTAssertNil(metadata.lastRunStartedAt)
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

    func testMsplatTrainingProgressWarnsThatTrainingRestarts() {
        let tempBase = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let model = AppModel(toolchainManager: MockToolchainManager(), projectBaseURL: tempBase) { _, config in
            MockPipelineRunner(projectURL: tempBase, config: config)
        }
        model.currentTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
        }
        defer {
            model.currentTask?.cancel()
            model.currentTask = nil
        }

        model.handle(event: .stageStarted(stage: .trainBrush))
        model.handle(event: .trainingBackendSelected(backend: .msplat))
        model.cancelCurrentProject(deleteProject: false)

        XCTAssertEqual(model.statusTitle, "Saving project…")
        XCTAssertEqual(model.statusDetail, "Stopping training at the next safe point (resume starts training over).")
    }

    func testBrushTrainingProgressUsesSnapshotStopCopy() {
        let tempBase = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let model = AppModel(toolchainManager: MockToolchainManager(), projectBaseURL: tempBase) { _, config in
            MockPipelineRunner(projectURL: tempBase, config: config)
        }
        model.currentTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
        }
        defer {
            model.currentTask?.cancel()
            model.currentTask = nil
        }

        model.handle(event: .stageStarted(stage: .trainBrush))
        model.handle(event: .trainingBackendSelected(backend: .brush))
        model.cancelCurrentProject(deleteProject: false)

        XCTAssertEqual(model.statusTitle, "Exporting snapshot…")
        XCTAssertEqual(model.statusDetail, "Exporting the latest snapshot (training restarts from scratch on resume).")
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
        try writeMinimalPly(at: output)

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

    func testResumeProjectRunsPipelineWhenOutputPathIsDirectory() async throws {
        let tempBase = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempBase, withIntermediateDirectories: true)
        let projectURL = tempBase.appendingPathComponent("Project.easysplatproj", isDirectory: true)
        try FileManager.default.createDirectory(at: projectURL, withIntermediateDirectories: true)
        let paths = ProjectPaths(root: projectURL)
        try paths.ensureDirectories()
        let output = paths.outputURL.appendingPathComponent("splat.ply")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

        let metadata = ProjectMetadata(
            title: "Project",
            input: .photos(folder: "/tmp/photos"),
            preset: PresetSpec(mode: .object, quality: .standard),
            state: PipelineState(stage: .done, attempt: 0, lastError: nil, resumeToken: nil),
            outputs: OutputSpec(splatPlyPath: "Output/splat.ply", colmapModelPath: "SfM/colmap/sparse/0")
        )
        try ProjectMetadataStore.save(metadata, to: paths.metadataURL)

        let runner = DirectoryOutputRepairingPipelineRunner(projectURL: projectURL)
        let model = AppModel(toolchainManager: MockToolchainManager(), projectBaseURL: tempBase) { _, _ in
            runner
        }

        model.resumeProject(at: projectURL)
        try await waitForViewState(model: model, state: .viewer)

        XCTAssertTrue(runner.didRun)
        var isDirectory = ObjCBool(false)
        XCTAssertTrue(FileManager.default.fileExists(atPath: output.path, isDirectory: &isDirectory))
        XCTAssertFalse(isDirectory.boolValue)
    }

    func testResumeProjectRunsPipelineWhenPersistedOutputIsCorrupt() async throws {
        let tempBase = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempBase) }
        try FileManager.default.createDirectory(at: tempBase, withIntermediateDirectories: true)
        let projectURL = tempBase.appendingPathComponent("Project.easysplatproj", isDirectory: true)
        try FileManager.default.createDirectory(at: projectURL, withIntermediateDirectories: true)
        let paths = ProjectPaths(root: projectURL)
        try paths.ensureDirectories()
        let output = paths.outputURL.appendingPathComponent("splat.ply")
        try "ply".write(to: output, atomically: true, encoding: .utf8)

        let metadata = ProjectMetadata(
            title: "Project",
            input: .photos(folder: "/tmp/photos"),
            preset: PresetSpec(mode: .object, quality: .standard),
            state: PipelineState(stage: .done, attempt: 0, lastError: nil, resumeToken: nil),
            outputs: OutputSpec(splatPlyPath: "Output/splat.ply", colmapModelPath: "SfM/colmap/sparse/0")
        )
        try ProjectMetadataStore.save(metadata, to: paths.metadataURL)

        let runner = DirectoryOutputRepairingPipelineRunner(projectURL: projectURL)
        let model = AppModel(toolchainManager: MockToolchainManager(), projectBaseURL: tempBase) { _, _ in
            runner
        }

        model.resumeProject(at: projectURL)
        try await waitForViewState(model: model, state: .viewer)

        XCTAssertTrue(runner.didRun)
        XCTAssertEqual(ProjectArtifactValidator.validatePlyFile(at: output), .valid)
    }

    func testOldCanceledTaskDoesNotClearNewerCurrentTask() async throws {
        let tempBase = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempBase) }
        try FileManager.default.createDirectory(at: tempBase, withIntermediateDirectories: true)
        let firstURL = try makeProject(at: tempBase, name: "First", lastError: nil, withOutput: false)
        let secondURL = try makeProject(at: tempBase, name: "Second", lastError: nil, withOutput: false)
        var callCount = 0
        let firstWaiting = expectation(description: "first run waiting for cancellation")
        let firstCanceled = expectation(description: "first run observed cancellation")
        let firstFinished = expectation(description: "first run finished after cancellation")
        let model = AppModel(toolchainManager: MockToolchainManager(), projectBaseURL: tempBase) { _, _ in
            callCount += 1
            if callCount == 1 {
                return DelayedCancellationPipelineRunner(
                    waitingForCancellation: firstWaiting,
                    cancellationObserved: firstCanceled,
                    runFinished: firstFinished
                )
            }
            return BlockingPipelineRunner()
        }

        model.resumeProject(at: firstURL)
        try await waitForViewState(model: model, state: .processing)
        await fulfillment(of: [firstWaiting], timeout: 2.0)
        model.resumeProject(at: secondURL)
        await fulfillment(of: [firstCanceled, firstFinished], timeout: 2.0)
        await Task.yield()

        XCTAssertNotNil(model.currentTask)
        XCTAssertEqual(model.currentProjectURL, secondURL)

        model.cancelCurrentProject(deleteProject: false)
        try await waitForViewState(model: model, state: .home, timeout: 4.0)
    }

    func testOldCanceledTaskDoesNotOverwriteNewerProjectState() async throws {
        let tempBase = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempBase) }
        try FileManager.default.createDirectory(at: tempBase, withIntermediateDirectories: true)
        let firstURL = try makeProject(at: tempBase, name: "First", lastError: nil, withOutput: false)
        let secondURL = try makeProject(at: tempBase, name: "Second", lastError: nil, withOutput: false)
        let firstStarted = expectation(description: "first run started")
        let firstFinished = expectation(description: "first run finished late")
        let lateRunner = LateCompletingPipelineRunner(
            projectURL: firstURL,
            started: firstStarted,
            finished: firstFinished
        )
        var callCount = 0
        let model = AppModel(toolchainManager: MockToolchainManager(), projectBaseURL: tempBase) { _, _ in
            callCount += 1
            if callCount == 1 {
                return lateRunner
            }
            return BlockingPipelineRunner()
        }

        model.resumeProject(at: firstURL)
        try await waitForViewState(model: model, state: .processing)
        await fulfillment(of: [firstStarted], timeout: 2.0)
        model.resumeProject(at: secondURL)
        try await waitForCurrentProjectURL(model: model, url: secondURL)

        lateRunner.finish()
        await fulfillment(of: [firstFinished], timeout: 2.0)
        try await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertEqual(model.currentProjectURL, secondURL)
        XCTAssertEqual(model.viewState, .processing)
        XCTAssertNil(model.outputPlyURL)
        XCTAssertNotEqual(model.statusTitle, "Stale import")

        model.cancelCurrentProject(deleteProject: false)
        try await waitForViewState(model: model, state: .home, timeout: 4.0)
    }

    func testOldCanceledTaskDoesNotOverwriteNewerProjectFailureState() async throws {
        let tempBase = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempBase) }
        try FileManager.default.createDirectory(at: tempBase, withIntermediateDirectories: true)
        let firstURL = try makeProject(at: tempBase, name: "First", lastError: nil, withOutput: false)
        let secondURL = try makeProject(at: tempBase, name: "Second", lastError: nil, withOutput: false)
        let firstStarted = expectation(description: "first failing run started")
        let firstFinished = expectation(description: "first failing run finished late")
        let lateRunner = LateFailingPipelineRunner(started: firstStarted, finished: firstFinished)
        var callCount = 0
        let model = AppModel(toolchainManager: MockToolchainManager(), projectBaseURL: tempBase) { _, _ in
            callCount += 1
            if callCount == 1 {
                return lateRunner
            }
            return BlockingPipelineRunner()
        }

        model.resumeProject(at: firstURL)
        try await waitForViewState(model: model, state: .processing)
        await fulfillment(of: [firstStarted], timeout: 2.0)
        model.resumeProject(at: secondURL)
        try await waitForCurrentProjectURL(model: model, url: secondURL)

        lateRunner.finish()
        await fulfillment(of: [firstFinished], timeout: 2.0)
        try await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertEqual(model.currentProjectURL, secondURL)
        XCTAssertEqual(model.viewState, .processing)
        XCTAssertNil(model.lastError)
        XCTAssertNil(model.errorDetails)
        XCTAssertNotEqual(model.statusTitle, "First project failed")

        model.cancelCurrentProject(deleteProject: false)
        try await waitForViewState(model: model, state: .home, timeout: 4.0)
    }

    func testOldToolchainProgressDoesNotOverwriteNewerProjectState() async throws {
        let tempBase = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempBase) }
        try FileManager.default.createDirectory(at: tempBase, withIntermediateDirectories: true)
        let firstURL = try makeProject(at: tempBase, name: "First", lastError: nil, withOutput: false)
        let secondURL = try makeProject(at: tempBase, name: "Second", lastError: nil, withOutput: false)
        let firstToolchainStarted = expectation(description: "first toolchain started")
        let manager = DelayedProgressToolchainManager(firstStarted: firstToolchainStarted)
        let model = AppModel(toolchainManager: manager, projectBaseURL: tempBase) { _, _ in
            BlockingPipelineRunner()
        }

        model.resumeProject(at: firstURL)
        await fulfillment(of: [firstToolchainStarted], timeout: 2.0)
        model.resumeProject(at: secondURL)
        try await waitForCurrentProjectURL(model: model, url: secondURL)

        manager.emitFirstProgress(fraction: 0.42, message: "Stale toolchain progress")
        try await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertEqual(model.currentProjectURL, secondURL)
        XCTAssertNotEqual(model.statusDetail, "Stale toolchain progress")
        XCTAssertFalse(model.logLines.contains("[Tools] Stale toolchain progress"))

        manager.finishAll()
        model.cancelCurrentProject(deleteProject: false)
        try await waitForViewState(model: model, state: .home, timeout: 4.0)
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

    /// When the tail seek lands inside a multibyte UTF-8 sequence, we should drop the
    /// partial leading bytes (and the partial line that contained them) rather than
    /// emitting replacement characters in the first surviving line.
    func testLoadPipelineLogTailSkipsPartialFirstLineAtBoundary() throws {
        let tempBase = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempBase, withIntermediateDirectories: true)
        let projectURL = tempBase.appendingPathComponent("Project.easysplatproj", isDirectory: true)
        try FileManager.default.createDirectory(at: projectURL, withIntermediateDirectories: true)
        let paths = ProjectPaths(root: projectURL)
        try paths.ensureDirectories()

        // Pad past the tail window so the seek lands inside this leading line, mid-emoji.
        // U+1F4A1 (light bulb) is a 4-byte sequence "F0 9F 92 A1" — a great victim for a mid-byte seek.
        var logData = Data()
        logData.append(contentsOf: String(repeating: "x", count: 200).utf8)
        logData.append(contentsOf: "💡 lead-in to be sliced\n".utf8)
        for index in 0..<10 {
            logData.append(contentsOf: "[stage] tail entry \(index)\n".utf8)
        }
        try logData.write(to: paths.pipelineLogURL, options: [.atomic])

        let model = AppModel(toolchainManager: MockToolchainManager(), projectBaseURL: tempBase) { _, config in
            MockPipelineRunner(projectURL: projectURL, config: config)
        }

        // Tail window deliberately smaller than the leading "x"-padding so the seek lands inside.
        let lines = model.test_loadPipelineLogTail(projectURL: projectURL, maxLines: 100, maxBytes: 150)

        // The partial first line is dropped entirely — no Unicode replacement chars survive.
        for line in lines {
            XCTAssertFalse(line.contains("\u{FFFD}"), "tail emitted a replacement char in: \(line)")
            XCTAssertFalse(line.contains("lead-in to be sliced"), "tail kept a partial leading line: \(line)")
        }
        // The whole tail entries that came after the boundary are still present.
        XCTAssertTrue(lines.contains { $0.contains("tail entry 9") }, "expected last tail line; got \(lines)")
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

    /// A project whose metadata uses a future formatVersion should appear in the listing
    /// with `.needsAppUpdate` so the user gets a clear prompt to update, instead of the
    /// project silently disappearing.
    func testRefreshProjectSummariesSurfacesUnsupportedFormatVersion() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)

        let projectURL = base.appendingPathComponent("FromTheFuture.easysplatproj", isDirectory: true)
        try FileManager.default.createDirectory(at: projectURL, withIntermediateDirectories: true)
        let metadataURL = projectURL.appendingPathComponent("project.json")
        let futureVersion = ProjectMetadataStore.supportedFormatVersion + 1
        let raw = """
        {
          "createdAt":"1970-01-01T00:00:00Z",
          "formatVersion":\(futureVersion),
          "id":"00000000-0000-0000-0000-000000000003",
          "input":{"photos":{"folder":"/tmp/photos"}},
          "preset":{"mode":"object","quality":"standard"},
          "state":{"attempt":0,"lastError":null,"resumeToken":null,"stage":"importInput"},
          "title":"User-chosen title"
        }
        """
        try raw.write(to: metadataURL, atomically: true, encoding: .utf8)

        let model = AppModel(toolchainManager: MockToolchainManager(), projectBaseURL: base) { _, config in
            MockPipelineRunner(projectURL: base, config: config)
        }
        model.refreshProjectSummaries()

        // contentsOfDirectory may canonicalize /tmp/... → /private/tmp/... on macOS, so
        // match by directory name rather than URL identity.
        let summary = try XCTUnwrap(
            model.projectSummaries.first {
                $0.url.lastPathComponent == projectURL.lastPathComponent
            },
            "expected a summary for FromTheFuture.easysplatproj; got titles: \(model.projectSummaries.map(\.title))"
        )
        XCTAssertEqual(summary.status, .needsAppUpdate)
        // Title should be preserved from the JSON peek so the user recognizes their project.
        XCTAssertEqual(summary.title, "User-chosen title")
    }

    /// A future build may add or rename required fields, so the listing must surface
    /// `.needsAppUpdate` even when the strict ProjectMetadata decoder cannot make sense
    /// of the file at all. The formatVersion guard short-circuits before strict decode.
    func testRefreshProjectSummariesSurfacesUnsupportedFormatVersionWithChangedSchema() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)

        let projectURL = base.appendingPathComponent("ChangedSchema.easysplatproj", isDirectory: true)
        try FileManager.default.createDirectory(at: projectURL, withIntermediateDirectories: true)
        let metadataURL = projectURL.appendingPathComponent("project.json")
        let futureVersion = ProjectMetadataStore.supportedFormatVersion + 1
        // Deliberately omit `state`, `input`, `preset`, `id`, `createdAt`. Today's strict
        // decoder cannot make sense of this — but the formatVersion bump must still surface.
        let raw = """
        {
          "formatVersion":\(futureVersion),
          "title":"Renamed-Schema project",
          "renamedField":42
        }
        """
        try raw.write(to: metadataURL, atomically: true, encoding: .utf8)

        let model = AppModel(toolchainManager: MockToolchainManager(), projectBaseURL: base) { _, config in
            MockPipelineRunner(projectURL: base, config: config)
        }
        model.refreshProjectSummaries()

        let summary = try XCTUnwrap(
            model.projectSummaries.first {
                $0.url.lastPathComponent == projectURL.lastPathComponent
            },
            "expected ChangedSchema project to surface as needsAppUpdate; got \(model.projectSummaries.map(\.title))"
        )
        XCTAssertEqual(summary.status, .needsAppUpdate)
        XCTAssertEqual(summary.title, "Renamed-Schema project")
    }

    func testRefreshProjectSummariesDoesNotMarkOutputDirectoryReady() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let projectURL = base.appendingPathComponent("DirectoryOutput.easysplatproj", isDirectory: true)
        try FileManager.default.createDirectory(at: projectURL, withIntermediateDirectories: true)
        let paths = ProjectPaths(root: projectURL)
        try paths.ensureDirectories()
        try FileManager.default.createDirectory(
            at: paths.outputURL.appendingPathComponent("splat.ply", isDirectory: true),
            withIntermediateDirectories: true
        )
        let metadata = ProjectMetadata(
            title: "DirectoryOutput",
            input: .photos(folder: "/tmp/photos"),
            preset: PresetSpec(mode: .object, quality: .standard),
            state: PipelineState(stage: .done, attempt: 0, lastError: nil, resumeToken: nil),
            outputs: OutputSpec(splatPlyPath: "Output/splat.ply", colmapModelPath: "SfM/colmap/sparse/0")
        )
        try ProjectMetadataStore.save(metadata, to: paths.metadataURL)

        let model = AppModel(toolchainManager: MockToolchainManager(), projectBaseURL: base) { _, config in
            MockPipelineRunner(projectURL: base, config: config)
        }
        model.refreshProjectSummaries()

        XCTAssertEqual(model.projectSummaries.first?.status, .inProgress)
    }

    func testRefreshProjectSummariesDoesNotMarkCorruptOutputReady() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let projectURL = base.appendingPathComponent("CorruptOutput.easysplatproj", isDirectory: true)
        try FileManager.default.createDirectory(at: projectURL, withIntermediateDirectories: true)
        let paths = ProjectPaths(root: projectURL)
        try paths.ensureDirectories()
        try "ply".write(to: paths.outputURL.appendingPathComponent("splat.ply"), atomically: true, encoding: .utf8)
        let metadata = ProjectMetadata(
            title: "CorruptOutput",
            input: .photos(folder: "/tmp/photos"),
            preset: PresetSpec(mode: .object, quality: .standard),
            state: PipelineState(stage: .done, attempt: 0, lastError: nil, resumeToken: nil),
            outputs: OutputSpec(splatPlyPath: "Output/splat.ply", colmapModelPath: "SfM/colmap/sparse/0")
        )
        try ProjectMetadataStore.save(metadata, to: paths.metadataURL)

        let model = AppModel(toolchainManager: MockToolchainManager(), projectBaseURL: base) { _, config in
            MockPipelineRunner(projectURL: base, config: config)
        }
        model.refreshProjectSummaries()

        XCTAssertEqual(model.projectSummaries.first?.status, .inProgress)
        XCTAssertNil(model.projectSummaries.first?.outputPlyURL)
    }

    func testRefreshProjectSummariesDoesNotDeepScanLargeAsciiOutput() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let projectURL = base.appendingPathComponent("LargeAsciiOutput.easysplatproj", isDirectory: true)
        try FileManager.default.createDirectory(at: projectURL, withIntermediateDirectories: true)
        let paths = ProjectPaths(root: projectURL)
        try paths.ensureDirectories()
        try """
        ply
        format ascii 1.0
        element vertex 1000000
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
        0 0 0 1 1 1 -4 -4 -4 1 1 0 0 0
        """.write(to: paths.outputURL.appendingPathComponent("splat.ply"), atomically: true, encoding: .utf8)
        let metadata = ProjectMetadata(
            title: "LargeAsciiOutput",
            input: .photos(folder: "/tmp/photos"),
            preset: PresetSpec(mode: .object, quality: .standard),
            state: PipelineState(stage: .done, attempt: 0, lastError: nil, resumeToken: nil),
            outputs: OutputSpec(splatPlyPath: "Output/splat.ply", colmapModelPath: "SfM/colmap/sparse/0")
        )
        try ProjectMetadataStore.save(metadata, to: paths.metadataURL)

        let model = AppModel(toolchainManager: MockToolchainManager(), projectBaseURL: base) { _, config in
            MockPipelineRunner(projectURL: base, config: config)
        }
        model.refreshProjectSummaries()

        XCTAssertEqual(model.projectSummaries.first?.status, .ready)
        XCTAssertEqual(model.projectSummaries.first?.outputPlyURL?.lastPathComponent, "splat.ply")
    }

    func testRefreshProjectSummariesRejectsEscapingOutputPath() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let projectURL = base.appendingPathComponent("EscapingOutput.easysplatproj", isDirectory: true)
        try FileManager.default.createDirectory(at: projectURL, withIntermediateDirectories: true)
        let paths = ProjectPaths(root: projectURL)
        try paths.ensureDirectories()
        let outside = base.appendingPathComponent("outside.ply")
        try writeMinimalPly(at: outside)
        let metadata = ProjectMetadata(
            title: "EscapingOutput",
            input: .photos(folder: "/tmp/photos"),
            preset: PresetSpec(mode: .object, quality: .standard),
            state: PipelineState(stage: .done, attempt: 0, lastError: nil, resumeToken: nil),
            outputs: OutputSpec(splatPlyPath: "../outside.ply", colmapModelPath: "SfM/colmap/sparse/0")
        )
        try ProjectMetadataStore.save(metadata, to: paths.metadataURL)

        let model = AppModel(toolchainManager: MockToolchainManager(), projectBaseURL: base) { _, config in
            MockPipelineRunner(projectURL: base, config: config)
        }
        model.refreshProjectSummaries()

        XCTAssertEqual(model.projectSummaries.first?.status, .inProgress)
        XCTAssertNil(model.projectSummaries.first?.outputPlyURL)
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

    func testDeleteInterruptedProjectTreatsAlreadyMissingDirectoryAsDeleted() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let url = try makeProject(
            at: base,
            name: "InterruptedAlreadyMissing",
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
        try FileManager.default.removeItem(at: url)

        model.deleteInterruptedProject(prompt)

        XCTAssertNil(model.recoveryPromptProject)
        XCTAssertTrue(model.ignoredRecoveryProjectIDs.contains(prompt.id))
        XCTAssertFalse(model.projectSummaries.contains(where: { $0.id == prompt.id }))
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

    func testForcedWindowCloseKeepsBypassUntilDelegateConsumesIt() {
        let tempBase = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let model = AppModel(toolchainManager: MockToolchainManager(), projectBaseURL: tempBase) { _, config in
            MockPipelineRunner(projectURL: tempBase, config: config)
        }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 120, height: 80),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false

        model.stopAction = .keepProject
        model.exitIntent = .closeWindow
        model.pendingCloseWindow = window

        model.forceFinalizeExit(intent: .closeWindow, window: window)

        XCTAssertTrue(model.allowNextWindowClose)
        XCTAssertTrue(model.pendingCloseWindow === window)
        XCTAssertEqual(model.exitIntent, .closeWindow)
        XCTAssertTrue(model.consumeWindowCloseBypass(for: window))
        XCTAssertFalse(model.allowNextWindowClose)
        XCTAssertNil(model.pendingCloseWindow)
        XCTAssertEqual(model.exitIntent, .none)
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

    func testRefreshProjectSummariesReplacesStaleRecoveryPrompt() throws {
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
        model.recoveryPromptProject = summaryA

        let paths = ProjectPaths(root: projectA)
        try FileManager.default.createDirectory(at: paths.outputURL, withIntermediateDirectories: true)
        try writeMinimalPly(at: paths.outputURL.appendingPathComponent("splat.ply"))
        var metadata = try ProjectMetadataStore.load(from: paths.metadataURL)
        metadata.outputs = OutputSpec(splatPlyPath: "Output/splat.ply", colmapModelPath: "SfM/colmap/sparse/0")
        metadata.state = PipelineState(stage: .done, attempt: metadata.state.attempt, lastError: nil, resumeToken: nil)
        metadata.checkpoint = nil
        try ProjectMetadataStore.save(metadata, to: paths.metadataURL)

        model.refreshProjectSummaries()

        XCTAssertEqual(model.recoveryPromptProject?.title, "InterruptedB")
    }

    func testAppConfigLoadsBundledPublicKeyAndHonorsEnvOverrides() async throws {
        let expectedPublicKey = try String(contentsOf: appResourceURL(named: "public_key_ed25519.txt"), encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        await withAppEnvironmentAsync([
            "EASYSPLAT_PROJECT_HOME_URL": nil,
            "EASYSPLAT_TOOLCHAIN_MANIFEST_URL": nil,
            "EASYSPLAT_TOOLCHAIN_PUBLIC_KEY_BASE64": nil,
        ]) {
            XCTAssertEqual(AppConfig.toolchainPublicKeyBase64, expectedPublicKey)
            XCTAssertFalse(AppConfig.toolchainPublicKeyBase64.isEmpty)
        }

        await withAppEnvironmentAsync([
            "EASYSPLAT_PROJECT_HOME_URL": "https://example.com/project-home",
            "EASYSPLAT_TOOLCHAIN_MANIFEST_URL": "https://example.com/toolchain/manifest.json",
            "EASYSPLAT_TOOLCHAIN_PUBLIC_KEY_BASE64": "OVERRIDE_PUBLIC_KEY_BASE64",
        ]) {
            XCTAssertEqual(AppConfig.projectHomeURL.absoluteString, "https://example.com/project-home")
            XCTAssertEqual(AppConfig.toolchainManifestURL.absoluteString, "https://example.com/toolchain/manifest.json")
            XCTAssertEqual(AppConfig.toolchainPublicKeyBase64, "OVERRIDE_PUBLIC_KEY_BASE64")
        }
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
        XCTAssertTrue(events.contains("\"event\":\"share_clicked\""))
        XCTAssertTrue(
            events.contains("\"event\":\"share_caption_copied\"")
                || events.contains("\"event\":\"share_sheet_opened\"")
        )
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

    func testShareCurrentSplatRejectsFallbackOutputFromDifferentProject() throws {
        let tempBase = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempBase) }
        try FileManager.default.createDirectory(at: tempBase, withIntermediateDirectories: true)
        let firstURL = try makeProject(at: tempBase, name: "First", lastError: nil, withOutput: true)
        let secondURL = try makeProject(at: tempBase, name: "Second", lastError: nil, withOutput: false)
        let firstOutput = ProjectPaths(root: firstURL).outputURL.appendingPathComponent("splat.ply")
        let model = AppModel(toolchainManager: MockToolchainManager(), projectBaseURL: tempBase) { _, config in
            MockPipelineRunner(projectURL: secondURL, config: config)
        }
        model.currentProjectURL = secondURL
        model.outputPlyURL = firstOutput

        model.shareCurrentSplat()

        XCTAssertTrue(model.shareStatusIsError)
        XCTAssertEqual(model.shareMetrics.shareClickedCount, 0)
        let metadata = try ProjectMetadataStore.load(from: ProjectPaths(root: secondURL).metadataURL)
        XCTAssertNil(metadata.shareMetrics)
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

    private func waitForCurrentProjectURL(model: AppModel, url: URL, timeout: TimeInterval = 2.0) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if model.currentProjectURL == url {
                return
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTFail("Timed out waiting for currentProjectURL to become \(url)")
    }

    private func waitForLastError(model: AppModel, timeout: TimeInterval = 2.0) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if model.lastError != nil {
                return
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTFail("Timed out waiting for lastError")
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
            try writeMinimalPly(at: paths.outputURL.appendingPathComponent("splat.ply"))
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

private actor AppTestEnvironmentLock {
    static let shared = AppTestEnvironmentLock()
    private var locked = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func lock() async {
        if !locked {
            locked = true
            return
        }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func unlock() {
        if waiters.isEmpty {
            locked = false
            return
        }
        let next = waiters.removeFirst()
        next.resume()
    }
}

@MainActor
@discardableResult
private func withAppEnvironmentAsync<T>(
    _ changes: [String: String?],
    _ body: @MainActor () async throws -> T
) async rethrows -> T {
    await AppTestEnvironmentLock.shared.lock()
    let previous = captureAppEnvironment(changes)
    applyAppEnvironment(changes)
    do {
        let result = try await body()
        restoreAppEnvironment(previous)
        await AppTestEnvironmentLock.shared.unlock()
        return result
    } catch {
        restoreAppEnvironment(previous)
        await AppTestEnvironmentLock.shared.unlock()
        throw error
    }
}

private func appResourceURL(named name: String) -> URL {
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("EasySplatApp/Resources/\(name)")
}

private func captureAppEnvironment(_ changes: [String: String?]) -> [String: String?] {
    var previous: [String: String?] = [:]
    for key in changes.keys {
        previous[key] = RuntimeEnvironment.value(forKey: key)
    }
    return previous
}

private func applyAppEnvironment(_ changes: [String: String?]) {
    for (key, value) in changes {
        RuntimeEnvironment.setValue(value, forKey: key)
    }
}

private func restoreAppEnvironment(_ previous: [String: String?]) {
    for (key, value) in previous {
        RuntimeEnvironment.setValue(value, forKey: key)
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

struct FailingToolchainManager: ToolchainManaging {
    var message: String

    func ensureToolchain(
        manifestURL: URL,
        publicKeyBase64: String,
        targetName: String,
        onProgress: @escaping @Sendable (Double, String) -> Void
    ) async throws -> ToolchainPaths {
        throw NSError(domain: "FailingToolchainManager", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}

final class DelayedProgressToolchainManager: @unchecked Sendable, ToolchainManaging {
    private let firstStarted: XCTestExpectation
    private let lock = NSLock()
    private var continuations: [CheckedContinuation<ToolchainPaths, Error>] = []
    private var firstProgress: (@Sendable (Double, String) -> Void)?
    private var callCount = 0

    init(firstStarted: XCTestExpectation) {
        self.firstStarted = firstStarted
    }

    func ensureToolchain(
        manifestURL: URL,
        publicKeyBase64: String,
        targetName: String,
        onProgress: @escaping @Sendable (Double, String) -> Void
    ) async throws -> ToolchainPaths {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            callCount += 1
            if callCount == 1 {
                firstProgress = onProgress
                firstStarted.fulfill()
            }
            continuations.append(continuation)
            lock.unlock()
        }
    }

    func emitFirstProgress(fraction: Double, message: String) {
        lock.lock()
        let progress = firstProgress
        lock.unlock()
        progress?(fraction, message)
    }

    func finishAll() {
        lock.lock()
        let pending = continuations
        continuations = []
        lock.unlock()
        let toolchain = mockToolchainPaths()
        for continuation in pending {
            continuation.resume(returning: toolchain)
        }
    }

    private func mockToolchainPaths() -> ToolchainPaths {
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

final class DelayedCancellationPipelineRunner: @unchecked Sendable, PipelineRunning {
    private let waitingForCancellation: XCTestExpectation
    private let cancellationObserved: XCTestExpectation
    private let runFinished: XCTestExpectation
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Never>?
    private var didCancel = false

    init(
        waitingForCancellation: XCTestExpectation,
        cancellationObserved: XCTestExpectation,
        runFinished: XCTestExpectation
    ) {
        self.waitingForCancellation = waitingForCancellation
        self.cancellationObserved = cancellationObserved
        self.runFinished = runFinished
    }

    func run(resumeFrom lastCompletedStage: PipelineStage?, events: @escaping @Sendable (PipelineEvent) -> Void) async throws {
        events(.stageStarted(stage: .trainBrush))
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                let shouldResume: Bool
                lock.lock()
                if didCancel {
                    shouldResume = true
                } else {
                    self.continuation = continuation
                    shouldResume = false
                }
                lock.unlock()
                waitingForCancellation.fulfill()
                if shouldResume {
                    continuation.resume()
                }
            }
        } onCancel: {
            finishCancellation()
        }
        runFinished.fulfill()
        throw CancellationError()
    }

    private func finishCancellation() {
        let continuation: CheckedContinuation<Void, Never>?
        lock.lock()
        didCancel = true
        continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        cancellationObserved.fulfill()
        continuation?.resume()
    }
}

final class LateFailingPipelineRunner: @unchecked Sendable, PipelineRunning {
    private let started: XCTestExpectation
    private let finished: XCTestExpectation
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Never>?

    init(started: XCTestExpectation, finished: XCTestExpectation) {
        self.started = started
        self.finished = finished
    }

    func run(resumeFrom lastCompletedStage: PipelineStage?, events: @escaping @Sendable (PipelineEvent) -> Void) async throws {
        events(.stageStarted(stage: .importInput))
        started.fulfill()
        await withCheckedContinuation { continuation in
            lock.lock()
            self.continuation = continuation
            lock.unlock()
        }
        events(.pipelineFailed(stage: .importInput, userMessage: "First project failed", debugMessage: "late failure"))
        finished.fulfill()
        throw NSError(domain: "LateFailingPipelineRunner", code: 1, userInfo: [
            NSLocalizedDescriptionKey: "First project failed"
        ])
    }

    func finish() {
        lock.lock()
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume()
    }
}

final class LateCompletingPipelineRunner: @unchecked Sendable, PipelineRunning {
    private let projectURL: URL
    private let started: XCTestExpectation
    private let finished: XCTestExpectation
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Never>?

    init(projectURL: URL, started: XCTestExpectation, finished: XCTestExpectation) {
        self.projectURL = projectURL
        self.started = started
        self.finished = finished
    }

    func run(resumeFrom lastCompletedStage: PipelineStage?, events: @escaping @Sendable (PipelineEvent) -> Void) async throws {
        events(.stageStarted(stage: .importInput))
        started.fulfill()
        await withCheckedContinuation { continuation in
            lock.lock()
            self.continuation = continuation
            lock.unlock()
        }
        events(.stageProgress(stage: .importInput, fraction: 1.0, message: "Stale import"))
        let paths = ProjectPaths(root: projectURL)
        let outputURL = paths.outputURL.appendingPathComponent("splat.ply")
        try FileManager.default.createDirectory(at: paths.outputURL, withIntermediateDirectories: true)
        try writeMinimalPly(at: outputURL)
        var metadata = try ProjectMetadataStore.load(from: paths.metadataURL)
        metadata.outputs = OutputSpec(splatPlyPath: "Output/splat.ply", colmapModelPath: "SfM/colmap/sparse/0")
        metadata.state = PipelineState(stage: .done, attempt: 0, lastError: nil, resumeToken: nil)
        try ProjectMetadataStore.save(metadata, to: paths.metadataURL)
        finished.fulfill()
    }

    func finish() {
        lock.lock()
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume()
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
        try writeMinimalPly(at: outputURL)
        metadata.outputs = OutputSpec(splatPlyPath: "Output/splat.ply", colmapModelPath: "SfM/colmap/sparse/0")
        metadata.state = PipelineState(stage: .done, attempt: 0, lastError: nil, resumeToken: nil)
        try ProjectMetadataStore.save(metadata, to: paths.metadataURL)
    }
}

final class MissingOutputPipelineRunner: PipelineRunning {
    private let projectURL: URL

    init(projectURL: URL) {
        self.projectURL = projectURL
    }

    func run(resumeFrom lastCompletedStage: PipelineStage?, events: @escaping @Sendable (PipelineEvent) -> Void) async throws {
        let paths = ProjectPaths(root: projectURL)
        var metadata = try ProjectMetadataStore.load(from: paths.metadataURL)
        metadata.outputs = OutputSpec(splatPlyPath: "Output/missing.ply", colmapModelPath: "SfM/colmap/sparse/0")
        metadata.state = PipelineState(stage: .done, attempt: 0, lastError: nil, resumeToken: nil)
        try ProjectMetadataStore.save(metadata, to: paths.metadataURL)
    }
}

final class DirectoryOutputRepairingPipelineRunner: PipelineRunning {
    private let projectURL: URL
    private(set) var didRun = false

    init(projectURL: URL) {
        self.projectURL = projectURL
    }

    func run(resumeFrom lastCompletedStage: PipelineStage?, events: @escaping @Sendable (PipelineEvent) -> Void) async throws {
        didRun = true
        let paths = ProjectPaths(root: projectURL)
        let outputURL = paths.outputURL.appendingPathComponent("splat.ply")
        if FileManager.default.fileExists(atPath: outputURL.path) {
            try FileManager.default.removeItem(at: outputURL)
        }
        try FileManager.default.createDirectory(at: paths.outputURL, withIntermediateDirectories: true)
        try writeMinimalPly(at: outputURL)

        var metadata = try ProjectMetadataStore.load(from: paths.metadataURL)
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

private func writeMinimalPly(at url: URL, vertexCount: Int = 1) throws {
    let safeCount = max(1, vertexCount)
    let body = (0..<safeCount).map { _ in
        "0 0 0 1 1 1 -4 -4 -4 1 1 0 0 0"
    }.joined(separator: "\n")
    let text = """
    ply
    format ascii 1.0
    element vertex \(safeCount)
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
    """
    try text.write(to: url, atomically: true, encoding: .utf8)
}
#endif
