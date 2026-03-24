#if canImport(XCTest)
import XCTest
@testable import EasySplatCore

final class MapAnythingCoverageManifestTests: XCTestCase {
    func testValidationAcceptsConsistentDirectManifest() {
        let manifest = MapAnythingCoverageManifest(
            mode: "direct",
            requestedDevice: "mps",
            selectedDevice: "mps",
            resolution: 518,
            cameraType: "SIMPLE_RADIAL",
            sharedCamera: false,
            seed: 42,
            maxPoints: 120_000,
            totalImages: 4,
            anchorImageCount: 4,
            requestedWindowSize: 4,
            requestedWindowOverlap: 0,
            windowSize: 4,
            windowOverlap: 0,
            windowReductionCount: 0,
            anchors: ["a.jpg", "b.jpg", "c.jpg", "d.jpg"],
            windows: [
                .init(start: 0, end: 4, images: ["a.jpg", "b.jpg", "c.jpg", "d.jpg"])
            ],
            rawPointSampleCount: 10_000,
            fusedSparsePointCount: 6_000,
            finalObservationCount: 9_500,
            meanTrackLength: 1.58,
            registeredImageCount: 4
        )

        XCTAssertTrue(manifest.validationIssues(expectedMode: .direct, selectedImageCount: 4).isEmpty)
        XCTAssertTrue(manifest.summary.contains("mean track length 1.58"))
    }

    func testValidationRejectsModeAndTrackInconsistencies() {
        let manifest = MapAnythingCoverageManifest(
            mode: "seed_refine",
            requestedDevice: "mps",
            selectedDevice: "mps",
            resolution: 518,
            cameraType: "SIMPLE_RADIAL",
            sharedCamera: false,
            seed: 42,
            maxPoints: 120_000,
            totalImages: 4,
            anchorImageCount: 2,
            requestedWindowSize: 2,
            requestedWindowOverlap: 0,
            windowSize: 2,
            windowOverlap: 0,
            windowReductionCount: 0,
            anchors: ["a.jpg", "b.jpg"],
            windows: [
                .init(start: 0, end: 2, images: ["a.jpg", "b.jpg"])
            ],
            rawPointSampleCount: 100,
            fusedSparsePointCount: 120,
            finalObservationCount: 90,
            meanTrackLength: 0.0,
            registeredImageCount: 1
        )

        let issues = manifest.validationIssues(expectedMode: .direct, selectedImageCount: 4)
        XCTAssertTrue(issues.contains(where: { $0.contains("mode=") }))
        XCTAssertTrue(issues.contains(where: { $0.contains("anchor_image_count") }))
        XCTAssertTrue(issues.contains(where: { $0.contains("registered_image_count") }))
        XCTAssertTrue(issues.contains(where: { $0.contains("raw_point_sample_count") }))
        XCTAssertTrue(issues.contains(where: { $0.contains("final_observation_count") }))
        XCTAssertTrue(issues.contains(where: { $0.contains("mean_track_length") }))
    }
}
#endif
