#if canImport(XCTest)
import XCTest
@testable import EasySplatCore

final class ColmapPairEstimatorTests: XCTestCase {
    func testExpectedSequentialPairs() {
        XCTAssertEqual(ColmapPairEstimator.expectedSequentialPairs(imageCount: 96, overlap: 10), 905)
    }

    func testExpectedExhaustivePairs() {
        XCTAssertEqual(ColmapPairEstimator.expectedExhaustivePairs(imageCount: 96), 4560)
    }
}
#endif

