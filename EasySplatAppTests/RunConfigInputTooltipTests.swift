#if canImport(XCTest)
import XCTest
@testable import EasySplatApp
@testable import EasySplatCore

final class RunConfigInputTooltipTests: XCTestCase {
    func testInputTooltipNamesVideosAndPhotoFolder() {
        XCTAssertEqual(
            RunConfigSummaryView.inputTooltip(for: .video(files: [
                "/tmp/kitchen.mov",
                "/tmp/lamp.mov",
                "/tmp/chair.mov",
                "/tmp/plant.mov"
            ])),
            "kitchen.mov, lamp.mov, chair.mov and 1 more"
        )
        XCTAssertEqual(
            RunConfigSummaryView.inputTooltip(for: .photos(folder: "/tmp/Desk Photos")),
            "Desk Photos"
        )
        XCTAssertEqual(
            RunConfigSummaryView.inputTooltip(for: .mixed(videos: ["/tmp/a.mov"], photosFolder: "/tmp/Table Set")),
            "1 video + Table Set"
        )
    }
}
#endif
