#if canImport(XCTest)
import AppKit
import CoreGraphics
import Darwin
import Foundation
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import EasySplatApp
@testable import EasySplatCore

@MainActor
final class AppModelTests: XCTestCase {
    func testRequestedRunOptionsUseProfessionalDefaults() {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let model = AppModel(toolchainManager: MockToolchainManager(), projectBaseURL: base) { url, config in
            MockPipelineRunner(projectURL: url, config: config)
        }

        XCTAssertEqual(model.requestedRunOptions, RequestedRunOptions())
        XCTAssertEqual(model.requestedRunOptions.capturePath, .automatic)
        XCTAssertEqual(model.requestedRunOptions.detailProfile, .balanced)
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
        XCTAssertFalse(model.isRunActive)
        XCTAssertNotNil(model.currentProjectURL)
        XCTAssertNotNil(model.outputPlyURL)
        XCTAssertTrue(model.pendingVideoURLs.isEmpty)
        XCTAssertNil(model.pendingPhotosFolderURL)
        guard let projectURL = model.currentProjectURL else {
            XCTFail("Missing project URL")
            return
        }
        let summary = model.projectSummaries.first {
            ProjectSummary.hasSameLocation($0.url, projectURL)
        }
        XCTAssertEqual(summary?.status, .ready)
        XCTAssertEqual(summary?.isActive, false)
        let metadataURL = projectURL.appendingPathComponent("project.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: metadataURL.path))
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

    func testCountImageFilesStopsAtRecommendationThreshold() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for index in 0..<100 {
            try Data("img".utf8).write(to: folder.appendingPathComponent("photo\(index).jpg"))
        }

        XCTAssertEqual(AppModel.countImageFiles(in: folder), AppModel.minimumRecommendedPhotos)
    }

    func testCountImageFilesStopsAtTheTraversalLimit() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for index in 0..<8 {
            try Data("not an image".utf8).write(
                to: folder.appendingPathComponent("file-\(index).txt")
            )
        }

        XCTAssertNil(AppModel.countImageFiles(in: folder, maximumVisitedEntries: 3))
    }

    func testCountImageFilesReturnsNilForMissingFolder() {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("missing-\(UUID().uuidString)")
        XCTAssertNil(AppModel.countImageFiles(in: folder))
    }

    func testAddInputsWarnsForThinPhotoFolder() async throws {
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
        for _ in 0..<100 where model.selectionWarning == nil {
            try await Task.sleep(for: .milliseconds(10))
        }
        let warning = try XCTUnwrap(model.selectionWarning)
        XCTAssertTrue(warning.contains("Thin"), "Warning should name the folder, got: \(warning)")
        XCTAssertTrue(warning.contains("3 image"), "Warning should mention the actual count, got: \(warning)")

        model.removePhotoFolder()
        XCTAssertNil(model.pendingPhotosFolderURL)
        XCTAssertNil(model.selectionWarning)
    }

    func testAddInputsKeepsFirstPhotoFolderAndWarnsAboutTheRest() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let first = base.appendingPathComponent("First", isDirectory: true)
        let second = base.appendingPathComponent("Second", isDirectory: true)
        try FileManager.default.createDirectory(at: first, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: second, withIntermediateDirectories: true)
        for index in 0..<AppModel.minimumRecommendedPhotos {
            try Data("image".utf8).write(to: first.appendingPathComponent("photo-\(index).jpg"))
        }
        let model = AppModel(toolchainManager: MockToolchainManager(), projectBaseURL: base)

        model.addInputs(urls: [first, second])

        XCTAssertEqual(model.pendingPhotosFolderURL, first)
        XCTAssertEqual(
            model.selectionWarning,
            "Ignored 1 additional photo folder. EasySplat uses one photo folder per splat."
        )
    }

    func testAddingSeparateClipsResetsContinuousOrderingBeforeSubmission() {
        let model = AppModel(toolchainManager: MockToolchainManager())
        model.requestedRunOptions.inputOrdering = .continuous

        model.addInputs(urls: [
            URL(fileURLWithPath: "/tmp/one.mov"),
            URL(fileURLWithPath: "/tmp/two.mov"),
        ])

        XCTAssertEqual(model.requestedRunOptions.inputOrdering, .automatic)
        XCTAssertEqual(
            model.selectionWarning,
            "Continuous sequence works with one video. Input Order was reset to Automatic."
        )
    }

    func testConstrainedResourceChoiceHasPlainExplanation() {
        XCTAssertFalse(HomeView.maximumPerformanceIsAvailable(memoryGB: 16.5))
        XCTAssertEqual(
            HomeView.resourceUseHelp(memoryGB: 16.5),
            "Maximum Performance is unavailable on Macs with 16 GB of unified memory or less."
        )
        XCTAssertTrue(HomeView.maximumPerformanceIsAvailable(memoryGB: 24))
        XCTAssertNil(HomeView.resourceUseHelp(memoryGB: 24))
    }

    func testDetailAvailabilityHelpExplainsDisabledChoices() {
        XCTAssertEqual(
            HomeView.detailAvailabilityHelp(memoryGB: 8),
            "Balanced and High Detail need more than 8 GB of unified memory."
        )
        XCTAssertEqual(
            HomeView.detailAvailabilityHelp(memoryGB: 16),
            "High Detail needs at least 24 GB of unified memory."
        )
        XCTAssertNil(HomeView.detailAvailabilityHelp(memoryGB: 24))
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
            requestedRunOptions: RequestedRunOptions(capturePath: .orbit, detailProfile: .balanced)
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
                requestedRunOptions: RequestedRunOptions(capturePath: .orbit, detailProfile: .balanced)
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
        XCTAssertTrue(model.flushPendingNotesSave())
        XCTAssertEqual(model.notesSaveState, .saved)
        let reloaded = try ProjectMetadataStore.load(from: ProjectPaths(root: projectURL).metadataURL)
        XCTAssertEqual(reloaded.notes, "last edit",
                       "flushPendingNotesSave must persist the pending value, not lose it.")
    }

    func testFailedNotesFlushKeepsLastEditForRetry() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let projectURL = base.appendingPathComponent("LateMount.easysplatproj", isDirectory: true)
        let model = AppModel(toolchainManager: MockToolchainManager(), projectBaseURL: base) { url, config in
            MockPipelineRunner(projectURL: url, config: config)
        }
        model.currentProjectURL = projectURL
        model.scheduleNotesSave(at: projectURL, to: "final keystroke")

        XCTAssertFalse(model.flushPendingNotesSave())
        XCTAssertEqual(model.pendingNotesSave?.text, "final keystroke")
        guard case .failed = model.notesSaveState else {
            return XCTFail("A failed notes write must remain visible")
        }

        try FileManager.default.createDirectory(at: projectURL, withIntermediateDirectories: true)
        try ProjectMetadataStore.save(
            ProjectMetadata(
                title: "LateMount",
                input: .photos(folder: "/tmp/photos"),
                requestedRunOptions: RequestedRunOptions()
            ),
            to: ProjectPaths(root: projectURL).metadataURL
        )

        XCTAssertTrue(model.flushPendingNotesSave())
        XCTAssertNil(model.pendingNotesSave)
        XCTAssertEqual(
            try ProjectMetadataStore.load(from: ProjectPaths(root: projectURL).metadataURL).notes,
            "final keystroke"
        )
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
                requestedRunOptions: RequestedRunOptions(capturePath: .orbit, detailProfile: .balanced)
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

    func testFreshProcessingRunExposesActiveOptionsAndInput() async throws {
        let tempBase = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempBase) }
        try FileManager.default.createDirectory(at: tempBase, withIntermediateDirectories: true)
        let input = tempBase.appendingPathComponent("clip.mov")
        try Data("video".utf8).write(to: input)

        let model = AppModel(toolchainManager: MockToolchainManager(), projectBaseURL: tempBase) { _, _ in
            BlockingPipelineRunner()
        }
        model.requestedRunOptions.capturePath = .walkthrough
        model.requestedRunOptions.detailProfile = .highDetail
        model.addInputs(urls: [input])
        model.startFromPendingSelection()

        try await waitForViewState(model: model, state: .processing)

        XCTAssertEqual(model.currentRunOptions?.capturePath, .walkthrough)
        XCTAssertEqual(model.currentRunOptions?.detailProfile, .highDetail)
        if case .video(let files) = model.currentInput {
            XCTAssertEqual(files, [input.path])
        } else {
            XCTFail("Expected active video input while processing.")
        }

        model.cancelCurrentProject(deleteProject: false)
        try await waitForViewState(model: model, state: .home, timeout: 4.0)
    }

    func testFreshDurableRunAppearsActiveInProjectLibraryBeforeCompletion() async throws {
        let tempBase = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempBase) }
        try FileManager.default.createDirectory(at: tempBase, withIntermediateDirectories: true)
        let input = tempBase.appendingPathComponent("clip.mov")
        try Data("video".utf8).write(to: input)

        let model = AppModel(toolchainManager: MockToolchainManager(), projectBaseURL: tempBase) { _, _ in
            BlockingPipelineRunner()
        }
        model.addInputs(urls: [input])
        model.startFromPendingSelection()

        let deadline = Date().addingTimeInterval(2)
        var activeSummary: ProjectSummary?
        while Date() < deadline, activeSummary == nil {
            if let projectURL = model.currentProjectURL {
                activeSummary = model.projectSummaries.first {
                    ProjectSummary.hasSameLocation($0.url, projectURL) && $0.isActive
                }
            }
            if activeSummary == nil {
                try await Task.sleep(nanoseconds: 25_000_000)
            }
        }

        XCTAssertEqual(activeSummary?.status, .inProgress)
        XCTAssertEqual(activeSummary?.title, "clip")
        XCTAssertTrue(model.isRunActive)

        model.lastError = "A stage reported a failure"
        model.viewState = .home
        model.refreshProjectSummaries()
        let currentProjectURL = try XCTUnwrap(model.currentProjectURL)
        let stillActive = model.projectSummaries.first {
            ProjectSummary.hasSameLocation($0.url, currentProjectURL)
        }
        XCTAssertEqual(stillActive?.isActive, true)
        XCTAssertEqual(stillActive?.status, .inProgress)

        model.cancelCurrentProject(deleteProject: false)
        try await waitForViewState(model: model, state: .home, timeout: 4.0)
    }

    func testIdleDeleteMovesProjectToTrashWithoutRemovingItDirectly() throws {
        let tempBase = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempBase) }
        let projectURL = tempBase.appendingPathComponent("Failed.easysplatproj", isDirectory: true)
        try FileManager.default.createDirectory(at: projectURL, withIntermediateDirectories: true)
        var trashedURLs: [URL] = []
        let model = AppModel(
            toolchainManager: MockToolchainManager(),
            projectBaseURL: tempBase,
            pipelineRunnerFactory: { url, config in
                MockPipelineRunner(projectURL: url, config: config)
            },
            projectTrashHandler: { trashedURLs.append($0) }
        )
        model.currentProjectURL = projectURL
        model.viewState = .processing

        model.cancelCurrentProject(deleteProject: true)

        XCTAssertEqual(trashedURLs, [projectURL])
        XCTAssertTrue(FileManager.default.fileExists(atPath: projectURL.path))
        XCTAssertEqual(model.viewState, .home)
        XCTAssertNil(model.currentProjectURL)
    }

    func testIdleTrashFailureKeepsProjectOpen() throws {
        let tempBase = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempBase) }
        let projectURL = tempBase.appendingPathComponent("Failed.easysplatproj", isDirectory: true)
        try FileManager.default.createDirectory(at: projectURL, withIntermediateDirectories: true)
        let model = AppModel(
            toolchainManager: MockToolchainManager(),
            projectBaseURL: tempBase,
            pipelineRunnerFactory: { url, config in
                MockPipelineRunner(projectURL: url, config: config)
            },
            projectTrashHandler: { _ in throw CocoaError(.fileWriteUnknown) }
        )
        model.currentProjectURL = projectURL
        model.viewState = .processing

        model.cancelCurrentProject(deleteProject: true)

        XCTAssertEqual(model.viewState, .processing)
        XCTAssertEqual(model.currentProjectURL, projectURL)
        XCTAssertEqual(model.statusTitle, "Couldn’t move project to Trash")
        XCTAssertNotNil(model.lastError)
        XCTAssertEqual(model.actionFailure?.title, "Couldn’t move project to Trash")
        XCTAssertEqual(
            model.actionFailure?.message,
            "The project stayed in place. Check Finder permissions and try again."
        )
    }

    func testTrashAbortsWhenPendingNotesCannotBeSaved() {
        let tempBase = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempBase) }
        let projectURL = tempBase.appendingPathComponent("Unsaved.easysplatproj", isDirectory: true)
        var trashedURLs: [URL] = []
        let model = AppModel(
            toolchainManager: MockToolchainManager(),
            projectBaseURL: tempBase,
            pipelineRunnerFactory: { url, config in
                MockPipelineRunner(projectURL: url, config: config)
            },
            projectTrashHandler: { trashedURLs.append($0) }
        )
        model.currentProjectURL = projectURL
        model.viewState = .viewer
        model.scheduleNotesSave(at: projectURL, to: "final keystroke")

        XCTAssertFalse(model.moveProjectToTrash(at: projectURL))

        XCTAssertTrue(trashedURLs.isEmpty)
        XCTAssertEqual(model.currentProjectURL, projectURL)
        XCTAssertEqual(model.viewState, .viewer)
        XCTAssertEqual(model.pendingNotesSave?.text, "final keystroke")
        XCTAssertEqual(model.actionFailure?.title, "Couldn’t save notes")
    }

    func testResumeAbortsBeforeChangingRunStateWhenPendingNotesCannotBeSaved() {
        let tempBase = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempBase) }
        let currentProjectURL = tempBase.appendingPathComponent("Unsaved.easysplatproj", isDirectory: true)
        let nextProjectURL = tempBase.appendingPathComponent("Next.easysplatproj", isDirectory: true)
        let model = AppModel(
            toolchainManager: MockToolchainManager(),
            projectBaseURL: tempBase,
            pipelineRunnerFactory: { url, config in
                MockPipelineRunner(projectURL: url, config: config)
            }
        )
        model.currentProjectURL = currentProjectURL
        model.viewState = .viewer
        model.scheduleNotesSave(at: currentProjectURL, to: "final keystroke")

        XCTAssertFalse(model.resumeProject(at: nextProjectURL))

        XCTAssertFalse(model.isRunActive)
        XCTAssertNil(model.currentTask)
        XCTAssertEqual(model.currentProjectURL, currentProjectURL)
        XCTAssertEqual(model.viewState, .viewer)
        XCTAssertEqual(model.pendingNotesSave?.text, "final keystroke")
        XCTAssertEqual(model.actionFailure?.title, "Couldn’t save notes")
    }

    func testRenameFailureUsesAppLevelActionFailure() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let projectURL = base.appendingPathComponent("Unreadable.easysplatproj", isDirectory: true)
        try FileManager.default.createDirectory(at: projectURL, withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: ProjectPaths(root: projectURL).metadataURL)
        let model = AppModel(toolchainManager: MockToolchainManager(), projectBaseURL: base)

        XCTAssertFalse(model.renameProject(at: projectURL, to: "New Name"))
        XCTAssertEqual(model.actionFailure?.title, "Couldn’t rename project")
        XCTAssertEqual(
            model.actionFailure?.message,
            "The project name wasn’t changed. Check folder permissions and try again."
        )
    }

    func testMissingDiagnosticProjectUsesAppLevelActionFailure() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let projectURL = base.appendingPathComponent("Missing.easysplatproj", isDirectory: true)
        let model = AppModel(toolchainManager: MockToolchainManager(), projectBaseURL: base)

        model.copyDiagnosticBundle(forProjectURL: projectURL)

        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline, model.actionFailure == nil {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertEqual(model.actionFailure?.title, "Couldn’t prepare diagnostics")
        XCTAssertEqual(model.actionFailure?.message, "Check the project files and try again.")
    }

    func testSetupExitPresentationHasNoTrashOrResumePromise() {
        let model = AppModel(toolchainManager: MockToolchainManager())

        let presentation = model.exitConfirmationPresentation

        XCTAssertEqual(presentation.title, "Stop setup?")
        XCTAssertEqual(presentation.message, "EasySplat will stop preparing tools. No project has been created.")
        XCTAssertEqual(presentation.primaryActionTitle, "Stop Setup")
        XCTAssertNil(presentation.destructiveActionTitle)
    }

    func testUseAllPhotoPreflightStopsBeforeToolDownloadOrProjectCreation() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let photos = base.appendingPathComponent("Photos", isDirectory: true)
        try FileManager.default.createDirectory(at: photos, withIntermediateDirectories: true)
        for index in 0..<78 {
            let url = photos.appendingPathComponent("photo-\(index).png")
            XCTAssertTrue(try writeTestGrayscaleImage(at: url, value: UInt8(index)))
        }
        let toolchain = CapabilityRecordingToolchainManager()
        let model = AppModel(
            toolchainManager: toolchain,
            projectBaseURL: base,
            hardwareProfile: HardwareProfile(memoryGB: 8, cpuCount: 8, gpuWorkingSetGB: 5)
        ) { projectURL, config in
            MockPipelineRunner(projectURL: projectURL, config: config)
        }
        model.requestedRunOptions.detailProfile = .fast
        model.requestedRunOptions.photoSelection = .useAllValidPhotos
        model.addInputs(urls: [photos])

        model.startFromPendingSelection()
        try await waitForLastError(model: model)
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline, model.isRunActive {
            try await Task.sleep(nanoseconds: 20_000_000)
        }

        XCTAssertEqual(model.validationRecovery, .useAutomaticPhotoSelection)
        XCTAssertNil(toolchain.lastRequest)
        XCTAssertNil(model.currentProjectURL)
        XCTAssertFalse(model.isRunActive)
        let projects = try FileManager.default.contentsOfDirectory(at: base, includingPropertiesForKeys: nil)
        XCTAssertFalse(projects.contains { $0.pathExtension == "easysplatproj" })
    }

    func testAutomaticPhotoPreflightRejectsAllCorruptFolderBeforeSetup() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let photos = base.appendingPathComponent("Photos", isDirectory: true)
        try FileManager.default.createDirectory(at: photos, withIntermediateDirectories: true)
        try Data("not an image".utf8).write(to: photos.appendingPathComponent("broken.jpg"))
        let toolchain = CapabilityRecordingToolchainManager()
        let model = AppModel(toolchainManager: toolchain, projectBaseURL: base) { projectURL, config in
            MockPipelineRunner(projectURL: projectURL, config: config)
        }
        model.requestedRunOptions.photoSelection = .automatic
        model.addInputs(urls: [photos])

        model.startFromPendingSelection()
        try await waitForLastError(model: model)

        XCTAssertEqual(model.lastError, RunPlanResolver.ValidationError.noValidPhotos.localizedDescription)
        XCTAssertNil(toolchain.lastRequest)
        XCTAssertNil(model.currentProjectURL)
        let projects = try FileManager.default.contentsOfDirectory(at: base, includingPropertiesForKeys: nil)
        XCTAssertFalse(projects.contains { $0.pathExtension == "easysplatproj" })
    }

    func testMixedUseAllPreflightReservesVideoFramesBeforeSetup() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let photos = base.appendingPathComponent("Photos", isDirectory: true)
        try FileManager.default.createDirectory(at: photos, withIntermediateDirectories: true)
        let video = base.appendingPathComponent("walkthrough.mov")
        try Data("video".utf8).write(to: video)
        let hardware = HardwareProfile(memoryGB: 8, cpuCount: 8, gpuWorkingSetGB: 5)
        let input = InputSpec.mixed(videos: [video.path], photosFolder: photos.path)
        let options = RequestedRunOptions(
            detailProfile: .fast,
            photoSelection: .useAllValidPhotos
        )
        let plan = RunPlanResolver.resolve(
            requestedOptions: options,
            input: input,
            hardware: hardware,
            developmentOverrides: .none
        )
        let maximum = try XCTUnwrap(RunPlanResolver.maximumValidPhotoCount(for: plan, input: input))
        for index in 0...maximum {
            XCTAssertTrue(try writeTestGrayscaleImage(
                at: photos.appendingPathComponent("photo-\(index).png"),
                value: UInt8(index % 255)
            ))
        }
        let toolchain = CapabilityRecordingToolchainManager()
        let model = AppModel(
            toolchainManager: toolchain,
            projectBaseURL: base,
            hardwareProfile: hardware
        ) { projectURL, config in
            MockPipelineRunner(projectURL: projectURL, config: config)
        }
        model.requestedRunOptions = options
        model.addInputs(urls: [video, photos])

        model.startFromPendingSelection()
        try await waitForLastError(model: model)

        XCTAssertEqual(model.validationRecovery, .useAutomaticPhotoSelection)
        XCTAssertEqual(
            model.lastError,
            RunPlanResolver.ValidationError.photoSelectionExceedsSafeLimit(
                selected: maximum + 1,
                maximum: maximum
            ).localizedDescription
        )
        XCTAssertNil(toolchain.lastRequest)
        XCTAssertNil(model.currentProjectURL)
    }

    func testUserPhaseElapsedTimeDoesNotResetBetweenInternalStages() {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let model = AppModel(toolchainManager: MockToolchainManager(), projectBaseURL: base) { url, config in
            MockPipelineRunner(projectURL: url, config: config)
        }
        let phaseStart = Date(timeIntervalSince1970: 100)
        model.phaseStartedAt = phaseStart

        model.handle(event: .stageStarted(stage: .importInput))
        XCTAssertEqual(model.phaseStartedAt, phaseStart)

        model.handle(event: .stageStarted(stage: .extractFrames))
        XCTAssertEqual(model.phaseStartedAt, phaseStart)

        model.handle(event: .stageStarted(stage: .sfmFeatures))
        XCTAssertNotEqual(model.phaseStartedAt, phaseStart)
    }

    func testStartProjectPersistsEveryRequestedOption() async throws {
        let tempBase = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempBase) }
        try FileManager.default.createDirectory(at: tempBase, withIntermediateDirectories: true)
        let input = tempBase.appendingPathComponent("clip.mov")
        try Data("video".utf8).write(to: input)

        let toolchainManager = CapabilityRecordingToolchainManager()
        var runnerPlan: ResolvedRunPlan?
        let model = AppModel(toolchainManager: toolchainManager, projectBaseURL: tempBase) { projectURL, config in
            runnerPlan = config.resolvedRunPlan
            return MockPipelineRunner(projectURL: projectURL, config: config)
        }
        let options = RequestedRunOptions(
            capturePath: .largeArea,
            detailProfile: .highDetail,
            cameraGrouping: .mixedCamerasOrLenses,
            lensProjection: .fisheye,
            inputOrdering: .continuous,
            resourcePolicy: .maximumPerformance,
            photoSelection: .useAllValidPhotos
        )
        model.requestedRunOptions = options

        await model.startProject(input: .video(files: [input.path]), title: "Walkthrough")

        let projectURL = try XCTUnwrap(model.currentProjectURL)
        let metadata = try ProjectMetadataStore.load(from: ProjectPaths(root: projectURL).metadataURL)
        XCTAssertEqual(metadata.requestedRunOptions, options)
        let persistedPlan = try XCTUnwrap(metadata.resolvedRunPlan)
        XCTAssertEqual(runnerPlan, persistedPlan)
        XCTAssertEqual(
            toolchainManager.lastRequest,
            try persistedPlan.toolchainCapabilityRequest()
        )
        XCTAssertEqual(model.currentRunOptions, options)
    }

    func testFreshStartUsesInjectedConstrainedHardwareProfile() async throws {
        let tempBase = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempBase) }
        try FileManager.default.createDirectory(at: tempBase, withIntermediateDirectories: true)
        let input = tempBase.appendingPathComponent("clip.mov")
        try Data("video".utf8).write(to: input)
        var runnerPlan: ResolvedRunPlan?
        let model = AppModel(
            toolchainManager: CapabilityRecordingToolchainManager(),
            projectBaseURL: tempBase,
            hardwareProfile: HardwareProfile(memoryGB: 8, cpuCount: 8, gpuWorkingSetGB: 5)
        ) { projectURL, config in
            runnerPlan = config.resolvedRunPlan
            return MockPipelineRunner(projectURL: projectURL, config: config)
        }
        model.requestedRunOptions.resourcePolicy = .automatic

        await model.startProject(input: .video(files: [input.path]), title: "Constrained")

        let plan = try XCTUnwrap(runnerPlan)
        XCTAssertEqual(plan.memoryTier, "constrained")
        XCTAssertEqual(plan.modelIdentifier, "DA3-SMALL")
        XCTAssertEqual(plan.keyframeBudget, 77)
    }

    func testChangingPrimaryRunOptionsPreservesProfessionalChoices() {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let model = AppModel(toolchainManager: MockToolchainManager(), projectBaseURL: base) { url, config in
            MockPipelineRunner(projectURL: url, config: config)
        }
        model.requestedRunOptions.cameraGrouping = .sameCameraAndLens
        model.requestedRunOptions.lensProjection = .fisheye

        model.requestedRunOptions.capturePath = .walkthrough
        model.requestedRunOptions.detailProfile = .fast

        XCTAssertEqual(model.requestedRunOptions.capturePath, .walkthrough)
        XCTAssertEqual(model.requestedRunOptions.detailProfile, .fast)
        XCTAssertEqual(model.requestedRunOptions.cameraGrouping, .sameCameraAndLens)
        XCTAssertEqual(model.requestedRunOptions.lensProjection, .fisheye)
    }

    func testResumedProcessingRunExposesPersistedOptionsAndInput() async throws {
        let tempBase = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempBase) }
        try FileManager.default.createDirectory(at: tempBase, withIntermediateDirectories: true)
        let url = try makeProject(at: tempBase, name: "ResumeConfig", lastError: nil, withOutput: false, stage: .sfmFeatures)

        let model = AppModel(toolchainManager: MockToolchainManager(), projectBaseURL: tempBase) { _, _ in
            BlockingPipelineRunner()
        }
        model.resumeProject(at: url)

        try await waitForViewState(model: model, state: .processing)

        XCTAssertEqual(model.currentRunOptions?.capturePath, .orbit)
        XCTAssertEqual(model.currentRunOptions?.detailProfile, .balanced)
        if case .photos(let folder) = model.currentInput {
            XCTAssertEqual(folder, "/tmp/photos")
        } else {
            XCTFail("Expected resumed photo-folder input while processing.")
        }

        model.cancelCurrentProject(deleteProject: false)
        try await waitForViewState(model: model, state: .home, timeout: 4.0)
    }

    func testResumedDurableRunAppearsActiveInProjectLibraryBeforeCompletion() async throws {
        let tempBase = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempBase) }
        try FileManager.default.createDirectory(at: tempBase, withIntermediateDirectories: true)
        let projectURL = try makeProject(
            at: tempBase,
            name: "Resume Active",
            lastError: nil,
            withOutput: false,
            stage: .sfmFeatures
        )

        let model = AppModel(toolchainManager: MockToolchainManager(), projectBaseURL: tempBase) { _, _ in
            BlockingPipelineRunner()
        }
        model.refreshProjectSummaries()
        model.resumeProject(at: projectURL)

        let deadline = Date().addingTimeInterval(2)
        var activeSummary: ProjectSummary?
        while Date() < deadline, activeSummary == nil {
            activeSummary = model.projectSummaries.first {
                ProjectSummary.hasSameLocation($0.url, projectURL) && $0.isActive
            }
            if activeSummary == nil {
                try await Task.sleep(nanoseconds: 25_000_000)
            }
        }

        XCTAssertEqual(activeSummary?.status, .inProgress)
        XCTAssertEqual(activeSummary?.title, "Resume Active")

        model.cancelCurrentProject(deleteProject: false)
        try await waitForViewState(model: model, state: .home, timeout: 4.0)
    }

    func testResumeUsesPersistedRunPlanForToolchainAndRunner() async throws {
        let tempBase = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempBase) }
        try FileManager.default.createDirectory(at: tempBase, withIntermediateDirectories: true)
        let url = try makeProject(
            at: tempBase,
            name: "ResumePlan",
            lastError: nil,
            withOutput: false,
            stage: .sfmFeatures
        )
        let paths = ProjectPaths(root: url)
        var metadata = try ProjectMetadataStore.load(from: paths.metadataURL)
        let options = RequestedRunOptions(detailProfile: .fast, resourcePolicy: .conserveMemory)
        let persistedPlan = RunPlanResolver.resolveForCurrentHardware(
            requestedOptions: options,
            input: metadata.input
        )
        metadata.requestedRunOptions = options
        metadata.resolvedRunPlan = persistedPlan
        try ProjectMetadataStore.save(metadata, to: paths.metadataURL)

        let toolchainManager = CapabilityRecordingToolchainManager()
        var runnerPlan: ResolvedRunPlan?
        let model = AppModel(toolchainManager: toolchainManager, projectBaseURL: tempBase) { projectURL, config in
            runnerPlan = config.resolvedRunPlan
            return MockPipelineRunner(projectURL: projectURL, config: config)
        }

        await model.resumeProjectTask(at: url)

        XCTAssertEqual(model.viewState, .viewer)
        XCTAssertEqual(runnerPlan, persistedPlan)
        XCTAssertEqual(
            toolchainManager.lastRequest,
            try persistedPlan.toolchainCapabilityRequest()
        )
    }

    func testResumeReplansForCurrentHardwareAndRestartsFramePreparation() async throws {
        let tempBase = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempBase) }
        try FileManager.default.createDirectory(at: tempBase, withIntermediateDirectories: true)
        let url = try makeProject(
            at: tempBase,
            name: "MovedMac",
            lastError: nil,
            withOutput: false,
            checkpoint: PipelineCheckpoint(
                stage: .trainSplat,
                updatedAt: Date(),
                progressFraction: 0.5,
                message: "Training",
                details: nil
            ),
            stage: .trainSplat,
            lastRunStartedAt: Date()
        )
        let paths = ProjectPaths(root: url)
        var metadata = try ProjectMetadataStore.load(from: paths.metadataURL)
        let options = RequestedRunOptions(detailProfile: .balanced)
        metadata.input = .video(files: ["/tmp/clip.mov"])
        metadata.requestedRunOptions = options
        metadata.resolvedRunPlan = RunPlanResolver.resolve(
            requestedOptions: options,
            input: metadata.input,
            hardware: HardwareProfile(memoryGB: 48, cpuCount: 16, gpuWorkingSetGB: 36),
            developmentOverrides: .none
        )
        try ProjectMetadataStore.save(metadata, to: paths.metadataURL)

        let toolchainManager = CapabilityRecordingToolchainManager()
        let runner = ResumeRecordingPipelineRunner(projectURL: url)
        var runnerPlan: ResolvedRunPlan?
        let model = AppModel(
            toolchainManager: toolchainManager,
            projectBaseURL: tempBase,
            hardwareProfile: HardwareProfile(memoryGB: 16, cpuCount: 10, gpuWorkingSetGB: 12)
        ) { _, config in
            runnerPlan = config.resolvedRunPlan
            return runner
        }

        await model.resumeProjectTask(at: url)

        let plan = try XCTUnwrap(runnerPlan)
        XCTAssertEqual(plan.memoryTier, "constrained")
        XCTAssertEqual(plan.modelIdentifier, "DA3-SMALL")
        XCTAssertEqual(plan.keyframeBudget, 160)
        XCTAssertEqual(runner.resumeFrom, .importInput)
        XCTAssertEqual(toolchainManager.lastRequest, try plan.toolchainCapabilityRequest())
    }

    func testUnsupportedResumePreservesCheckpointBeforeToolchainSetup() async throws {
        let tempBase = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempBase) }
        try FileManager.default.createDirectory(at: tempBase, withIntermediateDirectories: true)
        let checkpoint = PipelineCheckpoint(
            stage: .trainSplat,
            updatedAt: Date(timeIntervalSince1970: 500),
            progressFraction: 0.5,
            message: "Training",
            details: nil
        )
        let startedAt = Date(timeIntervalSince1970: 400)
        let url = try makeProject(
            at: tempBase,
            name: "HighDetailMovedMac",
            lastError: nil,
            withOutput: false,
            checkpoint: checkpoint,
            stage: .trainSplat,
            lastRunStartedAt: startedAt
        )
        let paths = ProjectPaths(root: url)
        var metadata = try ProjectMetadataStore.load(from: paths.metadataURL)
        let options = RequestedRunOptions(detailProfile: .highDetail)
        metadata.requestedRunOptions = options
        metadata.resolvedRunPlan = RunPlanResolver.resolve(
            requestedOptions: options,
            input: metadata.input,
            hardware: HardwareProfile(memoryGB: 48, cpuCount: 16, gpuWorkingSetGB: 36),
            developmentOverrides: .none
        )
        try ProjectMetadataStore.save(metadata, to: paths.metadataURL)

        let toolchainManager = CapabilityRecordingToolchainManager()
        let model = AppModel(
            toolchainManager: toolchainManager,
            projectBaseURL: tempBase,
            hardwareProfile: HardwareProfile(memoryGB: 16, cpuCount: 10, gpuWorkingSetGB: 12)
        ) { projectURL, config in
            MockPipelineRunner(projectURL: projectURL, config: config)
        }

        await model.resumeProjectTask(at: url)

        XCTAssertEqual(model.lastError, RunPlanResolver.ValidationError.highDetailRequiresMoreMemory.localizedDescription)
        XCTAssertEqual(model.validationRecovery, .useBalanced)
        XCTAssertNil(toolchainManager.lastRequest)
        let saved = try ProjectMetadataStore.load(from: paths.metadataURL)
        XCTAssertEqual(saved.checkpoint?.stage, checkpoint.stage)
        XCTAssertEqual(saved.checkpoint?.updatedAt, checkpoint.updatedAt)
        XCTAssertEqual(saved.checkpoint?.progressFraction, checkpoint.progressFraction)
        XCTAssertEqual(saved.checkpoint?.message, checkpoint.message)
        XCTAssertEqual(saved.lastRunStartedAt, startedAt)
        XCTAssertNil(saved.state.lastError)
    }

    func testValidationRecoveryUpdatesPersistedOptionsBeforeRetry() throws {
        let tempBase = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempBase) }
        try FileManager.default.createDirectory(at: tempBase, withIntermediateDirectories: true)
        let projectURL = try makeProject(
            at: tempBase,
            name: "RecoverOptions",
            lastError: nil,
            withOutput: false,
            stage: .trainSplat
        )
        let paths = ProjectPaths(root: projectURL)
        var metadata = try ProjectMetadataStore.load(from: paths.metadataURL)
        metadata.requestedRunOptions = RequestedRunOptions(detailProfile: .highDetail)
        try ProjectMetadataStore.save(metadata, to: paths.metadataURL)
        let model = AppModel(toolchainManager: MockToolchainManager(), projectBaseURL: tempBase)

        XCTAssertTrue(model.applyValidationRecovery(.useBalanced, projectURL: projectURL))

        let recovered = try ProjectMetadataStore.load(from: paths.metadataURL)
        XCTAssertEqual(recovered.requestedRunOptions.detailProfile, .balanced)
    }

    func testResumeToolchainFailurePreservesDurableProjectStateAndArtifacts() async throws {
        let tempBase = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempBase) }
        try FileManager.default.createDirectory(at: tempBase, withIntermediateDirectories: true)
        let checkpoint = PipelineCheckpoint(
            stage: .sfmMapping,
            updatedAt: Date(timeIntervalSince1970: 700),
            progressFraction: 1,
            message: "Geometry ready",
            details: nil
        )
        let projectURL = try makeProject(
            at: tempBase,
            name: "ToolchainResumeFailure",
            lastError: nil,
            withOutput: false,
            checkpoint: checkpoint,
            stage: .sfmMapping,
            lastRunStartedAt: Date(timeIntervalSince1970: 650)
        )
        let paths = ProjectPaths(root: projectURL)
        let geometrySentinel = paths.colmapSparseURL
            .appendingPathComponent("0", isDirectory: true)
            .appendingPathComponent("geometry.sentinel")
        let trainingSentinel = paths.trainingURL.appendingPathComponent("checkpoint.sentinel")
        try FileManager.default.createDirectory(
            at: geometrySentinel.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("geometry".utf8).write(to: geometrySentinel, options: [.atomic])
        try Data("training".utf8).write(to: trainingSentinel, options: [.atomic])
        let metadataBefore = try Data(contentsOf: paths.metadataURL)

        let model = AppModel(
            toolchainManager: FailingToolchainManager(message: "manifest unreachable"),
            projectBaseURL: tempBase
        ) { _, _ in
            XCTFail("Pipeline runner must not start when resume tool setup fails.")
            return BlockingPipelineRunner()
        }

        await model.resumeProjectTask(at: projectURL)

        XCTAssertEqual(
            model.lastError,
            "Couldn’t prepare the required tools. Check your connection and try again."
        )
        XCTAssertTrue(model.errorDetails?.contains("manifest unreachable") == true)
        XCTAssertEqual(
            model.statusDetail,
            "The saved project and its checkpoint are unchanged."
        )
        XCTAssertEqual(try Data(contentsOf: paths.metadataURL), metadataBefore)
        XCTAssertEqual(try Data(contentsOf: geometrySentinel), Data("geometry".utf8))
        XCTAssertEqual(try Data(contentsOf: trainingSentinel), Data("training".utf8))
    }

    func testCopyTechnicalDetailsPreviewsAndCopiesOnlySanitizedText() throws {
        let tempBase = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempBase) }
        try FileManager.default.createDirectory(at: tempBase, withIntermediateDirectories: true)
        let projectURL = try makeProject(
            at: tempBase,
            name: "Private Client",
            lastError: nil,
            withOutput: false
        )
        let model = AppModel(
            toolchainManager: MockToolchainManager(),
            projectBaseURL: tempBase
        ) { projectURL, config in
            MockPipelineRunner(projectURL: projectURL, config: config)
        }
        model.currentProjectURL = projectURL
        let raw = """
        \(NSHomeDirectory())/Documents/source.mov
        /Volumes/Client Drive/House/source.mov
        https://alice:secret@example.com/file
        Private Client
        """
        let pasteboard = NSPasteboard(name: .init("EasySplatTests.\(UUID().uuidString)"))
        var preview = ""

        model.copyTechnicalDetails(raw, pasteboard: pasteboard) { text in
            preview = text
            return true
        }

        XCTAssertEqual(pasteboard.string(forType: .string), preview)
        XCTAssertFalse(preview.contains(NSHomeDirectory()))
        XCTAssertFalse(preview.contains("Client Drive"))
        XCTAssertFalse(preview.contains("alice"))
        XCTAssertFalse(preview.contains("secret"))
        XCTAssertFalse(preview.contains("Private Client"))
        XCTAssertTrue(preview.contains("https://example.com/file"))
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
                requestedRunOptions: RequestedRunOptions(capturePath: .orbit, detailProfile: .balanced)
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
            requestedRunOptions: RequestedRunOptions(capturePath: .orbit, detailProfile: .balanced)
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
            requestedRunOptions: RequestedRunOptions(capturePath: .orbit, detailProfile: .balanced)
        )
        try ProjectMetadataStore.save(metadata, to: ProjectPaths(root: projectURL).metadataURL)

        let model = AppModel(toolchainManager: MockToolchainManager(), projectBaseURL: base) { url, config in
            MockPipelineRunner(projectURL: url, config: config)
        }

        XCTAssertFalse(model.renameProject(at: projectURL, to: ""))
        XCTAssertFalse(model.renameProject(at: projectURL, to: "   "))
        XCTAssertFalse(model.renameProject(at: projectURL, to: "Same"))
    }

    func testStartProjectUsesBalancedProfileByDefault() async throws {
        let tempBase = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempBase) }
        try FileManager.default.createDirectory(at: tempBase, withIntermediateDirectories: true)
        let input = tempBase.appendingPathComponent("input.mov")
        try Data("video".utf8).write(to: input)
        var capturedPlan: ResolvedRunPlan?

        let model = AppModel(
            toolchainManager: MockToolchainManager(),
            projectBaseURL: tempBase
        ) { projectURL, config in
            capturedPlan = config.resolvedRunPlan
            return MockPipelineRunner(projectURL: projectURL, config: config)
        }

        XCTAssertEqual(model.requestedRunOptions.detailProfile, .balanced)
        await model.startProject(input: .video(files: [input.path]), title: "BalancedDefault")

        XCTAssertEqual(capturedPlan?.trainerIterationLimit, 7_000)
        let projectURL = try XCTUnwrap(model.currentProjectURL)
        let metadata = try ProjectMetadataStore.load(from: ProjectPaths(root: projectURL).metadataURL)
        XCTAssertEqual(metadata.requestedRunOptions.detailProfile, .balanced)
    }

    func testStartProjectUsesFastResolvedPlanForExplicitFastDetail() async throws {
        let tempBase = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempBase) }
        try FileManager.default.createDirectory(at: tempBase, withIntermediateDirectories: true)
        let input = tempBase.appendingPathComponent("input.mov")
        try Data("video".utf8).write(to: input)
        var capturedPlan: ResolvedRunPlan?

        let model = AppModel(
            toolchainManager: MockToolchainManager(),
            projectBaseURL: tempBase
        ) { projectURL, config in
            capturedPlan = config.resolvedRunPlan
            return MockPipelineRunner(projectURL: projectURL, config: config)
        }

        model.requestedRunOptions.detailProfile = .fast
        await model.startProject(input: .video(files: [input.path]), title: "Fast")

        XCTAssertEqual(capturedPlan?.trainerIterationLimit, 3_000)
        XCTAssertEqual(capturedPlan?.modelIdentifier, "DA3-SMALL")
        let projectURL = try XCTUnwrap(model.currentProjectURL)
        let metadata = try ProjectMetadataStore.load(from: ProjectPaths(root: projectURL).metadataURL)
        XCTAssertEqual(metadata.requestedRunOptions.detailProfile, .fast)
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

    func testStartProjectToolchainFailureCreatesNoDurableProject() async throws {
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

        XCTAssertEqual(
            model.lastError,
            "Couldn’t prepare the required tools. Check your connection and try again."
        )
        XCTAssertTrue(model.errorDetails?.contains("manifest unreachable") == true)
        XCTAssertNil(model.currentProjectURL)
        XCTAssertNil(model.currentRunOptions)
        XCTAssertNil(model.currentInput)
        XCTAssertEqual(model.pendingVideoURLs, [input])
        XCTAssertNil(model.pendingPhotosFolderURL)
        XCTAssertTrue(model.projectSummaries.isEmpty)
        let projectBundles = try FileManager.default.contentsOfDirectory(
            at: tempBase,
            includingPropertiesForKeys: nil
        ).filter { $0.pathExtension == "easysplatproj" }
        XCTAssertTrue(projectBundles.isEmpty)
    }

    func testContinuousMultipleClipsFailsBeforeToolchainOrProjectCreation() async throws {
        let tempBase = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempBase) }
        try FileManager.default.createDirectory(at: tempBase, withIntermediateDirectories: true)
        let first = tempBase.appendingPathComponent("first.mov")
        let second = tempBase.appendingPathComponent("second.mov")
        try Data("first".utf8).write(to: first)
        try Data("second".utf8).write(to: second)
        let toolchain = CapabilityRecordingToolchainManager()
        let model = AppModel(toolchainManager: toolchain, projectBaseURL: tempBase) { _, _ in
            XCTFail("Pipeline runner should not start for an unverified continuous multi-clip input.")
            return BlockingPipelineRunner()
        }
        model.addInputs(urls: [first, second])
        model.requestedRunOptions.inputOrdering = .continuous

        model.startFromPendingSelection()
        try await waitForLastError(model: model, timeout: 4.0)

        XCTAssertEqual(
            model.lastError,
            "Continuous sequence currently supports one video clip. Use Automatic or Unordered for separate clips."
        )
        XCTAssertNil(toolchain.lastRequest)
        XCTAssertNil(model.currentProjectURL)
        let projectBundles = try FileManager.default.contentsOfDirectory(
            at: tempBase,
            includingPropertiesForKeys: nil
        ).filter { $0.pathExtension == "easysplatproj" }
        XCTAssertTrue(projectBundles.isEmpty)
    }

    func testTrainingStopCopyPromisesValidationNotAutomaticResume() {
        let tempBase = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let model = AppModel(toolchainManager: MockToolchainManager(), projectBaseURL: tempBase) { _, config in
            MockPipelineRunner(projectURL: tempBase, config: config)
        }
        model.currentProjectURL = tempBase.appendingPathComponent("Training.easysplatproj", isDirectory: true)
        model.currentTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
        }
        defer {
            model.currentTask?.cancel()
            model.currentTask = nil
        }

        model.handle(event: .stageStarted(stage: .trainSplat))
        model.cancelCurrentProject(deleteProject: false)

        XCTAssertEqual(model.statusTitle, "Saving training checkpoint…")
        XCTAssertEqual(
            model.statusDetail,
            "Saving and validating the latest training checkpoint. Recent iterations may repeat on resume."
        )
    }

    func testNonTrainingStopMakesNoHardTimingPromise() {
        let tempBase = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let model = AppModel(toolchainManager: MockToolchainManager(), projectBaseURL: tempBase) { _, config in
            MockPipelineRunner(projectURL: tempBase, config: config)
        }
        model.currentProjectURL = tempBase.appendingPathComponent("Reconstruction.easysplatproj", isDirectory: true)
        model.currentTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
        }
        defer {
            model.currentTask?.cancel()
            model.currentTask = nil
        }

        model.handle(event: .stageStarted(stage: .sfmMapping))
        model.cancelCurrentProject(deleteProject: false)

        XCTAssertEqual(model.statusTitle, "Saving progress…")
        XCTAssertEqual(
            model.statusDetail,
            "Keeping completed work and stopping at a safe point…"
        )
    }

    func testMsplatCheckpointPersistenceFailureDoesNotSilentlyCompleteStop() async throws {
        let tempBase = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempBase, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempBase) }
        let input = tempBase.appendingPathComponent("input.mov")
        try Data("video".utf8).write(to: input)
        let started = expectation(description: "training started")
        let model = AppModel(
            toolchainManager: MockToolchainManager(),
            projectBaseURL: tempBase
        ) { _, _ in
            StopFailingPipelineRunner(started: started, stage: .trainSplat)
        }
        var terminationReplies: [Bool] = []
        model.replyToTerminationRequest = { shouldTerminate in
            terminationReplies.append(shouldTerminate)
        }
        model.addInputs(urls: [input])
        model.startFromPendingSelection()
        await fulfillment(of: [started], timeout: 2.0)
        try await waitForPipelineState(model: model, stage: .trainSplat)

        model.cancelCurrentProject(deleteProject: false, exitIntent: .quit)
        try await waitForLastError(model: model, timeout: 2.0)

        XCTAssertEqual(model.viewState, .processing)
        XCTAssertEqual(model.statusTitle, "Couldn’t save the project")
        XCTAssertEqual(
            model.statusDetail,
            "The training checkpoint was not saved. Review the details and try again."
        )
        XCTAssertFalse(model.isStopping)
        XCTAssertEqual(model.exitIntent, .none)
        XCTAssertNil(model.pendingCloseWindow)
        XCTAssertEqual(terminationReplies, [false])
        XCTAssertNotNil(model.currentProjectURL)
        XCTAssertEqual(
            model.lastError,
            "The training checkpoint was not saved. Review the details and try again."
        )
        XCTAssertTrue(model.errorDetails?.contains("checkpoint persistence failed") == true)
    }

    func testStopFailurePresentationCoversCheckpointGenericAndDeleteFailures() {
        let tempBase = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let model = AppModel(toolchainManager: MockToolchainManager(), projectBaseURL: tempBase) { _, config in
            MockPipelineRunner(projectURL: tempBase, config: config)
        }
        model.currentProjectURL = tempBase.appendingPathComponent("FailureCopy.easysplatproj", isDirectory: true)

        model.stage = .trainSplat
        XCTAssertEqual(
            model.stopFailurePresentation(for: .keepProject),
            AppModel.StopFailurePresentation(
                title: "Couldn’t save the project",
                detail: "The training checkpoint was not saved. Review the details and try again."
            )
        )

        model.stage = .sfmMapping
        XCTAssertEqual(
            model.stopFailurePresentation(for: .keepProject),
            AppModel.StopFailurePresentation(
                title: "Couldn’t save the project",
                detail: "The project was not saved. Review the details and try again."
            )
        )
        XCTAssertEqual(
            model.stopFailurePresentation(for: .deleteProject),
            AppModel.StopFailurePresentation(
                title: "Couldn’t move project to Trash",
                detail: "The project stayed in place because EasySplat could not stop safely. Review the details and try again."
            )
        )
    }

    func testResumedMsplatCheckpointFailureUsesCheckpointFailureCopy() async throws {
        let tempBase = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempBase, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempBase) }
        let projectURL = try makeProject(
            at: tempBase,
            name: "ResumeCheckpointFailure",
            lastError: nil,
            withOutput: false,
            stage: .trainSplat
        )
        let started = expectation(description: "resumed training started")
        let model = AppModel(
            toolchainManager: MockToolchainManager(),
            projectBaseURL: tempBase
        ) { _, _ in
            StopFailingPipelineRunner(started: started, stage: .trainSplat)
        }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 120, height: 80),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false

        model.resumeProject(at: projectURL)
        await fulfillment(of: [started], timeout: 2.0)
        try await waitForPipelineState(model: model, stage: .trainSplat)

        model.cancelCurrentProject(
            deleteProject: false,
            exitIntent: .closeWindow,
            window: window
        )
        try await waitForLastError(model: model, timeout: 2.0)

        XCTAssertEqual(model.viewState, .processing)
        XCTAssertEqual(model.statusTitle, "Couldn’t save the project")
        XCTAssertEqual(
            model.statusDetail,
            "The training checkpoint was not saved. Review the details and try again."
        )
        XCTAssertFalse(model.isStopping)
        XCTAssertEqual(model.exitIntent, .none)
        XCTAssertNil(model.pendingCloseWindow)
        XCTAssertFalse(model.allowNextWindowClose)
        XCTAssertEqual(model.currentProjectURL, projectURL)
        XCTAssertEqual(
            model.lastError,
            "The training checkpoint was not saved. Review the details and try again."
        )
        XCTAssertTrue(model.errorDetails?.contains("checkpoint persistence failed") == true)
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

        let options = RequestedRunOptions(detailProfile: .highDetail)
        var metadata = ProjectMetadata(
            title: "Project",
            input: .photos(folder: "/tmp/photos"),
            requestedRunOptions: options,
            state: PipelineState(stage: .done, lastError: nil),
            outputs: OutputSpec(splatPlyPath: "Output/splat.ply", colmapModelPath: "SfM/colmap/sparse/0")
        )
        metadata.resolvedRunPlan = RunPlanResolver.resolve(
            requestedOptions: options,
            input: metadata.input,
            hardware: HardwareProfile(memoryGB: 48, cpuCount: 16, gpuWorkingSetGB: 36),
            developmentOverrides: .none
        )
        try ProjectMetadataStore.save(metadata, to: paths.metadataURL)

        let toolchainManager = CapabilityRecordingToolchainManager()
        let model = AppModel(
            toolchainManager: toolchainManager,
            projectBaseURL: tempBase,
            hardwareProfile: HardwareProfile(memoryGB: 16, cpuCount: 10, gpuWorkingSetGB: 12)
        ) { _, config in
            MockPipelineRunner(projectURL: projectURL, config: config)
        }

        model.resumeProject(at: projectURL)
        try await waitForViewState(model: model, state: .viewer)
        XCTAssertEqual(model.viewState, .viewer)
        XCTAssertEqual(model.outputPlyURL, output)
        XCTAssertNil(toolchainManager.lastRequest)
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
            requestedRunOptions: RequestedRunOptions(capturePath: .orbit, detailProfile: .balanced),
            state: PipelineState(stage: .done, lastError: nil),
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
            requestedRunOptions: RequestedRunOptions(capturePath: .orbit, detailProfile: .balanced),
            state: PipelineState(stage: .done, lastError: nil),
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

    func testStartAndResumeRequestsAreIgnoredWhileRunIsActive() async throws {
        let tempBase = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempBase) }
        try FileManager.default.createDirectory(at: tempBase, withIntermediateDirectories: true)
        let firstURL = try makeProject(at: tempBase, name: "First", lastError: nil, withOutput: false)
        let secondURL = try makeProject(at: tempBase, name: "Second", lastError: nil, withOutput: false)
        var callCount = 0
        let model = AppModel(toolchainManager: MockToolchainManager(), projectBaseURL: tempBase) { _, _ in
            callCount += 1
            return BlockingPipelineRunner()
        }

        model.resumeProject(at: firstURL)
        try await waitForViewState(model: model, state: .processing)
        try await waitForCurrentProjectURL(model: model, url: firstURL)
        let input = tempBase.appendingPathComponent("other.mov")
        try Data("video".utf8).write(to: input)
        model.addInputs(urls: [input])

        model.resumeProject(at: secondURL)
        model.startFromPendingSelection()
        try await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertTrue(model.isRunActive)
        XCTAssertNotNil(model.currentTask)
        XCTAssertEqual(model.currentProjectURL, firstURL)
        XCTAssertEqual(callCount, 1)

        model.cancelCurrentProject(deleteProject: false)
        try await waitForViewState(model: model, state: .home, timeout: 4.0)
        XCTAssertFalse(model.isRunActive)
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

    func testLoadPipelineLogTailKeepsNativeTrainerMessages() throws {
        let tempBase = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempBase) }
        let projectURL = tempBase.appendingPathComponent("Project.easysplatproj", isDirectory: true)
        let paths = ProjectPaths(root: projectURL)
        try paths.ensureDirectories()
        let message = "[training model] completed loading native checkpoint"
        try (message + "\n").write(to: paths.pipelineLogURL, atomically: true, encoding: .utf8)
        let model = AppModel(toolchainManager: MockToolchainManager(), projectBaseURL: tempBase) { _, config in
            MockPipelineRunner(projectURL: projectURL, config: config)
        }

        XCTAssertEqual(model.test_loadPipelineLogTail(projectURL: projectURL), [message])
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

    func testLoadPipelineLogTailRejectsSymlinkWithoutReadingExternalContents() throws {
        let tempBase = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempBase) }
        let projectURL = tempBase.appendingPathComponent("Project.easysplatproj", isDirectory: true)
        let paths = ProjectPaths(root: projectURL)
        try paths.ensureDirectories()
        let marker = "external-app-symlink-log-secret"
        let outsideLog = tempBase.appendingPathComponent("outside.log")
        try marker.write(to: outsideLog, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(at: paths.pipelineLogURL, withDestinationURL: outsideLog)
        let model = AppModel(toolchainManager: MockToolchainManager(), projectBaseURL: tempBase) { _, config in
            MockPipelineRunner(projectURL: projectURL, config: config)
        }

        let lines = model.test_loadPipelineLogTail(projectURL: projectURL)

        XCTAssertTrue(lines.isEmpty)
        XCTAssertFalse(lines.joined(separator: "\n").contains(marker))
        XCTAssertEqual(try String(contentsOf: outsideLog, encoding: .utf8), marker)
    }

    func testLoadPipelineLogTailRejectsSymlinkedLogsDirectory() throws {
        let tempBase = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempBase) }
        let projectURL = tempBase.appendingPathComponent("Project.easysplatproj", isDirectory: true)
        let paths = ProjectPaths(root: projectURL)
        try paths.ensureDirectories()
        try FileManager.default.removeItem(at: paths.logsURL)
        let outsideLogs = tempBase.appendingPathComponent("OutsideLogs", isDirectory: true)
        try FileManager.default.createDirectory(at: outsideLogs, withIntermediateDirectories: true)
        let marker = "external-app-parent-symlink-log-secret"
        try marker.write(
            to: outsideLogs.appendingPathComponent("pipeline.log"),
            atomically: true,
            encoding: .utf8
        )
        try FileManager.default.createSymbolicLink(
            at: paths.logsURL,
            withDestinationURL: outsideLogs
        )
        let model = AppModel(toolchainManager: MockToolchainManager(), projectBaseURL: tempBase) { _, config in
            MockPipelineRunner(projectURL: projectURL, config: config)
        }

        let lines = model.test_loadPipelineLogTail(projectURL: projectURL)

        XCTAssertTrue(lines.isEmpty)
        XCTAssertFalse(lines.joined(separator: "\n").contains(marker))
    }

    func testLoadPipelineLogTailRejectsMultiplyLinkedFileWithoutReadingExternalContents() throws {
        let tempBase = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempBase) }
        let projectURL = tempBase.appendingPathComponent("Project.easysplatproj", isDirectory: true)
        let paths = ProjectPaths(root: projectURL)
        try paths.ensureDirectories()
        let marker = "external-app-hardlink-log-secret"
        let outsideLog = tempBase.appendingPathComponent("outside.log")
        try marker.write(to: outsideLog, atomically: true, encoding: .utf8)
        try FileManager.default.linkItem(at: outsideLog, to: paths.pipelineLogURL)
        let model = AppModel(toolchainManager: MockToolchainManager(), projectBaseURL: tempBase) { _, config in
            MockPipelineRunner(projectURL: projectURL, config: config)
        }

        let lines = model.test_loadPipelineLogTail(projectURL: projectURL)

        XCTAssertTrue(lines.isEmpty)
        XCTAssertFalse(lines.joined(separator: "\n").contains(marker))
        XCTAssertEqual(try String(contentsOf: outsideLog, encoding: .utf8), marker)
    }

    func testLoadPipelineLogTailRejectsFIFO() throws {
        let tempBase = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempBase) }
        let projectURL = tempBase.appendingPathComponent("Project.easysplatproj", isDirectory: true)
        let paths = ProjectPaths(root: projectURL)
        try paths.ensureDirectories()
        XCTAssertEqual(Darwin.mkfifo(paths.pipelineLogURL.path, mode_t(S_IRUSR | S_IWUSR)), 0)
        let model = AppModel(toolchainManager: MockToolchainManager(), projectBaseURL: tempBase) { _, config in
            MockPipelineRunner(projectURL: projectURL, config: config)
        }

        let lines = model.test_loadPipelineLogTail(projectURL: projectURL)

        XCTAssertTrue(lines.isEmpty)
    }

    func testRefreshProjectSummariesStatusMapping() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)

        let readyURL = try makeProject(at: base, name: "Ready", lastError: nil, withOutput: true)
        _ = readyURL
        let failedURL = try makeProject(at: base, name: "Failed", lastError: "boom", withOutput: false)
        _ = failedURL
        let inProgressURL = try makeProject(
            at: base,
            name: "Progress",
            lastError: nil,
            withOutput: false,
            stage: .sfmMapping
        )
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

    func testRefreshProjectSummariesPreservesRunStartAndFailureActivity() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let projectURL = base.appendingPathComponent("RecentFailure.easysplatproj", isDirectory: true)
        let paths = ProjectPaths(root: projectURL)
        try paths.ensureDirectories()
        let startedAt = Date(timeIntervalSince1970: 300)
        let failedAt = Date(timeIntervalSince1970: 400)
        try ProjectMetadataStore.save(
            ProjectMetadata(
                createdAt: Date(timeIntervalSince1970: 100),
                title: "Recent Failure",
                input: .photos(folder: "/tmp/photos"),
                state: PipelineState(stage: .sfmMapping, lastError: "boom"),
                lastRunStartedAt: startedAt,
                lastFailureAt: failedAt
            ),
            to: paths.metadataURL
        )
        let model = AppModel(toolchainManager: MockToolchainManager(), projectBaseURL: base)

        model.refreshProjectSummaries()

        let summary = try XCTUnwrap(model.projectSummaries.first)
        XCTAssertEqual(summary.lastRunStartedAt, startedAt)
        XCTAssertEqual(summary.lastFailureAt, failedAt)
        XCTAssertEqual(summary.lastActivityAt, failedAt)
    }

    func testRefreshProjectSummariesAndProjectActionsRejectSymlinkedBundle() throws {
        let parent = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: parent) }
        let base = parent.appendingPathComponent("Projects", isDirectory: true)
        let outsideProject = parent.appendingPathComponent("Outside.easysplatproj", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outsideProject, withIntermediateDirectories: true)
        let outsidePaths = ProjectPaths(root: outsideProject)
        try ProjectMetadataStore.save(
            ProjectMetadata(
                title: "Outside",
                input: .photos(folder: "/tmp/photos"),
                requestedRunOptions: RequestedRunOptions(capturePath: .orbit, detailProfile: .balanced)
            ),
            to: outsidePaths.metadataURL
        )
        let originalMetadataBytes = try Data(contentsOf: outsidePaths.metadataURL)
        let linkedProject = base.appendingPathComponent("Linked.easysplatproj", isDirectory: true)
        try FileManager.default.createSymbolicLink(
            at: linkedProject,
            withDestinationURL: outsideProject
        )

        let model = AppModel(toolchainManager: MockToolchainManager(), projectBaseURL: base) { _, config in
            MockPipelineRunner(projectURL: linkedProject, config: config)
        }
        model.refreshProjectSummaries()
        XCTAssertTrue(model.projectSummaries.isEmpty)
        XCTAssertFalse(model.updateProjectNotes(at: linkedProject, to: "must stay local"))
        XCTAssertFalse(model.renameProject(at: linkedProject, to: "Must stay local"))
        model.markProjectOpened(at: linkedProject)

        XCTAssertEqual(try Data(contentsOf: outsidePaths.metadataURL), originalMetadataBytes)
        XCTAssertFalse(FileManager.default.fileExists(atPath: outsidePaths.lastOpenedSidecarURL.path))
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
          "requestedRunOptions":{"capturePath":"automatic","detailProfile":"balanced"},
          "state":{"lastError":null,"stage":"importInput"},
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
            requestedRunOptions: RequestedRunOptions(capturePath: .orbit, detailProfile: .balanced),
            state: PipelineState(stage: .done, lastError: nil),
            outputs: OutputSpec(splatPlyPath: "Output/splat.ply", colmapModelPath: "SfM/colmap/sparse/0")
        )
        try ProjectMetadataStore.save(metadata, to: paths.metadataURL)

        let model = AppModel(toolchainManager: MockToolchainManager(), projectBaseURL: base) { _, config in
            MockPipelineRunner(projectURL: base, config: config)
        }
        model.refreshProjectSummaries()

        XCTAssertEqual(model.projectSummaries.first?.status, .failed)
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
            requestedRunOptions: RequestedRunOptions(capturePath: .orbit, detailProfile: .balanced),
            state: PipelineState(stage: .done, lastError: nil),
            outputs: OutputSpec(splatPlyPath: "Output/splat.ply", colmapModelPath: "SfM/colmap/sparse/0")
        )
        try ProjectMetadataStore.save(metadata, to: paths.metadataURL)

        let model = AppModel(toolchainManager: MockToolchainManager(), projectBaseURL: base) { _, config in
            MockPipelineRunner(projectURL: base, config: config)
        }
        model.refreshProjectSummaries()

        XCTAssertEqual(model.projectSummaries.first?.status, .failed)
        XCTAssertNil(model.readyOutputURL(projectURL: projectURL, validationDepth: .quick))
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
            requestedRunOptions: RequestedRunOptions(capturePath: .orbit, detailProfile: .balanced),
            state: PipelineState(stage: .done, lastError: nil),
            outputs: OutputSpec(splatPlyPath: "Output/splat.ply", colmapModelPath: "SfM/colmap/sparse/0")
        )
        try ProjectMetadataStore.save(metadata, to: paths.metadataURL)

        let model = AppModel(toolchainManager: MockToolchainManager(), projectBaseURL: base) { _, config in
            MockPipelineRunner(projectURL: base, config: config)
        }
        model.refreshProjectSummaries()

        XCTAssertEqual(model.projectSummaries.first?.status, .ready)
        XCTAssertEqual(
            model.readyOutputURL(projectURL: projectURL, validationDepth: .quick)?.lastPathComponent,
            "splat.ply"
        )
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
            requestedRunOptions: RequestedRunOptions(capturePath: .orbit, detailProfile: .balanced),
            state: PipelineState(stage: .done, lastError: nil),
            outputs: OutputSpec(splatPlyPath: "../outside.ply", colmapModelPath: "SfM/colmap/sparse/0")
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(metadata).write(to: paths.metadataURL, options: .atomic)
        XCTAssertThrowsError(try ProjectMetadataStore.load(from: paths.metadataURL)) { error in
            guard case ProjectMetadataStore.LoadError.invalidArtifactPath(
                field: "outputs.splatPlyPath",
                path: "../outside.ply"
            ) = error else {
                return XCTFail("Expected invalid output path, got \(error)")
            }
        }

        let model = AppModel(toolchainManager: MockToolchainManager(), projectBaseURL: base) { _, config in
            MockPipelineRunner(projectURL: base, config: config)
        }
        model.refreshProjectSummaries()

        XCTAssertTrue(model.projectSummaries.isEmpty)
        XCTAssertNil(model.readyOutputURL(projectURL: projectURL, validationDepth: .quick))
    }

    func testStoppingKeptProjectRemainsUnfinishedAcrossRelaunch() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let projectURL = try makeProject(
            at: base,
            name: "InterruptedReturn",
            lastError: nil,
            withOutput: false,
            checkpoint: PipelineCheckpoint(
                stage: .trainSplat,
                updatedAt: Date(),
                progressFraction: 0.5,
                message: "heartbeat",
                details: nil
            ),
            stage: .trainSplat
        )

        let model = AppModel(toolchainManager: MockToolchainManager(), projectBaseURL: base) { _, _ in
            BlockingPipelineRunner()
        }

        model.resumeProject(at: projectURL)
        try await waitForViewState(model: model, state: .processing)

        model.cancelCurrentProject(deleteProject: false)
        try await waitForViewState(model: model, state: .home, timeout: 4.0)
        model.refreshProjectSummaries()

        XCTAssertTrue(FileManager.default.fileExists(atPath: projectURL.path))

        let relaunched = AppModel(toolchainManager: MockToolchainManager(), projectBaseURL: base) { _, config in
            MockPipelineRunner(projectURL: projectURL, config: config)
        }
        relaunched.refreshProjectSummaries()
        let stoppedSummary = relaunched.projectSummaries.first { $0.title == "InterruptedReturn" }
        XCTAssertNotNil(stoppedSummary, "Stopped project should remain listed.")
        XCTAssertEqual(stoppedSummary?.status, .inProgress)
        XCTAssertEqual(stoppedSummary?.isInterrupted, true)
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

    func testFailedProcessingScreenDoesNotBlockApplicationTermination() {
        let model = AppModel(toolchainManager: MockToolchainManager())
        model.viewState = .processing
        model.lastError = "Capture needs more overlap."
        let delegate = AppDelegate()
        delegate.model = model

        XCTAssertEqual(delegate.applicationShouldTerminate(NSApplication.shared), .terminateNow)
    }

    func testFailedProcessingScreenDoesNotBlockWindowClose() {
        let model = AppModel(toolchainManager: MockToolchainManager())
        model.viewState = .processing
        model.lastError = "Capture needs more overlap."
        let coordinator = WindowAccessor.Coordinator(model: model)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 920, height: 640),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )

        XCTAssertTrue(coordinator.windowShouldClose(window))
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

    func testAppConfigEnablesInsecureLoopbackOnlyForDebugManifest() async {
        await withAppEnvironmentAsync([
            "EASYSPLAT_TOOLCHAIN_MANIFEST_URL": "http://127.0.0.1:8000/manifest.json",
        ]) {
            XCTAssertTrue(AppConfig.allowInsecureLoopbackToolchainHTTP)
        }

        await withAppEnvironmentAsync([
            "EASYSPLAT_TOOLCHAIN_MANIFEST_URL": "http://downloads.example.com/manifest.json",
        ]) {
            XCTAssertFalse(AppConfig.allowInsecureLoopbackToolchainHTTP)
        }

        await withAppEnvironmentAsync([
            "EASYSPLAT_TOOLCHAIN_MANIFEST_URL": "https://downloads.example.com/manifest.json",
        ]) {
            XCTAssertFalse(AppConfig.allowInsecureLoopbackToolchainHTTP)
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

    func testShareUsesOnlyValidatedCurrentProjectPlyAndWritesNoAppEvents() async throws {
        let tempBase = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempBase) }
        try FileManager.default.createDirectory(at: tempBase, withIntermediateDirectories: true)
        let input = tempBase.appendingPathComponent("input.mov")
        try Data("video".utf8).write(to: input)

        let model = AppModel(toolchainManager: MockToolchainManager(), projectBaseURL: tempBase) { projectURL, config in
            MockPipelineRunner(projectURL: projectURL, config: config)
        }

        model.addInputs(urls: [input])
        model.startFromPendingSelection()
        try await waitForViewState(model: model, state: .viewer)

        let projectURL = try XCTUnwrap(model.currentProjectURL)
        let outputURL = try XCTUnwrap(model.outputPlyURL)
        let validatedItems = try await model.test_validatedShareItems()
        let items = try XCTUnwrap(validatedItems)
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(try XCTUnwrap(items.first as? URL).standardizedFileURL, outputURL.standardizedFileURL)

        await model.shareCurrentSplat()

        let appEventsURL = projectURL.appendingPathComponent("Logs/app_events.jsonl")
        XCTAssertFalse(FileManager.default.fileExists(atPath: appEventsURL.path))
    }

    func testShareCurrentSplatReportsMissingOutputFile() async throws {
        let tempBase = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempBase) }
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

        await model.shareCurrentSplat()

        XCTAssertTrue(model.shareStatusIsError)
        XCTAssertTrue((model.shareStatusMessage ?? "").contains("Could not find"))
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: projectURL.appendingPathComponent("Logs/app_events.jsonl").path
            )
        )
    }

    func testShareCurrentSplatReportsInvalidOutputDirectoryPath() async throws {
        let tempBase = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempBase) }
        try FileManager.default.createDirectory(at: tempBase, withIntermediateDirectories: true)
        let input = tempBase.appendingPathComponent("input.mov")
        try Data("video".utf8).write(to: input)

        let model = AppModel(toolchainManager: MockToolchainManager(), projectBaseURL: tempBase) { projectURL, config in
            MockPipelineRunner(projectURL: projectURL, config: config)
        }

        model.addInputs(urls: [input])
        model.startFromPendingSelection()
        try await waitForViewState(model: model, state: .viewer)

        guard let output = model.outputPlyURL else {
            XCTFail("Missing project state")
            return
        }
        try FileManager.default.removeItem(at: output)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

        await model.shareCurrentSplat()

        XCTAssertTrue(model.shareStatusIsError)
    }

    func testShareCurrentSplatRejectsFallbackOutputFromDifferentProject() async throws {
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

        await model.shareCurrentSplat()

        XCTAssertTrue(model.shareStatusIsError)
        let fallbackItems = try await model.test_validatedShareItems()
        XCTAssertNil(fallbackItems)
    }

    func testShareCurrentSplatIgnoredWhileSessionAlreadyActive() async throws {
        let tempBase = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempBase) }
        try FileManager.default.createDirectory(at: tempBase, withIntermediateDirectories: true)
        let input = tempBase.appendingPathComponent("input.mov")
        try Data("video".utf8).write(to: input)

        let model = AppModel(toolchainManager: MockToolchainManager(), projectBaseURL: tempBase) { projectURL, config in
            MockPipelineRunner(projectURL: projectURL, config: config)
        }

        model.addInputs(urls: [input])
        model.startFromPendingSelection()
        try await waitForViewState(model: model, state: .viewer)

        model.test_activateShareSession()

        await model.shareCurrentSplat()

        XCTAssertEqual(model.shareStatusMessage, "Share is already open.")
        XCTAssertFalse(model.shareStatusIsError)
        XCTAssertTrue(model.isShareSheetActive)
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

    private func waitForPipelineState(
        model: AppModel,
        stage: PipelineStage,
        timeout: TimeInterval = 2.0
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if model.stage == stage {
                return
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTFail("Timed out waiting for stage \(stage)")
    }

    private func makeProject(
        at base: URL,
        name: String,
        lastError: String?,
        withOutput: Bool,
        checkpoint: PipelineCheckpoint? = nil,
        stage: PipelineStage = .done,
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
            requestedRunOptions: RequestedRunOptions(capturePath: .orbit, detailProfile: .balanced),
            state: PipelineState(stage: stage, lastError: lastError),
            outputs: withOutput ? OutputSpec(splatPlyPath: "Output/splat.ply", colmapModelPath: "SfM/colmap/sparse/0") : nil,
            checkpoint: checkpoint,
            lastRunStartedAt: lastRunStartedAt
        )
        try ProjectMetadataStore.save(metadata, to: paths.metadataURL)
        return url
    }
}

private func writeTestGrayscaleImage(at url: URL, value: UInt8) throws -> Bool {
    let width = 2
    let height = 2
    var pixels = [UInt8](repeating: value, count: width * height)
    let data = Data(bytes: &pixels, count: pixels.count)
    guard let provider = CGDataProvider(data: data as CFData),
          let image = CGImage(
              width: width,
              height: height,
              bitsPerComponent: 8,
              bitsPerPixel: 8,
              bytesPerRow: width,
              space: CGColorSpaceCreateDeviceGray(),
              bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
              provider: provider,
              decode: nil,
              shouldInterpolate: false,
              intent: .defaultIntent
          ),
          let destination = CGImageDestinationCreateWithURL(
              url as CFURL,
              UTType.png.identifier as CFString,
              1,
              nil
          ) else {
        return false
    }
    CGImageDestinationAddImage(destination, image, nil)
    return CGImageDestinationFinalize(destination)
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

private func makeMockToolchainPaths() -> ToolchainPaths {
    let da3Root = URL(fileURLWithPath: "/mock/da3")
    return ToolchainPaths(
        root: URL(fileURLWithPath: "/tmp/toolchain"),
        colmap: URL(fileURLWithPath: "/mock/colmap"),
        msplat: URL(fileURLWithPath: "/mock/easysplat-train"),
        da3: Da3Toolchain(
            root: da3Root,
            sfmTool: da3Root.appendingPathComponent("bin/easysplat_da3_sfm"),
            python: da3Root.appendingPathComponent("python/bin/python3"),
            models: da3Root.appendingPathComponent("models"),
            modelBundle: da3Root.appendingPathComponent("models/da3-base.safetensors"),
            fallbackModelBundle: da3Root.appendingPathComponent("models/da3-small.safetensors")
        )
    )
}

final class MockToolchainManager: ToolchainManaging {
    func ensureToolchain(
        manifestURL: URL,
        publicKeyBase64: String,
        request: ToolchainCapabilityRequest,
        onProgress: @escaping @Sendable (Double, String) -> Void
    ) async throws -> ToolchainPaths {
        makeMockToolchainPaths()
    }
}

final class CapabilityRecordingToolchainManager: @unchecked Sendable, ToolchainManaging {
    private let queue = DispatchQueue(label: "CapabilityRecordingToolchainManager")
    private var requests: [ToolchainCapabilityRequest] = []

    var lastRequest: ToolchainCapabilityRequest? {
        queue.sync { requests.last }
    }

    func ensureToolchain(
        manifestURL: URL,
        publicKeyBase64: String,
        request: ToolchainCapabilityRequest,
        onProgress: @escaping @Sendable (Double, String) -> Void
    ) async throws -> ToolchainPaths {
        queue.sync { requests.append(request) }
        return makeMockToolchainPaths()
    }
}

struct FailingToolchainManager: ToolchainManaging {
    var message: String

    func ensureToolchain(
        manifestURL: URL,
        publicKeyBase64: String,
        request: ToolchainCapabilityRequest,
        onProgress: @escaping @Sendable (Double, String) -> Void
    ) async throws -> ToolchainPaths {
        throw NSError(domain: "FailingToolchainManager", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}

final class BlockingPipelineRunner: PipelineRunning {
    func run(resumeFrom lastCompletedStage: PipelineStage?, events: @escaping @Sendable (PipelineEvent) -> Void) async throws {
        events(.stageStarted(stage: .trainSplat))
        while true {
            try Task.checkCancellation()
            try await Task.sleep(nanoseconds: 50_000_000)
        }
    }
}

final class StopFailingPipelineRunner: PipelineRunning {
    private let started: XCTestExpectation
    private let stage: PipelineStage

    init(started: XCTestExpectation, stage: PipelineStage) {
        self.started = started
        self.stage = stage
    }

    func run(
        resumeFrom lastCompletedStage: PipelineStage?,
        events: @escaping @Sendable (PipelineEvent) -> Void
    ) async throws {
        events(.stageStarted(stage: stage))
        started.fulfill()
        do {
            try await Task.sleep(nanoseconds: 60_000_000_000)
        } catch {
            throw NSError(
                domain: "CheckpointSaveFailingPipelineRunner",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "checkpoint persistence failed"]
            )
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
        try writeMinimalPly(at: outputURL)
        metadata.outputs = OutputSpec(splatPlyPath: "Output/splat.ply", colmapModelPath: "SfM/colmap/sparse/0")
        metadata.state = PipelineState(stage: .done, lastError: nil)
        try ProjectMetadataStore.save(metadata, to: paths.metadataURL)
    }
}

final class ResumeRecordingPipelineRunner: PipelineRunning {
    private let projectURL: URL
    private(set) var resumeFrom: PipelineStage?

    init(projectURL: URL) {
        self.projectURL = projectURL
    }

    func run(
        resumeFrom lastCompletedStage: PipelineStage?,
        events: @escaping @Sendable (PipelineEvent) -> Void
    ) async throws {
        resumeFrom = lastCompletedStage
        let paths = ProjectPaths(root: projectURL)
        let outputURL = paths.outputURL.appendingPathComponent("splat.ply")
        try FileManager.default.createDirectory(at: paths.outputURL, withIntermediateDirectories: true)
        try writeMinimalPly(at: outputURL)
        var metadata = try ProjectMetadataStore.load(from: paths.metadataURL)
        metadata.outputs = OutputSpec(
            splatPlyPath: "Output/splat.ply",
            colmapModelPath: "SfM/colmap/sparse/0"
        )
        metadata.state = PipelineState(stage: .done, lastError: nil)
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
        metadata.state = PipelineState(stage: .done, lastError: nil)
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
        metadata.state = PipelineState(stage: .done, lastError: nil)
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
