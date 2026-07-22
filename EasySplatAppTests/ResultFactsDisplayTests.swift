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

    func testPartialCoverageWarnsOnlyBelowTheStrictRegistrationFloor() throws {
        // The user's scenario: 18 of 22 photos, 4 stray singletons.
        let strays = ViewerView.partialCoverageSummary(
            registeredViewCount: 18,
            totalViewCount: 22,
            componentViewCounts: [18, 1, 1, 1, 1]
        )
        XCTAssertEqual(strays?.registered, 18)
        XCTAssertEqual(strays?.total, 22)
        XCTAssertEqual(strays?.separateGroupViewCount, 0)
        XCTAssertEqual(
            ViewerView.partialCoverageMessage(try XCTUnwrap(strays)),
            "This splat covers 18 of 22 photos. To include the rest, add photos that overlap the missing areas, then use Re-train in the More menu."
        )

        // A split capture names the separate group.
        let split = ViewerView.partialCoverageSummary(
            registeredViewCount: 12,
            totalViewCount: 22,
            componentViewCounts: [12, 10]
        )
        XCTAssertEqual(split?.separateGroupViewCount, 10)
        XCTAssertEqual(
            ViewerView.partialCoverageMessage(try XCTUnwrap(split)),
            "This splat covers 12 of 22 photos. A separate group of 10 photos couldn't be connected to it. Add photos that bridge the two areas, then use Re-train in the More menu."
        )

        // At or above the floor a fully connected run always clears, no hint:
        // exactly 90% and full registration stay silent.
        XCTAssertNil(ViewerView.partialCoverageSummary(
            registeredViewCount: 9,
            totalViewCount: 10,
            componentViewCounts: [9, 1]
        ))
        XCTAssertNil(ViewerView.partialCoverageSummary(
            registeredViewCount: 22,
            totalViewCount: 22,
            componentViewCounts: [22]
        ))
        XCTAssertNil(ViewerView.partialCoverageSummary(
            registeredViewCount: 0,
            totalViewCount: 0,
            componentViewCounts: nil
        ))
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
