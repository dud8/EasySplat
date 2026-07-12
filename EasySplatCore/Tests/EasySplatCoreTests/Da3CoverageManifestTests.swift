#if canImport(XCTest)
import XCTest
@testable import EasySplatCore

final class Da3CoverageManifestTests: XCTestCase {
    func testLoadRejectsSymlinkedManifest() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let outsideManifestURL = root.appendingPathComponent("outside.json")
        let manifestURL = root.appendingPathComponent("da3_coverage_manifest.json")
        let manifest = makeSeedManifest(
            selectedNames: ["a.jpg", "b.jpg", "c.jpg", "d.jpg"],
            ordering: .continuous,
            windows: [
                .init(
                    start: 0,
                    end: 4,
                    images: ["a.jpg", "b.jpg", "c.jpg", "d.jpg"],
                    indices: [0, 1, 2, 3]
                )
            ]
        )
        try JSONEncoder().encode(manifest).write(to: outsideManifestURL)
        try FileManager.default.createSymbolicLink(
            at: manifestURL,
            withDestinationURL: outsideManifestURL
        )

        XCTAssertThrowsError(try Da3CoverageManifest.load(from: manifestURL))
    }

    func testLoadRejectsManifestLargerThanEightMiB() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let manifestURL = root.appendingPathComponent("da3_coverage_manifest.json")
        let manifest = makeSeedManifest(
            selectedNames: ["a.jpg", "b.jpg", "c.jpg", "d.jpg"],
            ordering: .continuous,
            windows: [
                .init(
                    start: 0,
                    end: 4,
                    images: ["a.jpg", "b.jpg", "c.jpg", "d.jpg"],
                    indices: [0, 1, 2, 3]
                )
            ]
        )
        var data = try JSONEncoder().encode(manifest)
        data.append(Data(repeating: 0x20, count: 8 * 1_024 * 1_024))
        XCTAssertGreaterThan(data.count, 8 * 1_024 * 1_024)
        try data.write(to: manifestURL)

        XCTAssertThrowsError(try Da3CoverageManifest.load(from: manifestURL))
    }

    func testValidationAcceptsCompleteAlignedPoseAndDepthSeed() throws {
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
          "export_strategy": "aligned_pose_depth_seed",
          "anchor_image_names": ["a.jpg", "b.jpg", "c.jpg"],
          "alignment_edge_count": 3,
          "max_alignment_rmse": 0.018,
          "alignment_complete": true,
          "raw_point_sample_count": 20000,
          "fused_sparse_point_count": 12000
        }
        """.write(to: manifestURL, atomically: true, encoding: .utf8)

        let manifest = try Da3CoverageManifest.load(from: manifestURL)
        XCTAssertEqual(manifest.inputOrdering, "continuous")
        XCTAssertEqual(manifest.alignmentEdgeCount, 3)
        XCTAssertEqual(manifest.maxAlignmentRMSE, 0.018)
        XCTAssertEqual(manifest.alignmentComplete, true)
        let selectedNames = ["a.jpg", "b.jpg", "c.jpg", "d.jpg", "e.jpg", "f.jpg", "g.jpg"]
        XCTAssertTrue(manifest.validationIssues(
            selectedImageNames: selectedNames,
            expectedWindowSize: 4,
            expectedWindowOverlap: 3,
            expectedInputOrdering: .continuous
        ).isEmpty)
        let pairs = try XCTUnwrap(manifest.boundedMatchPairs)
        XCTAssertEqual(pairs.count, 15)
        XCTAssertTrue(pairs.contains("a.jpg d.jpg"))
        XCTAssertFalse(pairs.contains("a.jpg g.jpg"))
    }

    func testValidationRejectsObsoleteDirectMode() {
        let selected = ["a.jpg", "b.jpg", "c.jpg", "d.jpg"]
        var manifest = makeSeedManifest(
            selectedNames: selected,
            ordering: .continuous,
            windows: [
                .init(start: 0, end: 4, images: selected, indices: [0, 1, 2, 3])
            ]
        )
        manifest.mode = "direct"

        let issues = manifest.validationIssues(
            selectedImageNames: selected,
            expectedWindowSize: 4,
            expectedWindowOverlap: 3,
            expectedInputOrdering: .continuous
        )

        XCTAssertTrue(issues.contains(where: { $0.contains("required seed_refine") }))
    }

    func testSeedValidationAcceptsTwoViewSingleWindowAnchors() {
        let selected = ["a.jpg", "b.jpg"]
        var manifest = makeSeedManifest(
            selectedNames: selected,
            ordering: .unordered,
            windows: [
                .init(start: 0, end: 2, images: selected, indices: [0, 1])
            ]
        )
        manifest.windowSize = 2
        manifest.windowOverlap = 1

        let issues = manifest.validationIssues(
            selectedImageNames: selected,
            expectedWindowSize: 4,
            expectedWindowOverlap: 3,
            expectedInputOrdering: .unordered
        )

        XCTAssertTrue(issues.isEmpty, issues.joined(separator: "\n"))
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
          "export_strategy": "aligned_pose_depth_seed",
          "anchor_image_names": [],
          "alignment_edge_count": 0,
          "max_alignment_rmse": 0.0,
          "alignment_complete": false,
          "raw_point_sample_count": 5,
          "fused_sparse_point_count": 10,
          "final_observation_count": 20
        }
        """.write(to: manifestURL, atomically: true, encoding: .utf8)

        let manifest = try Da3CoverageManifest.load(from: manifestURL)
        let issues = manifest.validationIssues(
            selectedImageNames: ["a.jpg", "b.jpg", "c.jpg", "d.jpg", "e.jpg"],
            expectedWindowSize: 4,
            expectedWindowOverlap: 3,
            expectedInputOrdering: .unordered
        )
        XCTAssertTrue(issues.contains(where: { $0.contains("complete image coverage") }))
        XCTAssertTrue(issues.contains(where: { $0.contains("alignment_complete") }))
        XCTAssertTrue(issues.contains(where: { $0.contains("anchor_image_names") }))
        XCTAssertTrue(issues.contains(where: { $0.contains("cannot exceed raw") }))
    }

    func testSeedValidationRejectsOversizedWindowAndNameIndexMismatch() {
        let selected = ["a.jpg", "b.jpg", "c.jpg", "d.jpg", "e.jpg"]
        var manifest = makeSeedManifest(
            selectedNames: selected,
            ordering: .continuous,
            windows: [
                .init(start: 0, end: 5, images: selected, indices: [0, 1, 2, 3, 4])
            ]
        )
        manifest.windowSize = 4
        manifest.windows[0].images = ["b.jpg", "a.jpg", "c.jpg", "d.jpg", "e.jpg"]

        let issues = manifest.validationIssues(
            selectedImageNames: selected,
            expectedWindowSize: 4,
            expectedWindowOverlap: 3,
            expectedInputOrdering: .continuous
        )
        XCTAssertTrue(issues.contains(where: { $0.contains("exceeded window_size") }))
        XCTAssertTrue(issues.contains(where: { $0.contains("name/index mapping") }))
    }

    func testSeedValidationRejectsCorruptExplicitIndexRange() {
        let selected = ["a.jpg", "b.jpg", "c.jpg", "d.jpg", "e.jpg"]
        let manifest = makeSeedManifest(
            selectedNames: selected,
            ordering: .continuous,
            windows: [
                .init(
                    start: 0,
                    end: 4,
                    images: [selected[0], selected[1], selected[2], selected[4]],
                    indices: [0, 1, 2, 4]
                )
            ]
        )

        let issues = manifest.validationIssues(
            selectedImageNames: selected,
            expectedWindowSize: 4,
            expectedWindowOverlap: 3,
            expectedInputOrdering: .continuous
        )
        XCTAssertTrue(issues.contains(where: { $0.contains("range did not bound indices") }))
    }

    func testSeedValidationRejectsDisconnectedContinuousWindows() {
        let selected = (0..<8).map { "img\($0).jpg" }
        let manifest = makeSeedManifest(
            selectedNames: selected,
            ordering: .continuous,
            windows: [
                .init(start: 0, end: 4, images: Array(selected[0..<4]), indices: [0, 1, 2, 3]),
                .init(start: 4, end: 8, images: Array(selected[4..<8]), indices: [4, 5, 6, 7])
            ]
        )

        let issues = manifest.validationIssues(
            selectedImageNames: selected,
            expectedWindowSize: 4,
            expectedWindowOverlap: 3,
            expectedInputOrdering: .continuous
        )
        XCTAssertTrue(issues.contains(where: { $0.contains("continuous overlap") }))
    }

    func testSeedValidationAcceptsUnorderedChainWithoutFirstWindowAnchors() {
        let selected = (0..<8).map { "img\($0).jpg" }
        var manifest = makeSeedManifest(
            selectedNames: selected,
            ordering: .unordered,
            windows: [
                .init(start: 0, end: 4, images: Array(selected[0..<4]), indices: [0, 1, 2, 3]),
                .init(start: 2, end: 6, images: Array(selected[2..<6]), indices: [2, 3, 4, 5]),
                .init(start: 4, end: 8, images: Array(selected[4..<8]), indices: [4, 5, 6, 7])
            ]
        )
        manifest.windowOverlap = 2
        manifest.anchorImageNames = [selected[0], selected[1], selected[2], selected[3], selected[4], selected[5]]

        let issues = manifest.validationIssues(
            selectedImageNames: selected,
            expectedWindowSize: 4,
            expectedWindowOverlap: 2,
            expectedInputOrdering: .unordered
        )
        XCTAssertTrue(issues.isEmpty, issues.joined(separator: "\n"))
    }

    func testSeedValidationRejectsDisconnectedUnorderedWindows() {
        let selected = (0..<8).map { "img\($0).jpg" }
        var manifest = makeSeedManifest(
            selectedNames: selected,
            ordering: .unordered,
            windows: [
                .init(start: 0, end: 4, images: Array(selected[0..<4]), indices: [0, 1, 2, 3]),
                .init(start: 4, end: 8, images: Array(selected[4..<8]), indices: [4, 5, 6, 7])
            ]
        )
        manifest.windowOverlap = 2

        let issues = manifest.validationIssues(
            selectedImageNames: selected,
            expectedWindowSize: 4,
            expectedWindowOverlap: 2,
            expectedInputOrdering: .unordered
        )
        XCTAssertTrue(issues.contains(where: { $0.contains("unordered overlap") }))
    }

    func testTrustedPairLimitAccountsForTwoViewConstrainedOverlap() {
        let limit = Da3CoverageManifest.trustedMatchPairLimit(
            selectedImageCount: 250,
            windowSize: 4,
            windowOverlap: 2,
            inputOrdering: .unordered
        )

        XCTAssertEqual(limit, 744)
    }

    func testConstrainedContinuousValidationKeepsGlobalAnchorsWhileEdgesUseTwoViews() {
        for imageCount in [5, 6, 7, 30] {
            let selected = (0..<imageCount).map { "img\($0).jpg" }
            var windows: [Da3CoverageManifest.Window] = []
            var start = 0
            while start < imageCount {
                let end = min(start + 4, imageCount)
                let indices = Array(start..<end)
                windows.append(.init(
                    start: start,
                    end: end,
                    images: indices.map { selected[$0] },
                    indices: indices
                ))
                if end == imageCount { break }
                start += 2
            }
            var manifest = makeSeedManifest(
                selectedNames: selected,
                ordering: .continuous,
                windows: windows
            )
            manifest.windowOverlap = 3
            manifest.anchorImageNames = Array(selected.prefix(3))
            manifest.alignmentEdgeCount = windows.count - 1

            let issues = manifest.validationIssues(
                selectedImageNames: selected,
                expectedWindowSize: 4,
                expectedWindowOverlap: 3,
                expectedInputOrdering: .continuous
            )

            XCTAssertTrue(issues.isEmpty, "\(imageCount) images: \(issues.joined(separator: "; "))")
        }
    }

    func testSeedValidationEnforcesHardMatchPairLimit() {
        let selected = (0..<500).map { "img\($0).jpg" }
        var manifest = makeSeedManifest(
            selectedNames: selected,
            ordering: .continuous,
            windows: [
                .init(start: 0, end: selected.count, images: selected, indices: Array(selected.indices))
            ]
        )
        manifest.windowSize = selected.count

        let issues = manifest.validationIssues(
            selectedImageNames: selected,
            expectedWindowSize: selected.count,
            expectedWindowOverlap: 3,
            expectedInputOrdering: .continuous
        )
        XCTAssertTrue(issues.contains(where: { $0.contains("hard limit") }))
    }

    func testSeedValidationBindsManifestToTrustedRunPlan() {
        let selected = (0..<250).map { "img\($0).jpg" }
        var manifest = makeSeedManifest(
            selectedNames: selected,
            ordering: .continuous,
            windows: [
                .init(
                    start: 0,
                    end: selected.count,
                    images: selected,
                    indices: Array(selected.indices)
                )
            ]
        )
        manifest.windowSize = selected.count
        manifest.windowOverlap = selected.count - 1

        let issues = manifest.validationIssues(
            selectedImageNames: selected,
            expectedWindowSize: 4,
            expectedWindowOverlap: 3,
            expectedInputOrdering: .continuous
        )

        XCTAssertTrue(issues.contains(where: { $0.contains("window_size") && $0.contains("expected 4") }))
        XCTAssertTrue(issues.contains(where: { $0.contains("window_overlap") && $0.contains("expected 3") }))
        XCTAssertTrue(issues.contains(where: { $0.contains("trusted match pair limit") }))
    }

    func testValidationBindsModelAndCameraConfigurationToInvocation() {
        let selected = ["a.jpg", "b.jpg", "c.jpg", "d.jpg"]
        var manifest = makeSeedManifest(
            selectedNames: selected,
            ordering: .continuous,
            windows: [
                .init(start: 0, end: 4, images: selected, indices: [0, 1, 2, 3])
            ]
        )
        manifest.modelSubdirectory = "DA3-SMALL"
        manifest.fallbackModelSubdirectory = "DA3-TINY"
        manifest.processResolution = 392
        manifest.maxPoints = 60_000
        manifest.cameraType = "SIMPLE_RADIAL"

        let issues = manifest.validationIssues(
            selectedImageNames: selected,
            expectedWindowSize: 4,
            expectedWindowOverlap: 3,
            expectedInputOrdering: .continuous,
            expectedProcessResolution: 504,
            expectedMaxPoints: 120_000,
            expectedCameraType: "PINHOLE",
            expectedSharedCamera: true,
            expectedPrimaryModelSubdirectory: "DA3-BASE",
            expectedFallbackModelSubdirectory: "DA3-SMALL"
        )

        XCTAssertTrue(issues.contains(where: { $0.contains("process_res=392") }))
        XCTAssertTrue(issues.contains(where: { $0.contains("max_points=60000") }))
        XCTAssertTrue(issues.contains(where: { $0.contains("camera_type=SIMPLE_RADIAL") }))
        XCTAssertTrue(issues.contains(where: { $0.contains("shared_camera=false") }))
        XCTAssertTrue(issues.contains(where: { $0.contains("fallback_model_subdir=DA3-TINY") }))
    }

    private func makeSeedManifest(
        selectedNames: [String],
        ordering: InputOrdering,
        windows: [Da3CoverageManifest.Window]
    ) -> Da3CoverageManifest {
        Da3CoverageManifest(
            mode: "seed_refine",
            requestedDevice: "mps",
            selectedDevice: "mps",
            modelSubdirectory: "DA3-BASE",
            fallbackModelSubdirectory: "DA3-SMALL",
            processResolution: 504,
            cameraType: "PINHOLE",
            sharedCamera: false,
            maxPoints: 120_000,
            totalImages: selectedNames.count,
            windowSize: 4,
            windowOverlap: 3,
            windows: windows,
            rawPointSampleCount: max(1, selectedNames.count * 16),
            fusedSparsePointCount: max(1, selectedNames.count * 8),
            finalObservationCount: nil,
            meanTrackLength: nil,
            registeredImageCount: selectedNames.count,
            nativeColmapExport: false,
            exportStrategy: "aligned_pose_depth_seed",
            inputOrdering: ordering.rawValue,
            anchorImageNames: Array(selectedNames.prefix(3)),
            alignmentEdgeCount: max(0, windows.count - 1),
            maxAlignmentRMSE: 0.01,
            alignmentComplete: true
        )
    }
}
#endif
