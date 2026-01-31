#if canImport(XCTest)
import XCTest
@testable import EasySplatCore

final class LearnedMatchingLogProgressTests: XCTestCase {
    func testPairProgressParsesFraction() {
        let tracker = LearnedMatchingProgressTracker()
        let update = tracker.ingest("Processed 10/100 pairs")
        XCTAssertNotNil(update)
        XCTAssertEqual(update?.fraction ?? 0, 0.1, accuracy: 0.0001)
        XCTAssertEqual(update?.message, "Learned matching (10/100 pairs)")
    }

    func testCountsParsesImagesAndPairs() {
        let tracker = LearnedMatchingProgressTracker()
        let update = tracker.ingest("Image count: 50 | Pair count: 500")
        XCTAssertNotNil(update)
        XCTAssertEqual(update?.fraction ?? 1, 0.0, accuracy: 0.0001)
        XCTAssertEqual(update?.message, "Learned matching (50 images, 500 pairs)")
    }

    func testIgnoresUnrelatedLines() {
        let tracker = LearnedMatchingProgressTracker()
        XCTAssertNil(tracker.ingest("Some unrelated log line"))
    }
}
#endif

