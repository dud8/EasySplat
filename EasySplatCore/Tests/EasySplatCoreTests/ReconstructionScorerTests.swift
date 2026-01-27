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

    func testAcceptableThresholds() {
        let score = ReconstructionScore(registeredImages: 70, totalImages: 100, meanReprojectionError: 1.0)
        XCTAssertTrue(ReconstructionScorer.isAcceptable(score, mode: .object))
        let low = ReconstructionScore(registeredImages: 40, totalImages: 100, meanReprojectionError: 1.0)
        XCTAssertFalse(ReconstructionScorer.isAcceptable(low, mode: .object))
    }
}
