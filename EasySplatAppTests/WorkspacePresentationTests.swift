import XCTest
@testable import EasySplatApp

final class WorkspacePresentationTests: XCTestCase {
    func testNewSplatIsDisabledOnlyWhileAHealthyRunIsActive() {
        XCTAssertTrue(RootView.newSplatIsDisabled(isProcessing: true, hasError: false))
        XCTAssertFalse(RootView.newSplatIsDisabled(isProcessing: true, hasError: true))
        XCTAssertFalse(RootView.newSplatIsDisabled(isProcessing: false, hasError: false))
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
