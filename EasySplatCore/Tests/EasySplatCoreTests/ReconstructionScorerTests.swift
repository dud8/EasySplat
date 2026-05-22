#if canImport(XCTest)
import XCTest
@testable import EasySplatCore

final class ReconstructionScorerTests: XCTestCase {
    func testParseModelAnalyzerOutput() {
        let sample = """
        Registered images: 120 / 200
        Points: 9876
        Observations: 43210
        Mean track length: 4.38
        Mean reprojection error: 1.23
        """
        let score = ReconstructionScorer.parseModelAnalyzerOutput(sample)
        XCTAssertEqual(score.registeredImages, 120)
        XCTAssertEqual(score.totalImages, 200)
        XCTAssertNotNil(score.meanReprojectionError)
        XCTAssertEqual(score.meanReprojectionError ?? 0, 1.23, accuracy: 0.01)
        XCTAssertEqual(score.pointCount, 9_876)
        XCTAssertEqual(score.observationCount, 43_210)
        XCTAssertEqual(score.meanTrackLength ?? 0, 4.38, accuracy: 0.01)
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
        let score = ReconstructionScore(
            registeredImages: 70,
            totalImages: 100,
            meanReprojectionError: 1.0,
            pointCount: 10_000,
            observationCount: 30_000,
            meanTrackLength: 3.0
        )
        XCTAssertTrue(ReconstructionScorer.isAcceptable(score, mode: .object))
        let low = ReconstructionScore(
            registeredImages: 40,
            totalImages: 100,
            meanReprojectionError: 1.0,
            pointCount: 10_000,
            observationCount: 30_000,
            meanTrackLength: 3.0
        )
        XCTAssertFalse(ReconstructionScorer.isAcceptable(low, mode: .object))
    }

    func testAcceptableRejectsTracklessSparseModel() {
        let score = ReconstructionScore(
            registeredImages: 70,
            totalImages: 100,
            meanReprojectionError: 1.0,
            pointCount: 10_000,
            observationCount: 0,
            meanTrackLength: 0.0
        )
        XCTAssertFalse(ReconstructionScorer.isAcceptable(score, mode: .object))
    }

    func testExpectedTotalImagesKeepsPartialSparseModelsFromPassing() {
        let sparseOnlyScore = ReconstructionScore(
            registeredImages: 5,
            totalImages: 5,
            meanReprojectionError: 0.8,
            pointCount: 12,
            observationCount: 36,
            meanTrackLength: 3.0
        )

        let adjusted = ReconstructionScorer.applyingExpectedTotalImages(
            sparseOnlyScore,
            expectedTotalImages: 60
        )

        XCTAssertEqual(adjusted.registeredImages, 5)
        XCTAssertEqual(adjusted.totalImages, 60)
        XCTAssertFalse(ReconstructionScorer.isAcceptable(adjusted, mode: .object))
    }

    func testParseSparseTextModelCountsFeedForwardOutputWithoutTracks() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try """
        # Camera list
        1 SIMPLE_PINHOLE 640 480 500 320 240
        """.write(to: root.appendingPathComponent("cameras.txt"), atomically: true, encoding: .utf8)

        try """
        # Image list with two lines per image:
        1 1 0 0 0 0 0 0 1 frame_000001.jpg

        2 1 0 0 0 1 0 0 1 frame_000002.jpg

        """.write(to: root.appendingPathComponent("images.txt"), atomically: true, encoding: .utf8)

        try """
        # Point list
        1 0 0 0 128 128 128 1.0
        2 1 0 0 128 128 128 1.0
        """.write(to: root.appendingPathComponent("points3D.txt"), atomically: true, encoding: .utf8)

        let score = try XCTUnwrap(ReconstructionScorer.parseSparseTextModel(
            at: root,
            expectedTotalImages: 2
        ))

        XCTAssertEqual(score.registeredImages, 2)
        XCTAssertEqual(score.totalImages, 2)
        XCTAssertEqual(score.pointCount, 2)
        XCTAssertNil(score.observationCount)
        XCTAssertNil(score.meanTrackLength)
        XCTAssertTrue(ReconstructionScorer.summary(score).contains("points 2"))
    }
}
#endif
