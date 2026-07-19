import Foundation

struct Da3CoverageManifest: Codable, Sendable {
    static let hardMatchPairLimit = 100_000
    // A 3,000-frame solve with ten-view windows advancing two views has at most
    // 15,000 serialized image entries. Eight MiB leaves over 500 bytes per entry;
    // the 100,000-pair budget is derived from those windows, not serialized here.
    private static let maximumFileBytes = 8 * 1_024 * 1_024

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
        let data = try BoundedFileReader.readRegularFile(
            at: url,
            maximumBytes: maximumFileBytes
        )
        return try JSONDecoder().decode(Da3CoverageManifest.self, from: data)
    }

    func validationIssues(
        selectedImageNames: [String],
        expectedWindowSize: Int? = nil,
        expectedWindowOverlap: Int? = nil,
        expectedInputOrdering: InputOrdering? = nil,
        expectedProcessResolution: Int? = nil,
        expectedMaxPoints: Int? = nil,
        expectedCameraType: String? = nil,
        expectedSharedCamera: Bool? = nil,
        expectedModelSubdirectory: String? = nil
    ) -> [String] {
        var issues: [String] = []
        let selectedImageCount = selectedImageNames.count
        if mode != "seed_refine" {
            issues.append("mode=\(mode) did not match required seed_refine")
        }
        if requestedDevice != Da3SfmConfig.requiredDevice {
            issues.append(
                "requested_device=\(requestedDevice) did not match required \(Da3SfmConfig.requiredDevice)"
            )
        }
        if selectedDevice != Da3SfmConfig.requiredDevice {
            issues.append(
                "selected_device=\(selectedDevice) did not match required \(Da3SfmConfig.requiredDevice)"
            )
        }
        if totalImages != selectedImageCount {
            issues.append("total_images=\(totalImages) did not match selected frames \(selectedImageCount)")
        }
        if let expectedProcessResolution, processResolution != expectedProcessResolution {
            issues.append("process_res=\(processResolution) did not match expected \(expectedProcessResolution)")
        }
        if maxPoints <= 0 {
            issues.append("max_points must be positive")
        }
        if let expectedMaxPoints, maxPoints != expectedMaxPoints {
            issues.append("max_points=\(maxPoints) did not match expected \(expectedMaxPoints)")
        }
        if let expectedCameraType, cameraType != expectedCameraType {
            issues.append("camera_type=\(cameraType) did not match expected \(expectedCameraType)")
        }
        if let expectedSharedCamera, sharedCamera != expectedSharedCamera {
            issues.append("shared_camera=\(sharedCamera) did not match expected \(expectedSharedCamera)")
        }
        if let expectedModelSubdirectory,
           modelSubdirectory != expectedModelSubdirectory {
            issues.append(
                "model_subdir=\(modelSubdirectory) did not match expected \(expectedModelSubdirectory)"
            )
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
        let trustedPairLimit: Int?
        if let expectedWindowSize,
           let expectedWindowOverlap,
           let expectedInputOrdering {
            let effectiveExpectedWindowSize = max(
                2,
                min(expectedWindowSize, selectedImageCount)
            )
            let effectiveExpectedWindowOverlap = max(
                0,
                min(expectedWindowOverlap, effectiveExpectedWindowSize - 1)
            )
            if windowSize != effectiveExpectedWindowSize {
                issues.append("seed_refine window_size=\(windowSize) did not match expected \(effectiveExpectedWindowSize)")
            }
            if windowOverlap != effectiveExpectedWindowOverlap {
                issues.append("seed_refine window_overlap=\(windowOverlap) did not match expected \(effectiveExpectedWindowOverlap)")
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
        if exportStrategy != "aligned_pose_depth_seed" {
            issues.append("seed_refine requires export_strategy=aligned_pose_depth_seed")
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
        let requiredAnchorCount = min(3, selectedImageCount)
        if anchors.count < requiredAnchorCount || Set(anchors).count != anchors.count {
            issues.append("seed_refine requires at least \(requiredAnchorCount) distinct anchor_image_names")
        } else if !Set(anchors).isSubset(of: coveredImages) {
            issues.append("seed_refine anchor_image_names must belong to covered images")
        }
        if inputOrdering != InputOrdering.continuous.rawValue,
           inputOrdering != InputOrdering.unordered.rawValue {
            issues.append("seed_refine input_ordering must resolve to continuous or unordered")
        }
        if inputOrdering == InputOrdering.continuous.rawValue {
            let requiredOverlap = Self.minimumAlignmentOverlap(
                windowSize: windowSize,
                requestedOverlap: windowOverlap
            )
            var seen = Set<Int>()
            for (index, indices) in resolvedWindowIndices.enumerated() {
                let current = Set(indices)
                if index > 0 {
                    let previous = Set(resolvedWindowIndices[index - 1])
                    if previous.intersection(current).count < requiredOverlap {
                        issues.append("window[\(index)] continuous overlap had fewer than \(requiredOverlap) images")
                    }
                    if current.subtracting(seen).isEmpty {
                        issues.append("window[\(index)] did not advance the continuous alignment graph")
                    }
                }
                seen.formUnion(current)
            }
        } else if inputOrdering == InputOrdering.unordered.rawValue {
            let requiredOverlap = Self.minimumAlignmentOverlap(
                windowSize: windowSize,
                requestedOverlap: windowOverlap
            )
            var seen = Set<Int>()
            for (index, indices) in resolvedWindowIndices.enumerated() {
                let current = Set(indices)
                if index > 0, current.intersection(seen).count < requiredOverlap {
                    issues.append("window[\(index)] unordered overlap had fewer than \(requiredOverlap) accepted images")
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
        if let rawPointSampleCount, let fusedSparsePointCount {
            if rawPointSampleCount <= 0 {
                issues.append("raw_point_sample_count must be positive")
            }
            if fusedSparsePointCount <= 0 {
                issues.append("fused_sparse_point_count must be positive")
            }
            if fusedSparsePointCount > rawPointSampleCount {
                issues.append("fused_sparse_point_count cannot exceed raw_point_sample_count")
            }
            if maxPoints > 0, fusedSparsePointCount > maxPoints {
                issues.append("fused_sparse_point_count exceeded max_points")
            }
            let multiplied = maxPoints.multipliedReportingOverflow(by: 4)
            let selectedAllowance = selectedImageCount.multipliedReportingOverflow(by: 128)
            let added = selectedAllowance.overflow
                ? (partialValue: Int.max, overflow: true)
                : maxPoints.addingReportingOverflow(selectedAllowance.partialValue)
            let rawLimit = min(
                multiplied.overflow ? Int.max : multiplied.partialValue,
                added.overflow ? Int.max : added.partialValue
            )
            if rawPointSampleCount > rawLimit {
                issues.append("raw_point_sample_count exceeded the trusted sampling limit")
            }
        } else {
            issues.append("seed_refine requires learned point sample and fusion counts")
        }
        if finalObservationCount != nil || meanTrackLength != nil {
            issues.append("learned initializer must not claim measured observations or track length")
        }
        if let pairs = boundedMatchPairs,
           let trustedPairLimit,
           pairs.count > trustedPairLimit {
            issues.append("seed_refine match pair count \(pairs.count) exceeded trusted match pair limit \(trustedPairLimit)")
        }
        if boundedMatchPairs == nil {
            issues.append("seed_refine match pair count exceeded the hard limit \(Self.hardMatchPairLimit)")
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
        if let maxAlignmentRMSE {
            parts.append("alignment RMSE \(String(format: "%.4f", maxAlignmentRMSE))")
        }
        if let fusedSparsePointCount {
            parts.append("learned points \(fusedSparsePointCount)")
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
            let effectiveOverlap = minimumAlignmentOverlap(
                windowSize: effectiveWindowSize,
                requestedOverlap: windowOverlap
            )
            guard effectiveOverlap < effectiveWindowSize else { return nil }
            newImagesPerWindow = effectiveWindowSize - effectiveOverlap
        case .unordered:
            let effectiveOverlap = minimumAlignmentOverlap(
                windowSize: effectiveWindowSize,
                requestedOverlap: windowOverlap
            )
            newImagesPerWindow = effectiveWindowSize - effectiveOverlap
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

    static func trustedRefinementMatchPairLimit(
        selectedImageCount: Int,
        windowSize: Int,
        windowOverlap: Int,
        inputOrdering: InputOrdering,
        includesLoopClosures: Bool
    ) -> Int? {
        guard let localLimit = trustedMatchPairLimit(
            selectedImageCount: selectedImageCount,
            windowSize: windowSize,
            windowOverlap: windowOverlap,
            inputOrdering: inputOrdering
        ) else {
            return nil
        }
        guard includesLoopClosures else { return localLimit }
        let loopBudget = selectedImageCount.multipliedReportingOverflow(by: 2)
        guard !loopBudget.overflow else { return nil }
        let combined = localLimit.addingReportingOverflow(loopBudget.partialValue)
        guard !combined.overflow else { return nil }
        return min(combined.partialValue, hardMatchPairLimit)
    }

    private static func minimumAlignmentOverlap(windowSize: Int, requestedOverlap: Int) -> Int {
        let geometryMinimum = windowSize == 4 ? 2 : 3
        return min(max(geometryMinimum, requestedOverlap), max(2, windowSize - 2))
    }
}
