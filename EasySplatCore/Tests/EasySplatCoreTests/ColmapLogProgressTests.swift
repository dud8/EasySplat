#if canImport(XCTest)
import XCTest
@testable import EasySplatCore

final class ColmapLogProgressTests: XCTestCase {
    func testFeatureProgressParsesProcessedFile() {
        let tracker = ColmapFeatureProgressTracker()

        XCTAssertNil(tracker.ingest("Unrelated line"))

        guard let update = tracker.ingest("I20260128 22:06:39.220674 feature_extraction.cc:257] Processed file [65/96]") else {
            XCTFail("Expected feature progress update")
            return
        }
        XCTAssertEqual(update.message, "Finding features (65/96)")
        XCTAssertEqual(update.fraction, 65.0 / 96.0, accuracy: 0.0001)
    }

    func testMatchingProgressIncreasesWithBlocks() {
        let tracker = ColmapMatchingProgressTracker()

        guard let step1 = tracker.ingest("I20260128 22:06:52.960593 pairing.cc:213] Processing block [1/5, 1/5]") else {
            XCTFail("Expected matching progress update")
            return
        }
        XCTAssertEqual(step1.message, "Matching views (block 1/25, tile 1/5 x 1/5)")
        XCTAssertEqual(step1.fraction, 1.0 / 25.0, accuracy: 0.0001)

        guard let step2 = tracker.ingest("I20260128 22:06:52.960593 pairing.cc:213] Processing block [1/5, 2/5]") else {
            XCTFail("Expected matching progress update")
            return
        }
        XCTAssertEqual(step2.message, "Matching views (block 2/25, tile 1/5 x 2/5)")
        XCTAssertEqual(step2.fraction, 2.0 / 25.0, accuracy: 0.0001)

        XCTAssertNil(tracker.ingest("I20260128 22:06:52.960593 pairing.cc:213] Processing block [1/5, 2/5]"))

        guard let final = tracker.ingest("I20260129 02:04:14.442403 pairing.cc:213] Processing block [5/5, 5/5]") else {
            XCTFail("Expected matching progress update")
            return
        }
        XCTAssertEqual(final.message, "Matching views (block 25/25, tile 5/5 x 5/5)")
        XCTAssertEqual(final.fraction, 0.99, accuracy: 0.0001)
    }

    func testMappingProgressTracksRegisteredImages() {
        let tracker = ColmapMappingProgressTracker(totalImages: 96)

        guard let first = tracker.ingest("Registering image #76 (num_reg_frames=2)") else {
            XCTFail("Expected mapping progress update")
            return
        }
        XCTAssertEqual(first.message, "Solving cameras (2/96 registered)")
        XCTAssertEqual(first.fraction, 2.0 / 96.0, accuracy: 0.0001)

        XCTAssertNil(tracker.ingest("Registering image #76 (num_reg_frames=2)"))

        guard let done = tracker.ingest("Keeping successful reconstruction") else {
            XCTFail("Expected mapping progress update")
            return
        }
        XCTAssertEqual(done.message, "Solving cameras (finalizing reconstruction)")
        XCTAssertEqual(done.fraction, 0.99, accuracy: 0.0001)
    }

    func testMappingProgressCountsEveryGlobalRefinementMarker() {
        let tracker = ColmapMappingProgressTracker(totalImages: 250)

        for index in 0..<4 {
            XCTAssertNil(tracker.ingest(
                "I20260713 00:10:\(20 + index).000 incremental_pipeline.cc:78] Retriangulation and Global bundle adjustment"
            ))
        }

        XCTAssertEqual(tracker.globalRefinementCycleCount, 4)
    }

    func testMappingProgressIgnoresLocalAndUnrelatedBundleAdjustmentLogs() {
        let tracker = ColmapMappingProgressTracker(totalImages: 250)

        XCTAssertNil(tracker.ingest("Running local bundle adjustment"))
        XCTAssertNil(tracker.ingest("Global bundle adjustment"))
        XCTAssertNil(tracker.ingest("Retriangulation and global bundle adjustment"))

        XCTAssertEqual(tracker.globalRefinementCycleCount, 0)
    }

    func testMappingProgressCountsRepeatedGlobalRefinementMarkers() {
        let tracker = ColmapMappingProgressTracker(totalImages: 250)
        let marker = "Retriangulation and Global bundle adjustment"

        XCTAssertNil(tracker.ingest(marker))
        XCTAssertNil(tracker.ingest(marker))

        XCTAssertEqual(tracker.globalRefinementCycleCount, 2)
    }

    func testMappingProgressCountsGlobalRefinementMarkersConcurrently() {
        let tracker = ColmapMappingProgressTracker(totalImages: 250)
        let markerCount = 256

        DispatchQueue.concurrentPerform(iterations: markerCount) { index in
            let line = index.isMultiple(of: 2)
                ? "Retriangulation and Global bundle adjustment"
                : "prefix Retriangulation and Global bundle adjustment suffix"
            _ = tracker.ingest(line)
        }

        XCTAssertEqual(tracker.globalRefinementCycleCount, markerCount)
    }
}
#endif
