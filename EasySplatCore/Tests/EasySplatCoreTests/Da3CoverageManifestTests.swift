#if canImport(XCTest)
import XCTest
@testable import EasySplatCore

final class Da3CoverageManifestTests: XCTestCase {
    func testLoadDecodesSnakeCaseManifestFromBridge() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let manifestURL = root.appendingPathComponent("da3_coverage_manifest.json")
        try """
        {
          "mode": "direct",
          "requested_device": "mps",
          "selected_device": "mps",
          "model_subdir": "DA3-BASE",
          "fallback_model_subdir": "DA3-SMALL",
          "process_res": 504,
          "camera_type": "PINHOLE",
          "shared_camera": true,
          "max_points": 120000,
          "total_images": 2,
          "window_size": 2,
          "window_overlap": 0,
          "windows": [
            { "start": 0, "end": 2, "images": ["a.jpg", "b.jpg"] }
          ],
          "raw_point_sample_count": 4000,
          "fused_sparse_point_count": 3000,
          "final_observation_count": 6000,
          "mean_track_length": 2.0,
          "registered_image_count": 2,
          "native_colmap_export": true,
          "export_strategy": "native_colmap"
        }
        """.write(to: manifestURL, atomically: true, encoding: .utf8)

        let manifest = try Da3CoverageManifest.load(from: manifestURL)

        XCTAssertEqual(manifest.modelSubdirectory, "DA3-BASE")
        XCTAssertEqual(manifest.fallbackModelSubdirectory, "DA3-SMALL")
        XCTAssertEqual(manifest.processResolution, 504)
        XCTAssertEqual(manifest.finalObservationCount, 6_000)
        XCTAssertEqual(manifest.nativeColmapExport, true)
        XCTAssertEqual(manifest.exportStrategy, "native_colmap")
        XCTAssertTrue(manifest.sharedCamera)
        XCTAssertTrue(manifest.validationIssues(expectedMode: .direct, selectedImageCount: 2).isEmpty)
    }

    func testValidationAcceptsConsistentDirectManifest() {
        let manifest = Da3CoverageManifest(
            mode: "direct",
            requestedDevice: "mps",
            selectedDevice: "mps",
            modelSubdirectory: "DA3-BASE",
            fallbackModelSubdirectory: "DA3-SMALL",
            processResolution: 504,
            cameraType: "PINHOLE",
            sharedCamera: false,
            maxPoints: 120_000,
            totalImages: 4,
            windowSize: 4,
            windowOverlap: 0,
            windows: [
                .init(start: 0, end: 4, images: ["a.jpg", "b.jpg", "c.jpg", "d.jpg"])
            ],
            rawPointSampleCount: 10_000,
            fusedSparsePointCount: 6_000,
            finalObservationCount: 12_000,
            meanTrackLength: 2.0,
            registeredImageCount: 4,
            nativeColmapExport: true,
            exportStrategy: "native_colmap"
        )

        XCTAssertTrue(manifest.validationIssues(expectedMode: .direct, selectedImageCount: 4).isEmpty)
        XCTAssertTrue(manifest.summary.contains("model DA3-BASE"))
        XCTAssertTrue(manifest.summary.contains("mean track length 2.00"))
    }

    func testValidationRejectsInconsistentPointAndObservationCounts() {
        let manifest = Da3CoverageManifest(
            mode: "direct",
            requestedDevice: "mps",
            selectedDevice: "mps",
            modelSubdirectory: "DA3-BASE",
            fallbackModelSubdirectory: "DA3-SMALL",
            processResolution: 504,
            cameraType: "PINHOLE",
            sharedCamera: false,
            maxPoints: 120_000,
            totalImages: 4,
            windowSize: 4,
            windowOverlap: 0,
            windows: [
                .init(start: 0, end: 4, images: ["a.jpg", "b.jpg", "c.jpg", "d.jpg"])
            ],
            rawPointSampleCount: 5_000,
            fusedSparsePointCount: 6_000,
            finalObservationCount: 5_500,
            meanTrackLength: 0,
            registeredImageCount: 3,
            nativeColmapExport: false,
            exportStrategy: nil
        )

        let issues = manifest.validationIssues(expectedMode: .direct, selectedImageCount: 4)
        XCTAssertTrue(issues.contains(where: { $0.contains("registered_image_count") }))
        XCTAssertTrue(issues.contains(where: { $0.contains("raw_point_sample_count") }))
        XCTAssertTrue(issues.contains(where: { $0.contains("final_observation_count") }))
        XCTAssertTrue(issues.contains(where: { $0.contains("mean_track_length") }))
        XCTAssertTrue(issues.contains(where: { $0.contains("native_colmap_export") }))
    }

    func testValidationRejectsWindowedDirectColmapExportStrategy() {
        let manifest = Da3CoverageManifest(
            mode: "direct",
            requestedDevice: "mps",
            selectedDevice: "mps",
            modelSubdirectory: "DA3-BASE",
            fallbackModelSubdirectory: "DA3-SMALL",
            processResolution: 504,
            cameraType: "PINHOLE",
            sharedCamera: false,
            maxPoints: 120_000,
            totalImages: 5,
            windowSize: 2,
            windowOverlap: 1,
            windows: [
                .init(start: 0, end: 2, images: ["a.jpg", "b.jpg"]),
                .init(start: 1, end: 3, images: ["b.jpg", "c.jpg"]),
                .init(start: 2, end: 4, images: ["c.jpg", "d.jpg"]),
                .init(start: 3, end: 5, images: ["d.jpg", "e.jpg"])
            ],
            rawPointSampleCount: 10,
            fusedSparsePointCount: 10,
            finalObservationCount: 20,
            meanTrackLength: 2.0,
            registeredImageCount: 5,
            nativeColmapExport: false,
            exportStrategy: "windowed_direct_colmap"
        )

        let issues = manifest.validationIssues(expectedMode: .direct, selectedImageCount: 5)
        XCTAssertTrue(issues.contains(where: { $0.contains("native_colmap_export") }))
    }

    func testValidationAcceptsCompleteAlignedPoseSeedWithoutPointClaims() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let manifestURL = root.appendingPathComponent("da3_coverage_manifest.json")
        try """
        {
          "mode": "seed_refine",
          "requested_device": "mps",
          "selected_device": "mps",
          "model_subdir": "DA3-BASE",
          "fallback_model_subdir": "DA3-SMALL",
          "process_res": 504,
          "camera_type": "PINHOLE",
          "shared_camera": false,
          "max_points": 120000,
          "total_images": 7,
          "window_size": 4,
          "window_overlap": 3,
          "input_ordering": "continuous",
          "windows": [
            { "start": 0, "end": 4, "images": ["a.jpg", "b.jpg", "c.jpg", "d.jpg"], "indices": [0, 1, 2, 3] },
            { "start": 1, "end": 5, "images": ["b.jpg", "c.jpg", "d.jpg", "e.jpg"], "indices": [1, 2, 3, 4] },
            { "start": 2, "end": 6, "images": ["c.jpg", "d.jpg", "e.jpg", "f.jpg"], "indices": [2, 3, 4, 5] },
            { "start": 3, "end": 7, "images": ["d.jpg", "e.jpg", "f.jpg", "g.jpg"], "indices": [3, 4, 5, 6] }
          ],
          "registered_image_count": 7,
          "native_colmap_export": false,
          "export_strategy": "aligned_pose_seed",
          "anchor_image_names": ["a.jpg", "b.jpg", "c.jpg"],
          "alignment_edge_count": 3,
          "max_alignment_rmse": 0.018,
          "alignment_complete": true
        }
        """.write(to: manifestURL, atomically: true, encoding: .utf8)

        let manifest = try Da3CoverageManifest.load(from: manifestURL)
        XCTAssertEqual(manifest.inputOrdering, "continuous")
        XCTAssertEqual(manifest.alignmentEdgeCount, 3)
        XCTAssertEqual(manifest.maxAlignmentRMSE, 0.018)
        XCTAssertEqual(manifest.alignmentComplete, true)
        XCTAssertTrue(manifest.validationIssues(expectedMode: .seedRefine, selectedImageCount: 7).isEmpty)
        let pairs = manifest.boundedMatchPairs
        XCTAssertEqual(pairs.count, 15)
        XCTAssertTrue(pairs.contains("a.jpg d.jpg"))
        XCTAssertFalse(pairs.contains("a.jpg g.jpg"))
    }

    func testValidationRejectsIncompleteAlignedSeedAndFakePointCounts() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let manifestURL = root.appendingPathComponent("da3_coverage_manifest.json")
        try """
        {
          "mode": "seed_refine",
          "requested_device": "mps",
          "selected_device": "mps",
          "model_subdir": "DA3-BASE",
          "process_res": 504,
          "camera_type": "PINHOLE",
          "shared_camera": false,
          "max_points": 120000,
          "total_images": 5,
          "window_size": 4,
          "window_overlap": 3,
          "input_ordering": "unordered",
          "windows": [
            { "start": 0, "end": 4, "images": ["a.jpg", "b.jpg", "c.jpg", "d.jpg"], "indices": [0, 1, 2, 3] }
          ],
          "registered_image_count": 4,
          "native_colmap_export": false,
          "export_strategy": "aligned_pose_seed",
          "anchor_image_names": [],
          "alignment_edge_count": 0,
          "max_alignment_rmse": 0.0,
          "alignment_complete": false,
          "raw_point_sample_count": 10,
          "fused_sparse_point_count": 10,
          "final_observation_count": 20
        }
        """.write(to: manifestURL, atomically: true, encoding: .utf8)

        let manifest = try Da3CoverageManifest.load(from: manifestURL)
        let issues = manifest.validationIssues(expectedMode: .seedRefine, selectedImageCount: 5)
        XCTAssertTrue(issues.contains(where: { $0.contains("complete image coverage") }))
        XCTAssertTrue(issues.contains(where: { $0.contains("alignment_complete") }))
        XCTAssertTrue(issues.contains(where: { $0.contains("anchor_image_names") }))
        XCTAssertTrue(issues.contains(where: { $0.contains("must not claim sparse points") }))
    }
}
#endif
