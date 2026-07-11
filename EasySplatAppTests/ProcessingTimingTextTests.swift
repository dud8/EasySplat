import XCTest
@testable import EasySplatApp

/// Covers the pure timing-caption logic extracted from ProcessingView. These assert real
/// formatting behavior (clamping, rounding, sub-second silence, absent prediction) rather
/// than pinning presentation copy.
@MainActor
final class ProcessingTimingTextTests: XCTestCase {
    func testFormatElapsedClampsRoundsAndFormats() {
        XCTAssertEqual(ProcessingView.formatElapsed(0), "0m 00s")
        XCTAssertEqual(ProcessingView.formatElapsed(-5), "0m 00s", "Negative elapsed clamps to zero.")
        XCTAssertEqual(ProcessingView.formatElapsed(65), "1m 05s")
        XCTAssertEqual(ProcessingView.formatElapsed(90.6), "1m 31s", "Rounds to the nearest second.")
        XCTAssertEqual(ProcessingView.formatElapsed(3661), "1h 01m 01s", "Hours appear only when non-zero.")
    }

    func testTimingTextIsNilWithoutElapsed() {
        XCTAssertNil(ProcessingView.timingText(elapsed: nil, silenceSeconds: 5, stagePrediction: 10))
    }

    func testTimingTextElapsedOnly() {
        XCTAssertEqual(
            ProcessingView.timingText(elapsed: 65, silenceSeconds: nil, stagePrediction: nil),
            "Elapsed 1m 05s"
        )
    }

    func testTimingTextSubSecondSilenceReadsNow() {
        XCTAssertEqual(
            ProcessingView.timingText(elapsed: 65, silenceSeconds: 0.4, stagePrediction: nil),
            "Elapsed 1m 05s • Last update now"
        )
    }

    func testTimingTextSilenceAtLeastOneSecondReadsAgo() {
        XCTAssertEqual(
            ProcessingView.timingText(elapsed: 65, silenceSeconds: 5, stagePrediction: nil),
            "Elapsed 1m 05s • Last update 0m 05s ago"
        )
    }

    func testTimingTextIncludesPredictionWhenPresent() {
        XCTAssertEqual(
            ProcessingView.timingText(elapsed: 65, silenceSeconds: nil, stagePrediction: 130),
            "Elapsed 1m 05s • Typical 2m 10s"
        )
    }
}
