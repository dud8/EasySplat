#if canImport(XCTest)
import XCTest
@testable import EasySplatApp

final class DropZoneStateTextTests: XCTestCase {
    func testDropZoneCopySwitchesWhileTargeted() {
        XCTAssertEqual(
            DropZoneView.displayTitle(restingTitle: "Drop input", isTargeted: false),
            "Drop input"
        )
        XCTAssertEqual(
            DropZoneView.displaySubtitle(restingSubtitle: "Videos or photos", isTargeted: false),
            "Videos or photos"
        )
        XCTAssertEqual(
            DropZoneView.displayTitle(restingTitle: "Drop input", isTargeted: true),
            "Release to add"
        )
        XCTAssertEqual(
            DropZoneView.displaySubtitle(restingSubtitle: "Videos or photos", isTargeted: true),
            "Videos, photos, folders, or datasets"
        )
    }
}
#endif
