import Foundation

struct Da3CoverageManifest: Codable, Sendable {
    static let hardMatchPairLimit = 100_000

    struct Window: Codable, Sendable {
        var start: Int
        var end: Int
        var images: [String]
        var indices: [Int]? = nil
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
    var inputOrdering: String? = nil
    var anchorImageNames: [String]? = nil
    var alignmentEdgeCount: Int? = nil
    var maxAlignmentRMSE: Double? = nil
    var alignmentComplete: Bool? = nil

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
        case inputOrdering = "input_ordering"
        case anchorImageNames = "anchor_image_names"
        case alignmentEdgeCount = "alignment_edge_count"
        case maxAlignmentRMSE = "max_alignment_rmse"
        case alignmentComplete = "alignment_complete"
    }

    static func load(from url: URL) throws -> Da3CoverageManifest {
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(Da3CoverageManifest.self, from: data)
    }

    func validationIssues(
        expectedMode: Da3RunMode,
        selectedImageNames: [String],
        expectedWindowSize: Int? = nil,
        expectedWindowOverlap: Int? = nil,
        expectedInputOrdering: InputOrdering? = nil
    ) -> [String] {
        var issues: [String] = []
        let selectedImageCount = selectedImageNames.count
        if mode != expectedMode.rawValue {
            issues.append("mode=\(mode) did not match expected \(expectedMode.rawValue)")
        }
        if totalImages != selectedImageCount {
            issues.append("total_images=\(totalImages) did not match selected frames \(selectedImageCount)")
        }
        if windows.isEmpty {
            issues.append("windows list was empty")
        }
        if windowSize <= 0 {
            issues.append("window_size must be positive")
        }
        if Set(selectedImageNames).count != selectedImageNames.count {
            issues.append("selected image names were not unique")
        }
        var resolvedWindowIndices: [[Int]] = []
        for (index, window) in windows.enumerated() {
            if window.start < 0 || window.end <= window.start {
                issues.append("window[\(index)] had invalid range \(window.start)..<\(window.end)")
            }
            if window.end > selectedImageCount {
                issues.append("window[\(index)] end \(window.end) exceeded selected frames \(selectedImageCount)")
            }
            if window.images.count > windowSize {
                issues.append("window[\(index)] image count \(window.images.count) exceeded window_size \(windowSize)")
            }
            if let indices = window.indices {
                if indices.count != window.images.count {
                    issues.append("window[\(index)] indices count \(indices.count) did not match images count \(window.images.count)")
                }
                if Set(indices).count != indices.count {
                    issues.append("window[\(index)] contained duplicate image indices")
                }
                if indices.contains(where: { $0 < 0 || $0 >= selectedImageCount }) {
                    issues.append("window[\(index)] contained an out-of-range image index")
                }
                if let minimumIndex = indices.min(),
                   let maximumIndex = indices.max(),
                   (window.start != minimumIndex || window.end != maximumIndex + 1) {
                    issues.append("window[\(index)] range did not bound indices")
                }
                resolvedWindowIndices.append(indices)
            } else if window.images.count != max(0, window.end - window.start) {
                issues.append("window[\(index)] images count \(window.images.count) did not match range length \(max(0, window.end - window.start))")
                resolvedWindowIndices.append([])
            } else {
                let rangeIndices = window.start >= 0 && window.end <= selectedImageCount && window.end >= window.start
                    ? Array(window.start..<window.end)
                    : []
                resolvedWindowIndices.append(rangeIndices)
            }
            let mappedIndices = resolvedWindowIndices.last ?? []
            if mappedIndices.count == window.images.count {
                for (position, imageIndex) in mappedIndices.enumerated() where selectedImageNames.indices.contains(imageIndex) {
                    if selectedImageNames[imageIndex] != window.images[position] {
                        issues.append("window[\(index)] name/index mapping did not match selected image order")
                        break
                    }
                }
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
        if expectedMode == .seedRefine {
            let trustedPairLimit: Int?
            if let expectedWindowSize,
               let expectedWindowOverlap,
               let expectedInputOrdering {
                if windowSize != expectedWindowSize {
                    issues.append("seed_refine window_size=\(windowSize) did not match expected \(expectedWindowSize)")
                }
                if windowOverlap != expectedWindowOverlap {
                    issues.append("seed_refine window_overlap=\(windowOverlap) did not match expected \(expectedWindowOverlap)")
                }
                if inputOrdering != expectedInputOrdering.rawValue {
                    issues.append("seed_refine input_ordering=\(inputOrdering ?? "missing") did not match expected \(expectedInputOrdering.rawValue)")
                }
                trustedPairLimit = Self.trustedMatchPairLimit(
                    selectedImageCount: selectedImageCount,
                    windowSize: expectedWindowSize,
                    windowOverlap: expectedWindowOverlap,
                    inputOrdering: expectedInputOrdering
                )
                if trustedPairLimit == nil {
                    issues.append("seed_refine trusted run plan could not produce a valid match pair limit")
                }
            } else {
                trustedPairLimit = nil
                issues.append("seed_refine validation requires a trusted window size, overlap, and input ordering")
            }
            if nativeColmapExport != false {
                issues.append("seed_refine requires native_colmap_export=false")
            }
            if exportStrategy != "aligned_pose_seed" {
                issues.append("seed_refine requires export_strategy=aligned_pose_seed")
            }
            if registeredImageCount != selectedImageCount {
                issues.append("seed_refine requires complete image coverage: registered_image_count must equal \(selectedImageCount)")
            }
            let coveredIndices = resolvedWindowIndices.reduce(into: Set<Int>()) { partial, indices in
                partial.formUnion(indices)
            }
            if coveredIndices != Set(selectedImageNames.indices) {
                issues.append("seed_refine requires complete image coverage across windows")
            }
            let coveredImages = Set(windows.flatMap(\.images))
            let anchors = anchorImageNames ?? []
            if anchors.count < 3 || Set(anchors).count != anchors.count {
                issues.append("seed_refine requires at least three distinct anchor_image_names")
            } else if !Set(anchors).isSubset(of: coveredImages) {
                issues.append("seed_refine anchor_image_names must belong to covered images")
            }
            if inputOrdering != InputOrdering.continuous.rawValue,
               inputOrdering != InputOrdering.unordered.rawValue {
                issues.append("seed_refine input_ordering must resolve to continuous or unordered")
            }
            if inputOrdering == InputOrdering.continuous.rawValue {
                var seen = Set<Int>()
                for (index, indices) in resolvedWindowIndices.enumerated() {
                    let current = Set(indices)
                    if index > 0 {
                        let previous = Set(resolvedWindowIndices[index - 1])
                        if previous.intersection(current).count < 3 {
                            issues.append("window[\(index)] continuous overlap had fewer than three images")
                        }
                        if current.subtracting(seen).isEmpty {
                            issues.append("window[\(index)] did not advance the continuous alignment graph")
                        }
                    }
                    seen.formUnion(current)
                }
            } else if inputOrdering == InputOrdering.unordered.rawValue {
                let anchorIndices = Set(anchors.compactMap { selectedImageNames.firstIndex(of: $0) })
                var seen = Set<Int>()
                for (index, indices) in resolvedWindowIndices.enumerated() {
                    let current = Set(indices)
                    if !anchorIndices.isSubset(of: current) {
                        issues.append("window[\(index)] did not contain all declared anchors")
                    }
                    if index > 0, current.subtracting(seen).isEmpty {
                        issues.append("window[\(index)] did not add an unseen image")
                    }
                    seen.formUnion(current)
                }
            }
            if alignmentComplete != true {
                issues.append("seed_refine requires alignment_complete=true")
            }
            let requiredEdges = max(0, windows.count - 1)
            if alignmentEdgeCount != requiredEdges {
                issues.append("seed_refine alignment_edge_count must equal \(requiredEdges)")
            }
            if let maxAlignmentRMSE {
                if !maxAlignmentRMSE.isFinite || maxAlignmentRMSE < 0 || maxAlignmentRMSE > 0.05 {
                    issues.append("seed_refine max_alignment_rmse must be finite and no greater than 0.05")
                }
            } else {
                issues.append("seed_refine requires max_alignment_rmse")
            }
            if rawPointSampleCount != nil || fusedSparsePointCount != nil || finalObservationCount != nil || meanTrackLength != nil {
                issues.append("aligned pose seed must not claim sparse points, observations, or track length")
            }
            if let pairs = boundedMatchPairs,
               let trustedPairLimit,
               pairs.count > trustedPairLimit {
                issues.append("seed_refine match pair count \(pairs.count) exceeded trusted match pair limit \(trustedPairLimit)")
            }
            if boundedMatchPairs == nil {
                issues.append("seed_refine match pair count exceeded the hard limit \(Self.hardMatchPairLimit)")
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
        if let maxAlignmentRMSE {
            parts.append("alignment RMSE \(String(format: "%.4f", maxAlignmentRMSE))")
        }
        return parts.joined(separator: ", ")
    }

    var boundedMatchPairs: [String]? {
        var pairs = Set<String>()
        for window in windows {
            guard window.images.count >= 2 else { continue }
            for firstIndex in 0..<(window.images.count - 1) {
                for secondIndex in (firstIndex + 1)..<window.images.count {
                    let first = window.images[firstIndex]
                    let second = window.images[secondIndex]
                    guard first != second else { continue }
                    let ordered = first < second ? "\(first) \(second)" : "\(second) \(first)"
                    pairs.insert(ordered)
                    if pairs.count > Self.hardMatchPairLimit {
                        return nil
                    }
                }
            }
        }
        return pairs.sorted()
    }

    static func trustedMatchPairLimit(
        selectedImageCount: Int,
        windowSize: Int,
        windowOverlap: Int,
        inputOrdering: InputOrdering
    ) -> Int? {
        guard selectedImageCount > 0, windowSize >= 4 else { return nil }
        let effectiveWindowSize = min(selectedImageCount, windowSize)
        let pairsPerWindow = effectiveWindowSize.multipliedReportingOverflow(
            by: effectiveWindowSize - 1
        )
        guard !pairsPerWindow.overflow else { return nil }
        let pairCapacity = pairsPerWindow.partialValue / 2
        guard selectedImageCount > effectiveWindowSize else {
            return min(pairCapacity, hardMatchPairLimit)
        }

        let newImagesPerWindow: Int
        switch inputOrdering {
        case .continuous:
            let effectiveOverlap = max(3, windowOverlap)
            guard effectiveOverlap < effectiveWindowSize else { return nil }
            newImagesPerWindow = effectiveWindowSize - effectiveOverlap
        case .unordered:
            newImagesPerWindow = effectiveWindowSize - 3
        case .automatic:
            return nil
        }
        guard newImagesPerWindow > 0 else { return nil }

        let remaining = selectedImageCount - effectiveWindowSize
        let additionalWindows = (remaining + newImagesPerWindow - 1) / newImagesPerWindow
        let windowCount = additionalWindows + 1
        let total = pairCapacity.multipliedReportingOverflow(by: windowCount)
        guard !total.overflow else { return nil }
        return min(total.partialValue, hardMatchPairLimit)
    }
}
