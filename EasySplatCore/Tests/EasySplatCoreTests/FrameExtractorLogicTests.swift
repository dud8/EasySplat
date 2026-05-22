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

    func testCappedExtractionSlotsCoverFullVideoDuration() {
        let options = FrameExtractionOptions(
            targetCount: 30,
            maxDimension: 960,
            targetFPS: 3,
            maxExtractedFrames: 40
        )

        let slots = FrameExtractor.test_cappedExtractionSlots(
            options: options,
            duration: 150,
            videoFPS: 30
        )

        XCTAssertEqual(slots.count, 40)
        XCTAssertGreaterThan(slots.first?.preferredTime ?? 0, 0)
        XCTAssertGreaterThan(slots.last?.preferredTime ?? 0, 145)
        XCTAssertTrue(zip(slots, slots.dropFirst()).allSatisfy { $0.preferredTime < $1.preferredTime })
        XCTAssertTrue(slots.allSatisfy { slot in
            slot.candidateTimes.allSatisfy { $0 >= 0 && $0 <= 150 }
        })
    }

    func testCappedCandidateIndicesUseVideoFrameScale() {
        let options = FrameExtractionOptions(
            targetCount: 40,
            maxDimension: 1280,
            targetFPS: 3,
            maxExtractedFrames: 54
        )

        let slots = FrameExtractor.test_cappedExtractionSlots(
            options: options,
            duration: 2,
            videoFPS: 30
        )
        let allIndices = slots.flatMap {
            FrameExtractor.test_cappedCandidateFrameIndices(for: $0, videoFPS: 30)
        }

        XCTAssertFalse(allIndices.isEmpty)
        XCTAssertEqual(slots.count, 54)
        XCTAssertTrue(allIndices.contains(0))
        XCTAssertTrue(allIndices.contains(59))
        XCTAssertTrue(allIndices.allSatisfy { $0 >= 0 && $0 <= 59 })
    }

}
