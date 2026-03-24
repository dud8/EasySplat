import Foundation

struct MapAnythingCoverageManifest: Codable, Sendable {
    struct Window: Codable, Sendable {
        var start: Int
        var end: Int
        var images: [String]
    }

    var mode: String
    var requestedDevice: String
    var selectedDevice: String
    var resolution: Int
    var cameraType: String
    var sharedCamera: Bool
    var seed: Int
    var maxPoints: Int
    var totalImages: Int
    var anchorImageCount: Int
    var requestedWindowSize: Int
    var requestedWindowOverlap: Int
    var windowSize: Int
    var windowOverlap: Int
    var windowReductionCount: Int
    var anchors: [String]
    var windows: [Window]
    var rawPointSampleCount: Int?
    var fusedSparsePointCount: Int?
    var finalObservationCount: Int?
    var meanTrackLength: Double?
    var registeredImageCount: Int?

    enum CodingKeys: String, CodingKey {
        case mode
        case requestedDevice = "requested_device"
        case selectedDevice = "selected_device"
        case resolution
        case cameraType = "camera_type"
        case sharedCamera = "shared_camera"
        case seed
        case maxPoints = "max_points"
        case totalImages = "total_images"
        case anchorImageCount = "anchor_image_count"
        case requestedWindowSize = "requested_window_size"
        case requestedWindowOverlap = "requested_window_overlap"
        case windowSize = "window_size"
        case windowOverlap = "window_overlap"
        case windowReductionCount = "window_reduction_count"
        case anchors
        case windows
        case rawPointSampleCount = "raw_point_sample_count"
        case fusedSparsePointCount = "fused_sparse_point_count"
        case finalObservationCount = "final_observation_count"
        case meanTrackLength = "mean_track_length"
        case registeredImageCount = "registered_image_count"
    }

    static func load(from url: URL) throws -> MapAnythingCoverageManifest {
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(MapAnythingCoverageManifest.self, from: data)
    }

    func validationIssues(expectedMode: MapAnythingRunMode, selectedImageCount: Int) -> [String] {
        var issues: [String] = []

        if mode != expectedMode.rawValue {
            issues.append("mode=\(mode) did not match expected \(expectedMode.rawValue)")
        }
        if totalImages != selectedImageCount {
            issues.append("total_images=\(totalImages) did not match selected frames \(selectedImageCount)")
        }
        if anchorImageCount != anchors.count {
            issues.append("anchor_image_count=\(anchorImageCount) did not match anchors list count \(anchors.count)")
        }
        if anchorImageCount <= 0 {
            issues.append("anchor_image_count must be > 0")
        }
        if windows.isEmpty {
            issues.append("windows list was empty")
        }
        for (index, window) in windows.enumerated() {
            if window.start < 0 || window.end <= window.start {
                issues.append("window[\(index)] had invalid range \(window.start)..<\(window.end)")
            }
            if window.end > anchors.count {
                issues.append("window[\(index)] end \(window.end) exceeded anchor count \(anchors.count)")
            }
            if window.images.count != max(0, window.end - window.start) {
                issues.append(
                    "window[\(index)] images count \(window.images.count) did not match range length \(max(0, window.end - window.start))"
                )
            }
        }

        switch expectedMode {
        case .direct:
            if anchorImageCount != selectedImageCount {
                issues.append("direct mode expected anchor_image_count to equal selected frames")
            }
            if windows.count != 1 {
                issues.append("direct mode expected exactly 1 window")
            }
            if let registeredImageCount, registeredImageCount != selectedImageCount {
                issues.append("direct mode expected registered_image_count=\(selectedImageCount), got \(registeredImageCount)")
            }
        case .seedRefine:
            if anchorImageCount > selectedImageCount {
                issues.append("seed_refine anchor_image_count exceeded selected frames")
            }
            if let registeredImageCount, registeredImageCount != anchorImageCount {
                issues.append("seed_refine expected registered_image_count=\(anchorImageCount), got \(registeredImageCount)")
            }
        }

        if let rawPointSampleCount, rawPointSampleCount <= 0 {
            issues.append("raw_point_sample_count must be > 0")
        }
        if let fusedSparsePointCount, fusedSparsePointCount <= 0 {
            issues.append("fused_sparse_point_count must be > 0")
        }
        if let finalObservationCount, finalObservationCount <= 0 {
            issues.append("final_observation_count must be > 0")
        }
        if let rawPointSampleCount, let fusedSparsePointCount, rawPointSampleCount < fusedSparsePointCount {
            issues.append("raw_point_sample_count \(rawPointSampleCount) was smaller than fused_sparse_point_count \(fusedSparsePointCount)")
        }
        if let fusedSparsePointCount, let finalObservationCount, finalObservationCount < fusedSparsePointCount {
            issues.append("final_observation_count \(finalObservationCount) was smaller than fused_sparse_point_count \(fusedSparsePointCount)")
        }
        if let meanTrackLength, !meanTrackLength.isFinite || meanTrackLength <= 0 {
            issues.append("mean_track_length must be a positive finite number")
        }

        return issues
    }

    var summary: String {
        var parts: [String] = [
            "mode \(mode)",
            "anchors \(anchorImageCount)/\(totalImages)",
            "windows \(windows.count)",
            "reductions \(windowReductionCount)"
        ]
        if let registeredImageCount {
            parts.append("registered \(registeredImageCount)")
        }
        if let fusedSparsePointCount {
            parts.append("points \(fusedSparsePointCount)")
        }
        if let finalObservationCount {
            parts.append("observations \(finalObservationCount)")
        }
        if let meanTrackLength {
            parts.append("mean track length \(String(format: "%.2f", meanTrackLength))")
        }
        return parts.joined(separator: ", ")
    }
}
