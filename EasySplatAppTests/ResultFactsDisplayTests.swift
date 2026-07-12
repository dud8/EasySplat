import EasySplatCore
import XCTest
@testable import EasySplatApp

final class ResultFactsDisplayTests: XCTestCase {
    func testTechnicalSolverLabelsCoverCurrentRoutes() {
        let labels = [
            "da3-refined": "Depth Anything 3 + refinement",
            "global_mapper": "COLMAP global mapper",
            "colmap": "COLMAP mapper",
        ]
        for (raw, expected) in labels {
            let summary = ReconstructionSummary(
                mapper: raw,
                capturedAt: Date(timeIntervalSince1970: 0),
                registeredImages: 1,
                totalImages: 1
            )
            XCTAssertEqual(summary.displayMapper, expected)
        }
    }

    func testDurationFormattingStaysCompact() {
        XCTAssertEqual(StageTimingDisplay.formatDuration(seconds: 0), "0s")
        XCTAssertEqual(StageTimingDisplay.formatDuration(seconds: 45), "45s")
        XCTAssertEqual(StageTimingDisplay.formatDuration(seconds: 60), "1m")
        XCTAssertEqual(StageTimingDisplay.formatDuration(seconds: 150), "2m 30s")
        XCTAssertEqual(StageTimingDisplay.formatDuration(seconds: 3_600), "1h")
        XCTAssertEqual(StageTimingDisplay.formatDuration(seconds: 3_725), "1h 2m")
    }
}
