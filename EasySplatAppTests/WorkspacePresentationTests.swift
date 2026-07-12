import XCTest
@testable import EasySplatApp

final class WorkspacePresentationTests: XCTestCase {
    func testNewSplatIsDisabledOnlyWhileAHealthyRunIsActive() {
        XCTAssertTrue(RootView.newSplatIsDisabled(isProcessing: true, hasError: false))
        XCTAssertFalse(RootView.newSplatIsDisabled(isProcessing: true, hasError: true))
        XCTAssertFalse(RootView.newSplatIsDisabled(isProcessing: false, hasError: false))
    }
}
