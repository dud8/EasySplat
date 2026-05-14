import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

extension PipelineRunner {
    struct SelectedFrameGroup: Sendable {
        let id: String
        let frames: [URL]
        let isVideo: Bool
    }

    struct SelectedFrameMapping: Codable, Sendable {
        let outputFileName: String
        let groupId: String
        let isVideo: Bool
        let sourcePath: String
    }

    var supportedImageExtensions: Set<String> {
        ["jpg", "jpeg", "png", "heic", "heif"]
    }

    func isHeicImage(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        return ext == "heic" || ext == "heif"
    }

    func transcodeHeicToJpeg(source: URL, destination: URL) throws {
        guard let sourceRef = CGImageSourceCreateWithURL(source as CFURL, nil) else {
            throw PipelineError.imageTranscodeFailed("Failed to read HEIC image: \(source.lastPathComponent)")
        }

        let props = CGImageSourceCopyPropertiesAtIndex(sourceRef, 0, nil) as? [CFString: Any]
        let width = (props?[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue ?? 0
        let height = (props?[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue ?? 0
        let maxDim = max(1, max(width, height))
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxDim,
            kCGImageSourceShouldCache: false
        ]

        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(sourceRef, 0, options as CFDictionary) else {
            throw PipelineError.imageTranscodeFailed("Failed to decode HEIC image: \(source.lastPathComponent)")
        }

        guard let destRef = CGImageDestinationCreateWithURL(destination as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw PipelineError.imageTranscodeFailed("Failed to create JPEG output: \(destination.lastPathComponent)")
        }

        let destOptions: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: 0.95
        ]
        CGImageDestinationAddImage(destRef, cgImage, destOptions as CFDictionary)
        guard CGImageDestinationFinalize(destRef) else {
            throw PipelineError.imageTranscodeFailed("Failed to write JPEG image: \(destination.lastPathComponent)")
        }
    }

    // Legacy support: earlier versions copied HEIC photos into Selected/ directly, but downstream tools
    // (COLMAP/VGGT) expect JPEG/PNG. Transcode in-place so resumed projects still work.
    func normalizeSelectedImagesForTooling(paths: ProjectPaths) throws -> Int {
        let fm = FileManager.default
        guard fm.fileExists(atPath: paths.framesSelectedURL.path) else { return 0 }

        let files = try fm.contentsOfDirectory(at: paths.framesSelectedURL, includingPropertiesForKeys: nil)
            .filter { !$0.hasDirectoryPath }

        var renamed: [String: String] = [:]
        var converted = 0
        for file in files where isHeicImage(file) {
            let newName = file.deletingPathExtension().lastPathComponent + ".jpg"
            let dest = paths.framesSelectedURL.appendingPathComponent(newName)

            if !fm.fileExists(atPath: dest.path) {
                try transcodeHeicToJpeg(source: file, destination: dest)
            }
            // Ensure downstream tools don't see a mix of formats with duplicate basenames.
            try? fm.removeItem(at: file)
            renamed[file.lastPathComponent] = newName
            converted += 1
        }

        if converted > 0,
           fm.fileExists(atPath: paths.framesSelectedManifestURL.path),
           let manifest = try? loadSelectedFrameManifest(from: paths.framesSelectedManifestURL) {
            let updated = manifest.map { entry in
                guard let newName = renamed[entry.outputFileName] else { return entry }
                return SelectedFrameMapping(
                    outputFileName: newName,
                    groupId: entry.groupId,
                    isVideo: entry.isVideo,
                    sourcePath: entry.sourcePath
                )
            }
            try saveSelectedFrameManifest(updated, to: paths.framesSelectedManifestURL)
        }

        return converted
    }

    func downsampleFrames(_ frames: [URL], targetCount: Int) -> [URL] {
        guard !frames.isEmpty else { return [] }
        guard targetCount > 0 else { return [] }
        if targetCount == 1 {
            return [frames[frames.count / 2]]
        }
        if frames.count <= targetCount {
            return frames
        }
        let step = Double(frames.count - 1) / Double(targetCount - 1)
        return (0..<targetCount).map { index in
            let position = Int(round(Double(index) * step))
            return frames[position]
        }
    }

    func downsampleSelectedFrames(to targetCount: Int, paths: ProjectPaths) throws -> [URL]? {
        guard targetCount > 0 else { return nil }
        let existing = try loadImages(in: paths.framesSelectedURL)
        guard existing.count > targetCount else { return nil }
        let reduced = downsampleFrames(existing, targetCount: targetCount)

        let tempSelected = paths.framesSelectedURL.deletingLastPathComponent()
            .appendingPathComponent("selected_retry", isDirectory: true)
        try resetDirectory(tempSelected)
        let newSelection = try copySelected(reduced, to: tempSelected)
        removeIfExists(paths.framesSelectedURL)
        try FileManager.default.moveItem(at: tempSelected, to: paths.framesSelectedURL)
        if FileManager.default.fileExists(atPath: paths.framesSelectedManifestURL.path),
           let manifest = try? loadSelectedFrameManifest(from: paths.framesSelectedManifestURL) {
            let manifestByFile = Dictionary(manifest.map { ($0.outputFileName, $0) }, uniquingKeysWith: { first, _ in first })
            var updated: [SelectedFrameMapping] = []
            updated.reserveCapacity(newSelection.count)
            for (index, original) in reduced.enumerated() where index < newSelection.count {
                let oldName = original.lastPathComponent
                guard let entry = manifestByFile[oldName] else { continue }
                let newName = newSelection[index].lastPathComponent
                updated.append(SelectedFrameMapping(
                    outputFileName: newName,
                    groupId: entry.groupId,
                    isVideo: entry.isVideo,
                    sourcePath: entry.sourcePath
                ))
            }
            try? saveSelectedFrameManifest(updated, to: paths.framesSelectedManifestURL)
        }
        return try loadImages(in: paths.framesSelectedURL)
    }

    func copySelected(
        groups: [SelectedFrameGroup],
        to directory: URL,
        manifestURL: URL,
        progress: ((Double, String) -> Void)? = nil
    ) throws -> (frames: [URL], manifest: [SelectedFrameMapping]) {
        let fm = FileManager.default
        var output: [URL] = []
        var manifest: [SelectedFrameMapping] = []
        let total = groups.reduce(0) { $0 + $1.frames.count }
        var index = 0
        var copied = 0
        for group in groups {
            for frame in group.frames {
                try Task.checkCancellation()
                let sourceExt = frame.pathExtension.lowercased()
                let destExt: String = {
                    if sourceExt.isEmpty { return "jpg" }
                    if sourceExt == "heic" || sourceExt == "heif" { return "jpg" }
                    return sourceExt
                }()
                let dest = directory.appendingPathComponent(String(format: "frame_%06d.%@", index, destExt))
                if fm.fileExists(atPath: dest.path) { try fm.removeItem(at: dest) }
                if isHeicImage(frame) {
                    try transcodeHeicToJpeg(source: frame, destination: dest)
                } else {
                    try fm.copyItem(at: frame, to: dest)
                }
                output.append(dest)
                manifest.append(SelectedFrameMapping(
                    outputFileName: dest.lastPathComponent,
                    groupId: group.id,
                    isVideo: group.isVideo,
                    sourcePath: frame.path
                ))
                index += 1
                copied += 1
                if let progress, total > 0, copied % 5 == 0 || copied == total {
                    let fraction = Double(copied) / Double(total)
                    progress(fraction, "Copying selected frames \(copied)/\(total)")
                }
            }
        }
        try saveSelectedFrameManifest(manifest, to: manifestURL)
        return (output, manifest)
    }

    func saveSelectedFrameManifest(_ manifest: [SelectedFrameMapping], to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(manifest)
        try data.write(to: url, options: [.atomic])
    }

    func loadSelectedFrameManifest(from url: URL) throws -> [SelectedFrameMapping] {
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode([SelectedFrameMapping].self, from: data)
    }

    func importedVideoURLs(for videoFiles: [String], paths: ProjectPaths) -> [URL] {
        var usedNames = Set<String>()
        return videoFiles.map { file in
            let source = URL(fileURLWithPath: file)
            let name = uniqueImportedVideoName(for: source, usedNames: &usedNames)
            return paths.originalsURL.appendingPathComponent(name)
        }
    }

    private func uniqueImportedVideoName(for source: URL, usedNames: inout Set<String>) -> String {
        let filename = source.lastPathComponent
        if usedNames.insert(filename).inserted {
            return filename
        }

        let nsName = filename as NSString
        let stem = nsName.deletingPathExtension
        let ext = nsName.pathExtension
        var suffix = 2
        while true {
            let candidate: String
            if ext.isEmpty {
                candidate = "\(stem)-\(suffix)"
            } else {
                candidate = "\(stem)-\(suffix).\(ext)"
            }
            if usedNames.insert(candidate).inserted {
                return candidate
            }
            suffix += 1
        }
    }

    func importInputs(
        metadata: ProjectMetadata,
        paths: ProjectPaths,
        progress: (Double, String) -> Void
    ) throws {
        var tasks: [(label: String, action: () throws -> Void)] = []

        let importedVideos = importedVideoURLs(for: metadata.input.videoFiles, paths: paths)
        for (file, dest) in zip(metadata.input.videoFiles, importedVideos) {
            let source = URL(fileURLWithPath: file)
            tasks.append((label: dest.lastPathComponent, action: {
                if try self.importedVideoNeedsCopy(dest) {
                    try self.copyFileAtomically(from: source, to: dest)
                }
            }))
        }

        if let photosFolder = metadata.input.photosFolder {
            let sourceFolder = URL(fileURLWithPath: photosFolder)
            let dest = paths.originalsURL.appendingPathComponent(sourceFolder.lastPathComponent)
            tasks.append((label: "Photos: \(sourceFolder.lastPathComponent)", action: {
                if try self.importedPhotoFolderNeedsCopy(source: sourceFolder, destination: dest) {
                    try self.copyDirectoryAtomically(from: sourceFolder, to: dest)
                }
            }))
        }

        guard !tasks.isEmpty else { return }
        let total = tasks.count
        for (index, task) in tasks.enumerated() {
            try Task.checkCancellation()
            let message = "Copying input \(index + 1)/\(total): \(task.label)"
            let startFraction = Double(index) / Double(total)
            progress(startFraction, message)
            try task.action()
            let endFraction = Double(index + 1) / Double(total)
            progress(endFraction, message)
        }
    }

    func copySelected(_ frames: [URL], to directory: URL) throws -> [URL] {
        let fm = FileManager.default
        var output: [URL] = []
        for (index, url) in frames.enumerated() {
            try Task.checkCancellation()
            let sourceExt = url.pathExtension.lowercased()
            let destExt: String = {
                if sourceExt.isEmpty { return "jpg" }
                if sourceExt == "heic" || sourceExt == "heif" { return "jpg" }
                return sourceExt
            }()
            let dest = directory.appendingPathComponent(String(format: "frame_%06d.%@", index, destExt))
            if fm.fileExists(atPath: dest.path) { try fm.removeItem(at: dest) }
            if isHeicImage(url) {
                try transcodeHeicToJpeg(source: url, destination: dest)
            } else {
                try fm.copyItem(at: url, to: dest)
            }
            output.append(dest)
        }
        return output
    }

    func importedVideoNeedsCopy(_ destination: URL) throws -> Bool {
        let fm = FileManager.default
        guard fm.fileExists(atPath: destination.path) else { return true }
        let size = (try? fm.attributesOfItem(atPath: destination.path)[.size] as? NSNumber)?.int64Value ?? 0
        return size <= 0
    }

    func importedPhotoFolderNeedsCopy(source: URL, destination: URL) throws -> Bool {
        let fm = FileManager.default
        guard fm.fileExists(atPath: destination.path) else { return true }
        let importedPhotos = try loadPhotos(in: destination)
        guard !importedPhotos.isEmpty else { return true }
        if fm.fileExists(atPath: source.path) {
            let sourcePhotos = try loadPhotos(in: source)
            return importedPhotos.count != sourcePhotos.count
        }
        return false
    }

    func copyFileAtomically(from source: URL, to destination: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        let temp = destination.deletingLastPathComponent()
            .appendingPathComponent(".\(destination.lastPathComponent).\(UUID().uuidString).tmp")
        defer {
            if fm.fileExists(atPath: temp.path) {
                try? fm.removeItem(at: temp)
            }
        }

        try fm.copyItem(at: source, to: temp)
        if fm.fileExists(atPath: destination.path) {
            _ = try fm.replaceItemAt(destination, withItemAt: temp, backupItemName: nil, options: [])
        } else {
            try fm.moveItem(at: temp, to: destination)
        }
    }

    func copyDirectoryAtomically(from source: URL, to destination: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        let temp = destination.deletingLastPathComponent()
            .appendingPathComponent(".\(destination.lastPathComponent).\(UUID().uuidString).tmp", isDirectory: true)
        defer {
            if fm.fileExists(atPath: temp.path) {
                try? fm.removeItem(at: temp)
            }
        }

        try fm.copyItem(at: source, to: temp)
        if fm.fileExists(atPath: destination.path) {
            _ = try fm.replaceItemAt(destination, withItemAt: temp, backupItemName: nil, options: [])
        } else {
            try fm.moveItem(at: temp, to: destination)
        }
    }

    func rawFramesDirectory(index: Int, paths: ProjectPaths) -> URL {
        paths.framesRawURL.appendingPathComponent(String(format: "video_%03d", index), isDirectory: true)
    }

    func loadImages(in directory: URL) throws -> [URL] {
        let fm = FileManager.default
        guard fm.fileExists(atPath: directory.path) else { return [] }
        return try fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { !$0.hasDirectoryPath }
            .filter { supportedImageExtensions.contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    func loadPhotos(in directory: URL) throws -> [URL] {
        let fm = FileManager.default
        guard fm.fileExists(atPath: directory.path) else { return [] }
        let normalizedRoot = directory.standardizedFileURL
        let looksLikeProjectRoot = fm.fileExists(atPath: directory.appendingPathComponent("project.json").path)
        let excludedProjectDirectories: Set<String> = looksLikeProjectRoot
            ? ["Frames", "SfM", "Training", "Output", "Logs"]
            : []
        guard let enumerator = fm.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey, .nameKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        var photos: [URL] = []
        for case let url as URL in enumerator {
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .nameKey])
            if values?.isDirectory == true {
                if looksLikeProjectRoot,
                   url.deletingLastPathComponent().standardizedFileURL == normalizedRoot,
                   let name = values?.name,
                   excludedProjectDirectories.contains(name) {
                    enumerator.skipDescendants()
                }
                continue
            }
            if supportedImageExtensions.contains(url.pathExtension.lowercased()) {
                photos.append(url)
            }
        }

        return photos.sorted { lhs, rhs in
            let left = lhs.path.replacingOccurrences(of: directory.path + "/", with: "")
            let right = rhs.path.replacingOccurrences(of: directory.path + "/", with: "")
            return left < right
        }
    }

    struct BlurFilterResult: Sendable {
        let frames: [URL]
        let dropped: Int
    }

    func scoreSharpnessForFrames(
        _ frames: [URL],
        progress: (Double, String) -> Void
    ) throws -> [URL: Double] {
        guard !frames.isEmpty else { return [:] }
        let total = Double(frames.count)
        var results: [URL: Double] = [:]
        results.reserveCapacity(frames.count)
        for (index, url) in frames.enumerated() {
            try Task.checkCancellation()
            if let score = try? FrameScoring.scoreFrame(at: url) {
                results[url] = max(score.blurScore, score.laplacianScore)
            }
            if index % 10 == 0 || index + 1 == frames.count {
                let fraction = min(Double(index + 1) / total, 1.0)
                progress(fraction, "Analyzing frame sharpness")
            }
        }
        return results
    }

    func applyFrameBudget(to groups: [SelectedFrameGroup], targetCount: Int) -> [SelectedFrameGroup] {
        guard targetCount > 0 else { return [] }
        let total = groups.reduce(0) { $0 + $1.frames.count }
        guard total > targetCount else { return groups }

        struct FrameEntry {
            let groupIndex: Int
            let url: URL
        }

        let flattened = groups.enumerated().flatMap { groupIndex, group in
            group.frames.map { FrameEntry(groupIndex: groupIndex, url: $0) }
        }
        guard targetCount > 1 else {
            let entry = flattened[flattened.count / 2]
            let group = groups[entry.groupIndex]
            return [SelectedFrameGroup(id: group.id, frames: [entry.url], isVideo: group.isVideo)]
        }

        let step = Double(flattened.count - 1) / Double(targetCount - 1)
        var selectedByGroup = Array(repeating: [URL](), count: groups.count)
        for index in 0..<targetCount {
            let position = Int(round(Double(index) * step))
            let entry = flattened[position]
            selectedByGroup[entry.groupIndex].append(entry.url)
        }

        return groups.enumerated().compactMap { index, group in
            let frames = selectedByGroup[index]
            guard !frames.isEmpty else { return nil }
            return SelectedFrameGroup(id: group.id, frames: frames, isVideo: group.isVideo)
        }
    }

    func filterVeryBlurryVideoFrames(
        frames: [URL],
        sharpnessByFrame: [URL: Double],
        profile: FrameExtractionProfile,
        maxDropFraction: Double,
        floorScale: Double
    ) -> BlurFilterResult {
        guard !frames.isEmpty else { return BlurFilterResult(frames: [], dropped: 0) }
        let safeFraction = max(0.0, min(1.0, maxDropFraction))
        let maxDropCount = Int((Double(frames.count) * safeFraction).rounded(.down))
        guard maxDropCount > 0 else { return BlurFilterResult(frames: frames, dropped: 0) }
        let floor = max(0.0, profile.sharpnessFloor * floorScale)

        var candidates: [(URL, Double)] = []
        candidates.reserveCapacity(frames.count)
        for url in frames {
            guard let sharpness = sharpnessByFrame[url] else { continue }
            if sharpness < floor {
                candidates.append((url, sharpness))
            }
        }
        guard !candidates.isEmpty else { return BlurFilterResult(frames: frames, dropped: 0) }

        let toDrop: Set<URL>
        if candidates.count <= maxDropCount {
            toDrop = Set(candidates.map { $0.0 })
        } else {
            let worst = candidates.sorted { $0.1 < $1.1 }.prefix(maxDropCount)
            toDrop = Set(worst.map { $0.0 })
        }
        guard !toDrop.isEmpty else { return BlurFilterResult(frames: frames, dropped: 0) }
        let filtered = frames.filter { !toDrop.contains($0) }
        let dropped = frames.count - filtered.count
        return BlurFilterResult(frames: filtered, dropped: dropped)
    }

    func targetCountForVideo(index: Int, total: Int, targetCount: Int) -> Int {
        guard total > 0 else { return targetCount }
        let base = targetCount / total
        let remainder = targetCount % total
        return base + (index < remainder ? 1 : 0)
    }

    func persistCheckpoint(
        paths: ProjectPaths,
        stage: PipelineStage,
        progress: Double? = nil,
        message: String? = nil,
        details: PipelineCheckpointDetails? = nil
    ) {
        guard var metadata = try? ProjectMetadataStore.load(from: paths.metadataURL) else { return }
        metadata.checkpoint = PipelineCheckpoint(
            stage: stage,
            updatedAt: Date(),
            progressFraction: progress,
            message: message,
            details: details
        )
        try? ProjectMetadataStore.save(metadata, to: paths.metadataURL)
    }

    struct FrameExtractionProfile {
        let targetCount: Int
        let maxDimension: CGFloat
        let targetFPS: Int
        let minDistanceRatio: Double
        let sharpnessFloor: Double
        let sharpnessRatio: Double
        let outputFormat: FrameOutputFormat
        let maxExtractedFrames: Int?
    }

    func frameExtractionProfile(for quality: QualityPreset) -> FrameExtractionProfile {
        let base: FrameExtractionProfile = switch quality {
        case .draft:
            FrameExtractionProfile(
                targetCount: 120,
                maxDimension: 1024,
                targetFPS: 2,
                minDistanceRatio: 0.20,
                sharpnessFloor: 30.0,
                sharpnessRatio: 0.5,
                outputFormat: .jpeg,
                maxExtractedFrames: nil
            )
        case .standard:
            FrameExtractionProfile(
                targetCount: 250,
                maxDimension: 1600,
                targetFPS: 3,
                minDistanceRatio: 0.20,
                sharpnessFloor: 40.0,
                sharpnessRatio: 0.6,
                outputFormat: .jpeg,
                maxExtractedFrames: nil
            )
        case .ultra:
            FrameExtractionProfile(
                targetCount: 500,
                maxDimension: 2048,
                targetFPS: 4,
                minDistanceRatio: 0.20,
                sharpnessFloor: 50.0,
                sharpnessRatio: 0.65,
                outputFormat: .png,
                maxExtractedFrames: nil
            )
        }
        let profiled = isFastSpeedProfile()
            ? FrameExtractionProfile(
                targetCount: fastSpeedProfileFrameBudget(),
                maxDimension: 960,
                targetFPS: 3,
                minDistanceRatio: base.minDistanceRatio,
                sharpnessFloor: base.sharpnessFloor,
                sharpnessRatio: base.sharpnessRatio,
                outputFormat: .jpeg,
                maxExtractedFrames: fastSpeedProfileFrameExtractionCap(targetCount: fastSpeedProfileFrameBudget())
            )
            : base
        let targetCountOverride = intEnvValue("EASYSPLAT_FRAME_TARGET_COUNT")
            .flatMap { $0 > 0 ? $0 : nil }
        let targetCount = targetCountOverride ?? profiled.targetCount
        let maxDimension = intEnvValue("EASYSPLAT_FRAME_MAX_DIMENSION")
            .flatMap { $0 > 0 ? max(256, $0) : nil } ?? Int(profiled.maxDimension)
        let targetFPS = intEnvValue("EASYSPLAT_FRAME_TARGET_FPS")
            .flatMap { $0 > 0 ? $0 : nil } ?? profiled.targetFPS
        let maxExtractedFrames: Int?
        if isFastSpeedProfile() {
            maxExtractedFrames = fastSpeedProfileFrameExtractionCap(targetCount: targetCount)
        } else {
            maxExtractedFrames = profiled.maxExtractedFrames
        }
        return FrameExtractionProfile(
            targetCount: targetCount,
            maxDimension: CGFloat(maxDimension),
            targetFPS: targetFPS,
            minDistanceRatio: profiled.minDistanceRatio,
            sharpnessFloor: profiled.sharpnessFloor,
            sharpnessRatio: profiled.sharpnessRatio,
            outputFormat: profiled.outputFormat,
            maxExtractedFrames: maxExtractedFrames
        )
    }

    func cameraModel(for preset: PresetSpec) -> String {
        if preset.mode == .room && preset.quality == .ultra {
            return "OPENCV"
        }
        return "SIMPLE_RADIAL"
    }

    func shouldUseSequential(selectedFrames: [URL], input: InputSpec, forceExhaustive: Bool) -> Bool {
        if forceExhaustive { return false }
        guard input.hasVideos, !input.hasPhotos else { return false }
        guard input.videoFiles.count == 1 else { return false }
        if selectedFrames.count < 30 { return false }
        return true
    }
}
