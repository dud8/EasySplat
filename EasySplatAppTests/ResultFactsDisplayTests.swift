import EasySplatCore
import XCTest
@testable import EasySplatApp

final class ResultFactsDisplayTests: XCTestCase {
    func testDurationFormattingStaysCompact() {
        XCTAssertEqual(StageTimingDisplay.formatDuration(seconds: 0), "0s")
        XCTAssertEqual(StageTimingDisplay.formatDuration(seconds: 45), "45s")
        XCTAssertEqual(StageTimingDisplay.formatDuration(seconds: 60), "1m")
        XCTAssertEqual(StageTimingDisplay.formatDuration(seconds: 150), "2m 30s")
        XCTAssertEqual(StageTimingDisplay.formatDuration(seconds: 3_600), "1h")
        XCTAssertEqual(StageTimingDisplay.formatDuration(seconds: 3_725), "1h 2m")
    }

    func testResultTotalPrefersCreateToViewerReadyWithoutChangingStageTotal() {
        let stages = [
            StageTimingRecord(
                stage: .sfmFeatures,
                startedAt: Date(timeIntervalSince1970: 0),
                durationSeconds: 40
            ),
            StageTimingRecord(
                stage: .trainSplat,
                startedAt: Date(timeIntervalSince1970: 40),
                durationSeconds: 60
            ),
        ]

        XCTAssertEqual(stages.totalDurationSeconds, 100)
        XCTAssertEqual(
            ViewerView.totalDurationSeconds(
                createToViewerReadySeconds: 135,
                stageTimings: stages
            ),
            135
        )
    }
}
