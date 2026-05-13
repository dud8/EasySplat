import Foundation

struct Da3CoverageManifest: Codable, Sendable {
    struct Window: Codable, Sendable {
        var start: Int
        var end: Int
        var images: [String]
    }

    var mode: String
    var requestedDevice: String
    var selectedDevice: String
    var modelSubdirectory: String
    var fallbackModelSubdirectory: String?
    var processResolution: Int
    var cameraType: String
    var sharedCamera: Bool
    var maxPoints: Int
    var totalImages: Int
    var windowSize: Int
    var windowOverlap: Int
    var windows: [Window]
    var rawPointSampleCount: Int?
    var fusedSparsePointCount: Int?
    var finalObservationCount: Int?
    var meanTrackLength: Double?
    var registeredImageCount: Int?
    var nativeColmapExport: Bool?
    var exportStrategy: String?

    enum CodingKeys: String, CodingKey {
        case mode
        case requestedDevice = "requested_device"
        case selectedDevice = "selected_device"
        case modelSubdirectory = "model_subdir"
        case fallbackModelSubdirectory = "fallback_model_subdir"
        case processResolution = "process_res"
        case cameraType = "camera_type"
        case sharedCamera = "shared_camera"
        case maxPoints = "max_points"
        case totalImages = "total_images"
        case windowSize = "window_size"
        case windowOverlap = "window_overlap"
        case windows
        case rawPointSampleCount = "raw_point_sample_count"
        case fusedSparsePointCount = "fused_sparse_point_count"
        case finalObservationCount = "final_observation_count"
        case meanTrackLength = "mean_track_length"
        case registeredImageCount = "registered_image_count"
        case nativeColmapExport = "native_colmap_export"
        case exportStrategy = "export_strategy"
    }

    static func load(from url: URL) throws -> Da3CoverageManifest {
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(Da3CoverageManifest.self, from: data)
    }

    func validationIssues(expectedMode: Da3RunMode, selectedImageCount: Int) -> [String] {
        var issues: [String] = []
        if mode != expectedMode.rawValue {
            issues.append("mode=\(mode) did not match expected \(expectedMode.rawValue)")
        }
        if totalImages != selectedImageCount {
            issues.append("total_images=\(totalImages) did not match selected frames \(selectedImageCount)")
        }
        if windows.isEmpty {
            issues.append("windows list was empty")
        }
        for (index, window) in windows.enumerated() {
            if window.start < 0 || window.end <= window.start {
                issues.append("window[\(index)] had invalid range \(window.start)..<\(window.end)")
            }
            if window.end > selectedImageCount {
                issues.append("window[\(index)] end \(window.end) exceeded selected frames \(selectedImageCount)")
            }
            if window.images.count != max(0, window.end - window.start) {
                issues.append("window[\(index)] images count \(window.images.count) did not match range length \(max(0, window.end - window.start))")
            }
        }
        if expectedMode == .direct, let registeredImageCount, registeredImageCount != selectedImageCount {
            issues.append("direct mode expected registered_image_count=\(selectedImageCount), got \(registeredImageCount)")
        }
        if expectedMode == .direct,
           nativeColmapExport != true {
            issues.append("direct mode requires native_colmap_export=true")
        }
        if expectedMode == .direct,
           let exportStrategy,
           exportStrategy != "native_colmap" {
            issues.append("direct mode requires export_strategy=native_colmap")
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
        var parts = [
            "mode \(mode)",
            "model \(modelSubdirectory)",
            "windows \(windows.count)"
        ]
        if let registeredImageCount {
            parts.append("registered \(registeredImageCount)/\(totalImages)")
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
