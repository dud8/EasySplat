import XCTest
@testable import EasySplatCore

final class FrameExtractorLogicTests: XCTestCase {
    func testEffectiveTargetFPSUsesBaseWhenDurationZero() {
        let options = FrameExtractionOptions(targetCount: 100, maxDimension: 1024, targetFPS: 3)
        let fps = FrameExtractor.test_effectiveTargetFPS(options: options, duration: 0, videoFPS: 30)
        XCTAssertEqual(fps, 3)
    }

    func testEffectiveTargetFPSClampsToVideoFPS() {
        let options = FrameExtractionOptions(targetCount: 600, maxDimension: 1024, targetFPS: 2)
        let fps = FrameExtractor.test_effectiveTargetFPS(options: options, duration: 10, videoFPS: 24)
        XCTAssertEqual(fps, 24)
    }

    func testEffectiveTargetFPSHonorsTargetCount() {
        let options = FrameExtractionOptions(targetCount: 120, maxDimension: 1024, targetFPS: 2)
        let fps = FrameExtractor.test_effectiveTargetFPS(options: options, duration: 20, videoFPS: 30)
        XCTAssertEqual(fps, 6)
    }

    func testFrameOutputFormatMappings() {
        XCTAssertEqual(FrameOutputFormat.jpeg.fileExtension, "jpg")
        XCTAssertEqual(FrameOutputFormat.png.fileExtension, "png")
        XCTAssertEqual(FrameOutputFormat.jpeg.utType, .jpeg)
        XCTAssertEqual(FrameOutputFormat.png.utType, .png)
    }
}
