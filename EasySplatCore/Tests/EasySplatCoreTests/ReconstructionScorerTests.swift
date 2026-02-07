#if canImport(XCTest)
import XCTest
@testable import EasySplatCore

final class ReconstructionScorerTests: XCTestCase {
    func testParseModelAnalyzerOutput() {
        let sample = """
        Registered images: 120 / 200
        Mean reprojection error: 1.23
        """
        let score = ReconstructionScorer.parseModelAnalyzerOutput(sample)
        XCTAssertEqual(score.registeredImages, 120)
        XCTAssertEqual(score.totalImages, 200)
        XCTAssertNotNil(score.meanReprojectionError)
        XCTAssertEqual(score.meanReprojectionError ?? 0, 1.23, accuracy: 0.01)
    }

    func testParseModelAnalyzerOutputMissingReprojection() {
        let sample = """
        Registered images: 10 / 20
        """
        let score = ReconstructionScorer.parseModelAnalyzerOutput(sample)
        XCTAssertEqual(score.registeredImages, 10)
        XCTAssertEqual(score.totalImages, 20)
        XCTAssertNil(score.meanReprojectionError)
    }

    func testParseModelAnalyzerOutputWithGlogPrefixAndSplitCounts() {
        let sample = """
        I20260207 16:43:09.118649 1624963 model.cc:455] Registered images: 3
        I20260207 16:43:09.118650 1624963 model.cc:456] Images: 298
        I20260207 16:43:09.118651 1624963 model.cc:457] Mean reprojection error: 1.44
        """
        let score = ReconstructionScorer.parseModelAnalyzerOutput(sample)
        XCTAssertEqual(score.registeredImages, 3)
        XCTAssertEqual(score.totalImages, 298)
        XCTAssertEqual(score.meanReprojectionError ?? 0, 1.44, accuracy: 0.01)
    }

    func testParseModelAnalyzerOutputIgnoresTimestampDigits() {
        let sample = """
        I20260207 16:43:09.118649 1624963 model.cc:455] Registered images: 120 / 200
        I20260207 16:43:09.118651 1624963 model.cc:457] Mean reprojection error: 0.98
        """
        let score = ReconstructionScorer.parseModelAnalyzerOutput(sample)
        XCTAssertEqual(score.registeredImages, 120)
        XCTAssertEqual(score.totalImages, 200)
        XCTAssertEqual(score.meanReprojectionError ?? 0, 0.98, accuracy: 0.01)
    }

    func testAcceptableThresholds() {
        let score = ReconstructionScore(registeredImages: 70, totalImages: 100, meanReprojectionError: 1.0)
        XCTAssertTrue(ReconstructionScorer.isAcceptable(score, mode: .object))
        let low = ReconstructionScore(registeredImages: 40, totalImages: 100, meanReprojectionError: 1.0)
        XCTAssertFalse(ReconstructionScorer.isAcceptable(low, mode: .object))
    }
}
#endif
