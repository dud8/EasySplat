import XCTest
@testable import EasySplatApp

final class WorkspacePresentationTests: XCTestCase {
    func testProcessingFixtureRequiresTheVerifierFlagAndIsolatedHome() {
        let home = URL(fileURLWithPath: "/tmp/easysplat-ui-harness", isDirectory: true)
        let project = home
            .appendingPathComponent("Documents/EasySplat Projects", isDirectory: true)
            .appendingPathComponent("Processing Fixture.easysplatproj", isDirectory: true)
        let environment = [
            "HOME": home.path,
            "EASYSPLAT_ISOLATED_UI_RUNNER": "1",
            "EASYSPLAT_UI_VERIFIER_PROCESSING_PROJECT": project.path,
        ]
        let arguments = ["EasySplatApp", "--easysplat-ui-verifier-processing-fixture"]

        XCTAssertEqual(
            AppConfig.uiVerificationProcessingProjectURL(
                environment: environment,
                arguments: arguments
            ),
            project.standardizedFileURL
        )
        XCTAssertNil(AppConfig.uiVerificationProcessingProjectURL(
            environment: environment.merging(["EASYSPLAT_ISOLATED_UI_RUNNER": "0"]) { _, new in new },
            arguments: arguments
        ))
        XCTAssertNil(AppConfig.uiVerificationProcessingProjectURL(
            environment: environment,
            arguments: ["EasySplatApp"]
        ))
        XCTAssertNil(AppConfig.uiVerificationProcessingProjectURL(
            environment: environment.merging([
                "EASYSPLAT_UI_VERIFIER_PROCESSING_PROJECT": "/tmp/outside.easysplatproj"
            ]) { _, new in new },
            arguments: arguments
        ))
    }

    @MainActor
    func testProcessingFixtureSeedsOnlyTheActivePresentationState() {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let project = base.appendingPathComponent(
            "Processing Fixture.easysplatproj",
            isDirectory: true
        )
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let model = AppModel(
            toolchainManager: MockToolchainManager(),
            projectBaseURL: base
        )

        model.applyUIVerificationProcessingFixture(projectURL: project, now: now)

        XCTAssertEqual(model.viewState, .processing)
        XCTAssertEqual(model.currentProjectURL, project)
        XCTAssertEqual(model.stage, .sfmMapping)
        XCTAssertNil(model.progress)
        XCTAssertEqual(model.statusTitle, "Refining camera poses")
        XCTAssertEqual(model.elapsedSincePhaseStart(now: now), 12 * 60)
        XCTAssertEqual(model.lastPipelineEventAt, now.addingTimeInterval(-8))
        XCTAssertTrue(model.isRunActive)
        XCTAssertNil(model.currentTask, "The fixture must not start a pipeline or toolchain task.")
    }

    func testProjectSelectionOnlyOpensFinishedProjects() {
        XCTAssertTrue(ProjectSidebar.opensOnSelection(status: .ready))
        XCTAssertFalse(ProjectSidebar.opensOnSelection(status: .inProgress))
        XCTAssertFalse(ProjectSidebar.opensOnSelection(status: .failed))
        XCTAssertFalse(ProjectSidebar.opensOnSelection(status: .needsAppUpdate))
        XCTAssertEqual(ProjectSidebar.rowActionTitle(status: .inProgress), "Resume")
        XCTAssertEqual(ProjectSidebar.rowActionTitle(status: .failed), "Try Again")
        XCTAssertNil(ProjectSidebar.rowActionTitle(status: .ready))
        XCTAssertNil(ProjectSidebar.rowActionTitle(status: .needsAppUpdate))
    }

    func testSetupStopCopyDoesNotPromiseAProjectOrCheckpoint() {
        XCTAssertEqual(ProcessingView.stopToolbarTitle(projectExists: false), "Stop Setup…")
        XCTAssertEqual(ProcessingView.stopDialogTitle(projectExists: false, isTraining: false), "Stop setup?")
        XCTAssertEqual(ProcessingView.stopActionTitle(projectExists: false), "Stop Setup")
        XCTAssertEqual(
            ProcessingView.stopDialogMessage(projectExists: false, isTraining: false),
            "EasySplat will stop preparing tools. No project has been created."
        )
        XCTAssertEqual(
            ProcessingView.failureActionTitle(recovery: .useAutomaticPhotoSelection),
            "Use Automatic Selection"
        )
    }

    func testProfessionalOptionLabelsStayPlainAndSpecific() {
        XCTAssertEqual(HomeView.detailLabel(.highDetail), "High Detail")
        XCTAssertEqual(HomeView.captureLabel(.orbit), "Around a subject")
        XCTAssertEqual(HomeView.captureLabel(.walkthrough), "Through a space")
        XCTAssertEqual(HomeView.captureLabel(.largeArea), "Across a large area")
        XCTAssertEqual(HomeView.cameraLabel(.mixedCamerasOrLenses), "Mixed cameras")
        XCTAssertEqual(HomeView.lensLabel(.fisheye), "Fisheye")
        XCTAssertEqual(HomeView.orderLabel(.continuous), "Continuous")
        XCTAssertEqual(HomeView.resourceLabel(.conserveMemory), "Conserve Memory")
    }
}
