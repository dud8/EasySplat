#if canImport(XCTest)
import AppKit
import Foundation
import XCTest
@testable import EasySplatApp
@testable import EasySplatCore

@MainActor
final class SubjectIsolationAppModelTests: XCTestCase {
    func testIsolationAcquiresMsplatAndCompletesWithoutReplacingCanonicalOutput() async throws {
        let base = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        let projectURL = base.appendingPathComponent(
            "Subject.easysplatproj",
            isDirectory: true
        )
        let paths = ProjectPaths(root: projectURL)
        try paths.ensureDirectories()
        let originalURL = paths.outputSplatURL
        let subjectURL = paths.isolatedOutputURL
        try Data("canonical".utf8).write(to: originalURL)
        try Data("subject".utf8).write(to: subjectURL)

        let progress = SubjectIsolationProgress(
            phase: .filtering,
            completedUnitCount: 3,
            totalUnitCount: 4
        )
        let output = ValidatedSplatOutput(
            variant: .subject,
            url: subjectURL,
            sha256: String(repeating: "a", count: 64),
            byteCount: 7,
            gaussianCount: 42,
            sceneBounds: SplatSceneBounds(
                center: ScenePoint3D(x: 1, y: 2, z: 3),
                radius: 4
            )
        )
        let operation = RecordingSubjectIsolationCoordinator(
            progress: [progress],
            outcome: .completed(output)
        )
        let toolchain = RecordingIsolationToolchainManager(
            paths: makeIsolationToolchainPaths()
        )
        let power = RecordingPowerAssertion()
        operation.onEnter = {
            operation.powerWasActive = power.begun == 1 && power.released == 0
        }
        let hardware = HardwareProfile(
            memoryGB: 48,
            cpuCount: 16,
            gpuWorkingSetGB: 36
        )
        let model = AppModel(
            toolchainManager: toolchain,
            projectBaseURL: base,
            hardwareProfile: hardware,
            powerAssertion: power,
            subjectIsolationCoordinatorFactory: { operation }
        )
        model.viewState = .viewer
        model.currentProjectURL = projectURL
        model.outputPlyURL = originalURL
        model.subjectOutput = output
        model.selectedSplatOutputVariant = .subject
        model.isShareReady = true

        XCTAssertTrue(model.startSubjectIsolation())
        XCTAssertTrue(model.isSubjectIsolationActive)
        XCTAssertTrue(model.hasActiveWork)
        XCTAssertNil(model.currentTask)
        try await waitUntil { !model.isSubjectIsolationActive }

        XCTAssertEqual(
            toolchain.lastRequest,
            ToolchainCapabilityRequest(capabilities: [.msplat])
        )
        let request = try XCTUnwrap(operation.request)
        XCTAssertEqual(request.projectPaths.root, projectURL)
        XCTAssertEqual(request.nativeExecutableURL, makeIsolationToolchainPaths().msplat)
        XCTAssertEqual(request.nativeMetallibURL, makeIsolationToolchainPaths().metallib)
        XCTAssertEqual(request.toolchainBuildIdentity, "test-toolchain-v1")
        XCTAssertEqual(request.memoryBudgetBytes, 8 * 1_073_741_824)
        XCTAssertNil(request.anchor)
        XCTAssertTrue(operation.powerWasActive)
        XCTAssertEqual(power.begun, 1)
        XCTAssertEqual(power.released, 1)
        XCTAssertEqual(model.subjectIsolationProgress, progress)
        XCTAssertEqual(model.subjectOutput, output)
        XCTAssertEqual(model.selectedSplatOutputVariant, .subject)
        XCTAssertEqual(model.displayedOutputURL, subjectURL)
        XCTAssertEqual(model.displayedOutputSceneBounds, output.sceneBounds)
        XCTAssertEqual(model.outputPlyURL, originalURL)
        XCTAssertFalse(model.isShareReady)
        XCTAssertFalse(model.hasActiveWork)
        XCTAssertNil(model.currentTask)
    }

    func testAmbiguityKeepsOriginalSelectedAndPublishesNoSubjectOutput() async throws {
        let fixture = try makeViewerFixture()
        defer { fixture.cleanup() }
        let request = makeChoiceRequest(in: fixture.paths)
        let operation = RecordingSubjectIsolationCoordinator(
            outcome: .ambiguity(request)
        )
        let model = makeViewerModel(fixture: fixture, operation: operation)

        XCTAssertTrue(model.startSubjectIsolation())
        try await waitUntil { !model.isSubjectIsolationActive }

        XCTAssertEqual(model.subjectChoiceRequest, request)
        XCTAssertNil(model.subjectOutput)
        XCTAssertEqual(model.selectedSplatOutputVariant, .original)
        XCTAssertEqual(model.displayedOutputURL, fixture.originalURL)
        XCTAssertEqual(model.outputPlyURL, fixture.originalURL)
        XCTAssertFalse(model.subjectIsolationStatusIsError)
    }

    func testNoSubjectUsesRequiredCopyAndLeavesOriginalUnchanged() async throws {
        let fixture = try makeViewerFixture()
        defer { fixture.cleanup() }
        let model = makeViewerModel(
            fixture: fixture,
            operation: RecordingSubjectIsolationCoordinator(outcome: .noSubject)
        )

        XCTAssertTrue(model.startSubjectIsolation())
        try await waitUntil { !model.isSubjectIsolationActive }

        XCTAssertEqual(
            model.subjectIsolationStatusMessage,
            "No clear subject to isolate. The original is unchanged."
        )
        XCTAssertFalse(model.subjectIsolationStatusIsError)
        XCTAssertNil(model.subjectOutput)
        XCTAssertEqual(model.outputPlyURL, fixture.originalURL)
        XCTAssertEqual(model.displayedOutputURL, fixture.originalURL)
    }

    func testFailureSaysOriginalIsUnchanged() async throws {
        let fixture = try makeViewerFixture()
        defer { fixture.cleanup() }
        let model = makeViewerModel(
            fixture: fixture,
            operation: FailingSubjectIsolationCoordinator()
        )

        XCTAssertTrue(model.startSubjectIsolation())
        try await waitUntil { !model.isSubjectIsolationActive }

        XCTAssertEqual(
            model.subjectIsolationStatusMessage,
            "Couldn’t isolate the subject. The original is unchanged."
        )
        XCTAssertTrue(model.subjectIsolationStatusIsError)
        XCTAssertNil(model.subjectOutput)
        XCTAssertEqual(model.outputPlyURL, fixture.originalURL)
    }

    func testRetryForwardsTheExactAnchor() async throws {
        let fixture = try makeViewerFixture()
        defer { fixture.cleanup() }
        let operation = RecordingSubjectIsolationCoordinator(outcome: .noSubject)
        let model = makeViewerModel(fixture: fixture, operation: operation)
        let anchor = SubjectAnchor(
            imageIdentity: "frame-017.png",
            instanceLabel: 9,
            normalizedX: 0.123,
            normalizedY: 0.987
        )

        XCTAssertTrue(model.retrySubjectIsolation(anchor: anchor))
        try await waitUntil { !model.isSubjectIsolationActive }

        XCTAssertEqual(operation.request?.anchor, anchor)
    }

    func testCancellationWaitsForTeardownAndRejectsLateCompletion() async throws {
        let fixture = try makeViewerFixture()
        defer { fixture.cleanup() }
        let operation = ControllableSubjectIsolationCoordinator()
        let model = makeViewerModel(fixture: fixture, operation: operation)

        XCTAssertTrue(model.startSubjectIsolation())
        try await waitUntil { operation.hasStarted }
        model.cancelSubjectIsolation()

        XCTAssertTrue(model.isSubjectIsolationActive)
        XCTAssertNil(model.subjectOutput)
        operation.finish(.completed(fixture.subjectOutput))
        try await waitUntil { !model.isSubjectIsolationActive }

        XCTAssertNil(model.subjectOutput)
        XCTAssertEqual(model.selectedSplatOutputVariant, .original)
        XCTAssertEqual(model.outputPlyURL, fixture.originalURL)
        XCTAssertNil(model.subjectIsolationStatusMessage)
        XCTAssertFalse(model.subjectIsolationStatusIsError)
    }

    func testStaleProgressFromAnOldTokenCannotOverwriteTheNewOperation() async throws {
        let fixture = try makeViewerFixture()
        defer { fixture.cleanup() }
        let first = ControllableSubjectIsolationCoordinator()
        let second = ControllableSubjectIsolationCoordinator()
        let factory = CoordinatorQueue([first, second])
        let model = makeViewerModel(
            fixture: fixture,
            coordinatorFactory: { factory.next() }
        )

        XCTAssertTrue(model.startSubjectIsolation())
        try await waitUntil { first.hasStarted }
        first.finish(.noSubject)
        try await waitUntil { !model.isSubjectIsolationActive }

        XCTAssertTrue(model.startSubjectIsolation())
        try await waitUntil { second.hasStarted }
        let current = SubjectIsolationProgress(
            phase: .validating,
            completedUnitCount: 2,
            totalUnitCount: 3
        )
        second.emit(current)
        try await waitUntil { model.subjectIsolationProgress == current }

        first.emit(SubjectIsolationProgress(
            phase: .publishing,
            completedUnitCount: 99,
            totalUnitCount: 100
        ))
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(model.subjectIsolationProgress, current)

        second.finish(.cancelled)
        try await waitUntil { !model.isSubjectIsolationActive }
    }

    func testArtifactReloadMakesOnlyValidSubjectAvailableAndAlwaysSelectsOriginal() async throws {
        let fixture = try makeViewerFixture()
        defer { fixture.cleanup() }
        let loadResult = LockedValue<IsolationArtifactLoadResult>(
            .valid(makeIsolationArtifact(output: fixture.subjectOutput), fixture.subjectOutput)
        )
        let model = makeViewerModel(
            fixture: fixture,
            artifactLoader: { _ in loadResult.value }
        )
        model.subjectOutput = fixture.subjectOutput
        model.selectedSplatOutputVariant = .subject

        await model.reloadSubjectIsolationArtifact(for: fixture.projectURL)

        XCTAssertEqual(model.subjectOutput, fixture.subjectOutput)
        XCTAssertEqual(model.selectedSplatOutputVariant, .original)
        XCTAssertEqual(model.displayedOutputURL, fixture.originalURL)

        for unavailable in [
            IsolationArtifactLoadResult.stale(.sourceOutput),
            .invalid,
            .noArtifact,
        ] {
            loadResult.value = unavailable
            model.subjectOutput = fixture.subjectOutput
            model.selectedSplatOutputVariant = .subject

            await model.reloadSubjectIsolationArtifact(for: fixture.projectURL)

            XCTAssertNil(model.subjectOutput)
            XCTAssertEqual(model.selectedSplatOutputVariant, .original)
            XCTAssertEqual(model.displayedOutputURL, fixture.originalURL)
        }
    }

    func testSubjectRemovalClearsSessionOnlyAfterStoreSuccess() async throws {
        let fixture = try makeViewerFixture()
        defer { fixture.cleanup() }
        let removal = RemovalHarness()
        let model = makeViewerModel(
            fixture: fixture,
            artifactRemover: removal.remove
        )
        model.subjectOutput = fixture.subjectOutput
        model.selectedSplatOutputVariant = .subject
        removal.result = false

        let firstRemovalSucceeded = await model.removeSubjectVersion()
        XCTAssertFalse(firstRemovalSucceeded)
        XCTAssertEqual(model.subjectOutput, fixture.subjectOutput)
        XCTAssertEqual(model.selectedSplatOutputVariant, .subject)
        XCTAssertTrue(model.subjectIsolationStatusIsError)

        removal.result = true
        let secondRemovalSucceeded = await model.removeSubjectVersion()
        XCTAssertTrue(secondRemovalSucceeded)
        XCTAssertNil(model.subjectOutput)
        XCTAssertEqual(model.selectedSplatOutputVariant, .original)
        XCTAssertEqual(removal.paths.last?.root, fixture.projectURL)
    }

    func testSubjectRemovalRunsStoreOffMainActor() async throws {
        let fixture = try makeViewerFixture()
        defer { fixture.cleanup() }
        let removal = RemovalHarness()
        removal.result = true
        let model = makeViewerModel(
            fixture: fixture,
            artifactRemover: removal.remove
        )
        model.subjectOutput = fixture.subjectOutput
        model.selectedSplatOutputVariant = .subject

        let removalSucceeded = await model.removeSubjectVersion()
        XCTAssertTrue(removalSucceeded)
        try await waitUntil { removal.paths.count == 1 }

        XCTAssertEqual(removal.calledOnMainThread, false)
        try await waitUntil { model.subjectOutput == nil }
    }

    func testSubjectRemovalDoesNotClearStateAfterProjectChanges() async throws {
        let fixture = try makeViewerFixture()
        defer { fixture.cleanup() }
        let removal = RemovalHarness()
        removal.result = true
        removal.delay = 0.2
        let model = makeViewerModel(
            fixture: fixture,
            artifactRemover: removal.remove
        )
        model.subjectOutput = fixture.subjectOutput
        model.selectedSplatOutputVariant = .subject
        let otherProject = fixture.base.appendingPathComponent(
            "Other.easysplatproj",
            isDirectory: true
        )

        let task = Task { await model.removeSubjectVersion() }
        try await waitUntil { removal.hasStarted }

        XCTAssertFalse(removal.hasFinished)
        model.currentProjectURL = otherProject
        let removalSucceeded = await task.value
        XCTAssertTrue(removalSucceeded)
        XCTAssertEqual(model.subjectOutput, fixture.subjectOutput)
        XCTAssertEqual(model.selectedSplatOutputVariant, .subject)
    }

    func testSubjectRemovalParticipatesInTheActiveWorkGuard() async throws {
        let fixture = try makeViewerFixture()
        defer { fixture.cleanup() }
        let removal = RemovalHarness()
        removal.result = true
        removal.delay = 0.2
        let model = makeViewerModel(
            fixture: fixture,
            artifactRemover: removal.remove
        )
        model.subjectOutput = fixture.subjectOutput
        model.selectedSplatOutputVariant = .subject

        let task = Task { await model.removeSubjectVersion() }
        try await waitUntil { removal.hasStarted }

        XCTAssertTrue(model.isSubjectVersionRemovalActive)
        XCTAssertTrue(model.hasActiveWork)
        XCTAssertFalse(model.startSubjectIsolation())

        let removalSucceeded = await task.value
        XCTAssertTrue(removalSucceeded)
        XCTAssertFalse(model.isSubjectVersionRemovalActive)
        XCTAssertFalse(model.hasActiveWork)
    }

    func testVariantSelectionRequiresSubjectAndInvalidatesPreparedShareState() {
        let fixture = try! makeViewerFixture()
        defer { fixture.cleanup() }
        let model = makeViewerModel(fixture: fixture)
        model.isShareReady = true

        XCTAssertFalse(model.setSelectedSplatOutputVariant(.subject))
        XCTAssertEqual(model.selectedSplatOutputVariant, .original)
        XCTAssertTrue(model.isShareReady)

        model.subjectOutput = fixture.subjectOutput
        XCTAssertTrue(model.setSelectedSplatOutputVariant(.subject))
        XCTAssertEqual(model.selectedSplatOutputVariant, .subject)
        XCTAssertFalse(model.isShareReady)
        XCTAssertTrue(model.setSelectedSplatOutputVariant(.original))
        XCTAssertEqual(model.displayedOutputURL, fixture.originalURL)
    }

    func testActiveIsolationBlocksModelAndRootProjectSwitchingGuards() throws {
        let fixture = try makeViewerFixture()
        defer { fixture.cleanup() }
        let otherProject = fixture.paths.root.deletingLastPathComponent()
            .appendingPathComponent("Other.easysplatproj", isDirectory: true)
        let otherPaths = ProjectPaths(root: otherProject)
        try otherPaths.ensureDirectories()
        try ProjectMetadataStore.save(
            ProjectMetadata(title: "Other", input: .video(files: [])),
            to: otherPaths.metadataURL
        )
        let trashed = LockedValue(false)
        let model = makeViewerModel(
            fixture: fixture,
            projectTrashHandler: { _ in trashed.value = true }
        )
        model.isSubjectIsolationActive = true
        var selection: URL? = ProjectSidebar.selectionID(for: fixture.projectURL)

        XCTAssertFalse(model.beginNewSplat())
        model.startFromPendingSelection()
        XCTAssertNil(model.currentTask)
        XCTAssertFalse(model.resumeProject(at: otherProject))
        XCTAssertFalse(model.retrainProject(at: otherProject, profile: .balanced))
        XCTAssertFalse(model.moveProjectToTrash(at: otherProject))
        XCTAssertFalse(trashed.value)

        RootView.prepareProjectList(
            model: model,
            selectedProjectURL: &selection
        )
        XCTAssertEqual(selection, ProjectSidebar.selectionID(for: fixture.projectURL))
        XCTAssertEqual(model.currentProjectURL, fixture.projectURL)
        XCTAssertEqual(model.viewState, .viewer)
    }

    func testResetClearsSessionSubjectStateAndRestoresOriginalSelection() {
        let fixture = try! makeViewerFixture()
        defer { fixture.cleanup() }
        let model = makeViewerModel(fixture: fixture)
        model.subjectOutput = fixture.subjectOutput
        model.selectedSplatOutputVariant = .subject
        model.subjectChoiceRequest = makeChoiceRequest(in: fixture.paths)
        model.subjectIsolationStatusMessage = "old"

        model.reset()

        XCTAssertNil(model.subjectOutput)
        XCTAssertNil(model.subjectChoiceRequest)
        XCTAssertNil(model.subjectIsolationStatusMessage)
        XCTAssertEqual(model.selectedSplatOutputVariant, .original)
    }

    func testWindowCloseDeletionWaitsUntilIsolationTeardown() async throws {
        let fixture = try makeViewerFixture()
        defer { fixture.cleanup() }
        let operation = ControllableSubjectIsolationCoordinator()
        let trashed = LockedValue(false)
        let model = makeViewerModel(
            fixture: fixture,
            operation: operation,
            projectTrashHandler: { _ in trashed.value = true }
        )
        model.exitDecisionOverride = { .delete }
        let coordinator = WindowAccessor.Coordinator(model: model)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 920, height: 640),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )

        XCTAssertTrue(model.startSubjectIsolation())
        try await waitUntil { operation.hasStarted }
        XCTAssertFalse(coordinator.windowShouldClose(window))
        XCTAssertTrue(model.isSubjectIsolationActive)
        XCTAssertFalse(trashed.value)

        // Keep the test inside the XCTest host while still exercising the
        // close-triggered cancellation and deferred deletion path.
        model.exitIntent = .none
        operation.finish(.cancelled)
        try await waitUntil { !model.isSubjectIsolationActive }
        XCTAssertTrue(trashed.value)
    }

    func testQuitSeesIsolationAsActiveAndCancelsOnlyIsolation() async throws {
        let fixture = try makeViewerFixture()
        defer { fixture.cleanup() }
        let operation = ControllableSubjectIsolationCoordinator()
        let model = makeViewerModel(fixture: fixture, operation: operation)
        model.exitDecisionOverride = { .save }
        let delegate = AppDelegate(model: model)

        XCTAssertTrue(model.startSubjectIsolation())
        try await waitUntil { operation.hasStarted }
        XCTAssertEqual(
            delegate.applicationShouldTerminate(NSApplication.shared),
            .terminateLater
        )
        XCTAssertTrue(model.isSubjectIsolationActive)
        XCTAssertNil(model.currentTask)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.originalURL.path))

        // Avoid terminating the XCTest host when the controlled operation
        // finally tears down.
        model.exitIntent = .none
        operation.finish(.cancelled)
        try await waitUntil { !model.isSubjectIsolationActive }
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.originalURL.path))
    }

    func testReadyProjectReopenLoadsValidSubjectButDefaultsToOriginal() async throws {
        let fixture = try makeViewerFixture()
        defer { fixture.cleanup() }
        try ProjectMetadataStore.save(
            ProjectMetadata(
                title: "Viewer",
                input: .video(files: []),
                state: PipelineState(stage: .done, lastError: nil)
            ),
            to: fixture.paths.metadataURL
        )
        let model = AppModel(
            toolchainManager: RecordingIsolationToolchainManager(
                paths: makeIsolationToolchainPaths()
            ),
            projectBaseURL: fixture.base,
            subjectIsolationArtifactLoader: { _ in
                .valid(
                    makeIsolationArtifact(output: fixture.subjectOutput),
                    fixture.subjectOutput
                )
            },
            finishedOutputValidator: { _ in fixture.originalURL }
        )

        XCTAssertTrue(model.resumeProject(at: fixture.projectURL))
        try await waitUntil {
            model.viewState == .viewer && !model.isRunActive
        }

        XCTAssertEqual(model.outputPlyURL, fixture.originalURL)
        XCTAssertEqual(model.subjectOutput, fixture.subjectOutput)
        XCTAssertEqual(model.selectedSplatOutputVariant, .original)
        XCTAssertEqual(model.displayedOutputURL, fixture.originalURL)
    }

    func testRetrainClearsSessionSubjectBeforeStartingAndReloadsAfterCompletion() async throws {
        let fixture = try makeViewerFixture()
        defer { fixture.cleanup() }
        try ProjectMetadataStore.save(
            ProjectMetadata(
                title: "Viewer",
                input: .video(files: []),
                state: PipelineState(stage: .done, lastError: nil)
            ),
            to: fixture.paths.metadataURL
        )
        let model = AppModel(
            toolchainManager: RecordingIsolationToolchainManager(
                paths: makeIsolationToolchainPaths()
            ),
            projectBaseURL: fixture.base,
            hardwareProfile: HardwareProfile(
                memoryGB: 48,
                cpuCount: 16,
                gpuWorkingSetGB: 36
            ),
            pipelineRunnerFactory: { _, _ in InstantPipelineRunner() },
            subjectIsolationArtifactLoader: { _ in .noArtifact },
            finishedOutputValidator: { _ in fixture.originalURL }
        )
        model.viewState = .viewer
        model.currentProjectURL = fixture.projectURL
        model.outputPlyURL = fixture.originalURL
        model.subjectOutput = fixture.subjectOutput
        model.selectedSplatOutputVariant = .subject

        XCTAssertTrue(
            model.retrainProject(at: fixture.projectURL, profile: .balanced)
        )
        XCTAssertNil(model.subjectOutput)
        XCTAssertEqual(model.selectedSplatOutputVariant, .original)
        try await waitUntil {
            model.viewState == .viewer && !model.isRunActive
        }
        XCTAssertNil(model.subjectOutput)
        XCTAssertEqual(model.outputPlyURL, fixture.originalURL)
    }

    func testFailedRetrainKeepsValidSessionSubjectAvailable() throws {
        let fixture = try makeViewerFixture()
        defer { fixture.cleanup() }
        let model = AppModel(
            toolchainManager: RecordingIsolationToolchainManager(
                paths: makeIsolationToolchainPaths()
            ),
            projectBaseURL: fixture.base
        )
        model.viewState = .viewer
        model.currentProjectURL = fixture.projectURL
        model.outputPlyURL = fixture.originalURL
        model.subjectOutput = fixture.subjectOutput
        model.selectedSplatOutputVariant = .subject

        XCTAssertFalse(
            model.retrainProject(at: fixture.projectURL, profile: .balanced)
        )
        XCTAssertEqual(model.subjectOutput, fixture.subjectOutput)
        XCTAssertEqual(model.selectedSplatOutputVariant, .subject)
        XCTAssertEqual(model.displayedOutputURL, fixture.subjectOutput.url)
        XCTAssertFalse(model.isRunActive)
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(
            "EasySplat-subject-app-tests-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: true
        )
        return url
    }

    private func makeViewerFixture() throws -> ViewerFixture {
        let base = try temporaryDirectory()
        let projectURL = base.appendingPathComponent(
            "Viewer.easysplatproj",
            isDirectory: true
        )
        let paths = ProjectPaths(root: projectURL)
        try paths.ensureDirectories()
        try Data("original".utf8).write(to: paths.outputSplatURL)
        try Data("subject".utf8).write(to: paths.isolatedOutputURL)
        let output = ValidatedSplatOutput(
            variant: .subject,
            url: paths.isolatedOutputURL,
            sha256: String(repeating: "b", count: 64),
            byteCount: 7,
            gaussianCount: 21,
            sceneBounds: SplatSceneBounds(
                center: ScenePoint3D(x: 0, y: 1, z: 2),
                radius: 3
            )
        )
        return ViewerFixture(
            base: base,
            projectURL: projectURL,
            paths: paths,
            originalURL: paths.outputSplatURL,
            subjectOutput: output
        )
    }

    private func makeViewerModel(
        fixture: ViewerFixture,
        operation: any SubjectIsolationCoordinating =
            RecordingSubjectIsolationCoordinator(outcome: .noSubject),
        coordinatorFactory: AppModel.SubjectIsolationCoordinatorFactory? = nil,
        artifactLoader: @escaping AppModel.SubjectIsolationArtifactLoader = {
            _ in .noArtifact
        },
        artifactRemover: @escaping AppModel.SubjectIsolationArtifactRemover = {
            paths in
            try SubjectIsolationArtifactStore.removeValidatedSubject(paths: paths)
        },
        projectTrashHandler: @escaping (URL) throws -> Void = { _ in }
    ) -> AppModel {
        let model = AppModel(
            toolchainManager: RecordingIsolationToolchainManager(
                paths: makeIsolationToolchainPaths()
            ),
            projectBaseURL: fixture.base,
            hardwareProfile: HardwareProfile(
                memoryGB: 48,
                cpuCount: 16,
                gpuWorkingSetGB: 36
            ),
            subjectIsolationCoordinatorFactory: coordinatorFactory ?? {
                operation
            },
            subjectIsolationArtifactLoader: artifactLoader,
            subjectIsolationArtifactRemover: artifactRemover,
            projectTrashHandler: projectTrashHandler
        )
        model.viewState = .viewer
        model.currentProjectURL = fixture.projectURL
        model.outputPlyURL = fixture.originalURL
        return model
    }

    private func waitUntil(
        timeout: TimeInterval = 2,
        _ condition: @MainActor () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() {
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Timed out waiting for condition.")
    }
}

private struct ViewerFixture {
    let base: URL
    let projectURL: URL
    let paths: ProjectPaths
    let originalURL: URL
    let subjectOutput: ValidatedSplatOutput

    func cleanup() {
        try? FileManager.default.removeItem(at: base)
    }
}

private func makeChoiceRequest(in paths: ProjectPaths) -> SubjectChoiceRequest {
    SubjectChoiceRequest(
        keyframeImageURL: paths.framesSelectedURL.appendingPathComponent("frame.png"),
        combinedInstanceLabelMaskURL: paths.isolationURL.appendingPathComponent("choice.png"),
        pixelWidth: 640,
        pixelHeight: 480,
        candidates: [
            SubjectChoiceRequest.Candidate(
                componentIdentity: "main",
                instanceLabel: 3,
                confidence: 0.91
            ),
        ]
    )
}

private func makeIsolationArtifact(
    output: ValidatedSplatOutput
) -> IsolationArtifact {
    IsolationArtifact(
        sourcePlySHA256: String(repeating: "1", count: 64),
        trainingManifestSHA256: String(repeating: "2", count: 64),
        dataset: .init(
            inputDigest: String(repeating: "3", count: 64),
            geometryDigest: String(repeating: "4", count: 64),
            selectedFramesDigest: String(repeating: "5", count: 64),
            selectedImageOrder: ["frame.png"]
        ),
        masks: [],
        toolchainBuildIdentity: "test",
        nativeExecutableSHA256: String(repeating: "6", count: 64),
        visionRequestRevision: 1,
        selectedViewIdentities: ["frame.png"],
        heldOutViewIdentities: [],
        policy: .init(
            version: 1,
            minimumMaskConfidence: 0.8,
            minimumHeldOutMedianIoU: 0.6,
            minimumHeldOutFirstQuartileIoU: 0.5,
            minimumRetainedGaussianFraction: 0.01,
            maximumRetainedGaussianFraction: 0.95
        ),
        subjectAnchor: nil,
        metrics: .init(
            meanMaskConfidence: 0.9,
            heldOutMeanIoU: nil,
            heldOutMedianIoU: nil,
            heldOutFirstQuartileIoU: nil,
            retainedGaussianFraction: 0.5
        ),
        output: .init(
            identity: UUID(),
            relativePath: "Output/isolated.ply",
            sha256: output.sha256,
            byteCount: output.byteCount,
            gaussianCount: output.gaussianCount,
            sceneBounds: output.sceneBounds
        )
    )
}

private func makeIsolationToolchainPaths() -> ToolchainPaths {
    let root = URL(fileURLWithPath: "/mock/toolchain")
    let da3Root = root.appendingPathComponent("da3", isDirectory: true)
    return ToolchainPaths(
        root: root,
        dataRoot: root,
        toolchainIdentity: "test-toolchain-v1",
        colmap: root.appendingPathComponent("bin/colmap"),
        msplat: root.appendingPathComponent("bin/easysplat-train"),
        metallib: root.appendingPathComponent("bin/default.metallib"),
        da3: Da3Toolchain(
            root: da3Root,
            sfmTool: da3Root.appendingPathComponent("bin/easysplat_da3_sfm"),
            python: da3Root.appendingPathComponent("python/bin/python3"),
            models: da3Root.appendingPathComponent("models", isDirectory: true),
            modelBundle: da3Root.appendingPathComponent("models/da3-base.safetensors"),
            smallModelBundle: da3Root.appendingPathComponent("models/da3-small.safetensors")
        )
    )
}

private final class RecordingIsolationToolchainManager:
    ToolchainManaging,
    @unchecked Sendable
{
    private let lock = NSLock()
    private let paths: ToolchainPaths
    private var request: ToolchainCapabilityRequest?

    init(paths: ToolchainPaths) {
        self.paths = paths
    }

    var lastRequest: ToolchainCapabilityRequest? {
        lock.withLock { request }
    }

    func resolveToolchain(
        request: ToolchainCapabilityRequest,
        onProgress: @escaping @Sendable (Double, String) -> Void
    ) async throws -> ToolchainPaths {
        lock.withLock {
            self.request = request
        }
        onProgress(0.5, "Preparing isolation tools")
        return paths
    }
}

private final class RecordingSubjectIsolationCoordinator:
    SubjectIsolationCoordinating,
    @unchecked Sendable
{
    private let lock = NSLock()
    private let progress: [SubjectIsolationProgress]
    private let outcome: SubjectIsolationOutcome
    private var recordedRequest: SubjectIsolationRequest?

    var onEnter: @Sendable () -> Void = {}
    var powerWasActive = false

    init(
        progress: [SubjectIsolationProgress] = [],
        outcome: SubjectIsolationOutcome
    ) {
        self.progress = progress
        self.outcome = outcome
    }

    var request: SubjectIsolationRequest? {
        lock.withLock { recordedRequest }
    }

    func isolate(
        request: SubjectIsolationRequest,
        onProgress: @escaping @Sendable (SubjectIsolationProgress) -> Void,
        onLog: @escaping @Sendable (String, Bool) -> Void
    ) async throws -> SubjectIsolationOutcome {
        lock.withLock {
            recordedRequest = request
        }
        onEnter()
        onLog("native output", false)
        for value in progress {
            onProgress(value)
        }
        return outcome
    }
}

private struct FailingSubjectIsolationCoordinator:
    SubjectIsolationCoordinating
{
    struct Failure: Error {}

    func isolate(
        request: SubjectIsolationRequest,
        onProgress: @escaping @Sendable (SubjectIsolationProgress) -> Void,
        onLog: @escaping @Sendable (String, Bool) -> Void
    ) async throws -> SubjectIsolationOutcome {
        throw Failure()
    }
}

private final class ControllableSubjectIsolationCoordinator:
    SubjectIsolationCoordinating,
    @unchecked Sendable
{
    private let lock = NSLock()
    private var continuation:
        CheckedContinuation<SubjectIsolationOutcome, any Error>?
    private var progressHandler:
        (@Sendable (SubjectIsolationProgress) -> Void)?

    var hasStarted: Bool {
        lock.withLock { continuation != nil }
    }

    func isolate(
        request: SubjectIsolationRequest,
        onProgress: @escaping @Sendable (SubjectIsolationProgress) -> Void,
        onLog: @escaping @Sendable (String, Bool) -> Void
    ) async throws -> SubjectIsolationOutcome {
        try await withCheckedThrowingContinuation { continuation in
            lock.withLock {
                self.progressHandler = onProgress
                self.continuation = continuation
            }
        }
    }

    func emit(_ progress: SubjectIsolationProgress) {
        let handler = lock.withLock { progressHandler }
        handler?(progress)
    }

    func finish(_ outcome: SubjectIsolationOutcome) {
        let pending = lock.withLock {
            let pending = continuation
            continuation = nil
            return pending
        }
        pending?.resume(returning: outcome)
    }
}

private final class CoordinatorQueue: @unchecked Sendable {
    private let lock = NSLock()
    private var coordinators: [any SubjectIsolationCoordinating]

    init(_ coordinators: [any SubjectIsolationCoordinating]) {
        self.coordinators = coordinators
    }

    func next() -> any SubjectIsolationCoordinating {
        lock.withLock {
            precondition(!coordinators.isEmpty)
            return coordinators.removeFirst()
        }
    }
}

private final class LockedValue<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value

    init(_ value: Value) {
        stored = value
    }

    var value: Value {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}

private final class RemovalHarness: @unchecked Sendable {
    private let lock = NSLock()
    private var storedResult = false
    private var recordedPaths: [ProjectPaths] = []
    private var removalCalledOnMainThread: Bool?
    private var storedDelay: TimeInterval = 0
    private var started = false
    private var finished = false

    var result: Bool {
        get { lock.withLock { storedResult } }
        set { lock.withLock { storedResult = newValue } }
    }

    var paths: [ProjectPaths] {
        lock.withLock { recordedPaths }
    }

    var delay: TimeInterval {
        get { lock.withLock { storedDelay } }
        set { lock.withLock { storedDelay = newValue } }
    }

    var calledOnMainThread: Bool? {
        lock.withLock { removalCalledOnMainThread }
    }

    var hasStarted: Bool {
        lock.withLock { started }
    }

    var hasFinished: Bool {
        lock.withLock { finished }
    }

    func remove(paths: ProjectPaths) throws -> Bool {
        let (result, delay) = lock.withLock {
            removalCalledOnMainThread = Thread.isMainThread
            recordedPaths.append(paths)
            started = true
            return (storedResult, storedDelay)
        }
        if delay > 0 {
            Thread.sleep(forTimeInterval: delay)
        }
        lock.withLock {
            finished = true
        }
        return result
    }
}

private final class InstantPipelineRunner: PipelineRunning {
    func run(
        resumeFrom lastCompletedStage: PipelineStage?,
        events: @escaping @Sendable (PipelineEvent) -> Void
    ) async throws {}
}
#endif
