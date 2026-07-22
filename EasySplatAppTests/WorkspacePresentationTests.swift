import XCTest
@testable import EasySplatApp

final class WorkspacePresentationTests: XCTestCase {
    func testWorkspaceUsesStandardDurationUnlessReduceMotionIsEnabled() {
        XCTAssertEqual(
            WorkspaceView.workspaceAnimationDuration(reduceMotion: false),
            Theme.Motion.standardWorkspaceDuration
        )
        XCTAssertEqual(Theme.Motion.standardWorkspaceDuration, 0.16)
        XCTAssertNil(WorkspaceView.workspaceAnimationDuration(reduceMotion: true))
    }

    func testProjectSelectionOnlyOpensFinishedProjects() {
        XCTAssertTrue(ProjectSidebar.opensOnSelection(status: .ready))
        XCTAssertFalse(ProjectSidebar.opensOnSelection(status: .inProgress))
        XCTAssertFalse(ProjectSidebar.opensOnSelection(status: .failed))
        XCTAssertEqual(ProjectSidebar.rowActionTitle(status: .inProgress), "Resume")
        XCTAssertEqual(ProjectSidebar.rowActionTitle(status: .failed), "Try Again")
        XCTAssertNil(ProjectSidebar.rowActionTitle(status: .ready))
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

    func testRunStopCopyNamesTheRunInsteadOfTrailingOff() {
        XCTAssertEqual(ProcessingView.stopToolbarTitle(projectExists: true), "Stop Run…")
        XCTAssertEqual(ProcessingView.stopToolbarTitle(projectExists: false), "Stop Setup…")
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
