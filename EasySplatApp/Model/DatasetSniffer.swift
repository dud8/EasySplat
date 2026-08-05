import EasySplatCore
import Foundation

/// Stat-first detection of a pre-processed dataset input. Pure and
/// `nonisolated` so selection can classify a dropped URL without hopping the
/// main actor. Folder probes use `FileManager.fileExists` only; the zip probe
/// reads the central directory in process without extracting anything.
///
/// Precedence is COLMAP > Nerfstudio > Polycam so a folder that carries more
/// than one format's markers resolves deterministically to the richest one.
enum DatasetSniffer {
    enum DatasetDetection: Equatable {
        case colmap(root: URL)
        case nerfstudio(root: URL)
        case polycam(root: URL)

        var kind: DatasetKind {
            switch self {
            case .colmap: return .colmap
            case .nerfstudio: return .nerfstudio
            case .polycam: return .polycam
            }
        }

        var root: URL {
            switch self {
            case let .colmap(root), let .nerfstudio(root), let .polycam(root):
                return root
            }
        }
    }

    /// Image file extensions the pipeline admits, mirrored here so a COLMAP
    /// project's loose images register as image data during detection.
    static let imageExtensions: Set<String> = [
        "jpg", "jpeg", "png", "heic", "heif", "tif", "tiff",
    ]

    // MARK: - Folder detection

    /// Detects a dataset rooted at `url`, or one visible directory below it.
    /// A marker-less root that holds exactly one visible child directory
    /// descends once (total depth <= 2); two or more candidate children are
    /// ambiguous and yield nil.
    nonisolated static func detect(at url: URL) -> DatasetDetection? {
        if let detection = probeFolder(url) {
            return detection
        }
        guard let child = soleVisibleChildDirectory(of: url) else {
            return nil
        }
        return probeFolder(child)
    }

    private nonisolated static func probeFolder(_ root: URL) -> DatasetDetection? {
        if isColmap(root) { return .colmap(root: root) }
        if isNerfstudio(root) { return .nerfstudio(root: root) }
        if isPolycam(root) { return .polycam(root: root) }
        return nil
    }

    private nonisolated static func isColmap(_ root: URL) -> Bool {
        // A model plus at least one image directory or loose image on disk;
        // a bare sparse model without images cannot train.
        colmapModelPresent(under: root)
            && (isDirectory(root.appendingPathComponent("images", isDirectory: true))
                || hasLooseImages(in: root))
    }

    /// Mirrors `ColmapDatasetImporter.locateModelDirectory`'s discovery order
    /// and `containsModel`'s file test. Kept local because the core helper is
    /// module-internal; the two must stay in step.
    private nonisolated static func colmapModelPresent(under root: URL) -> Bool {
        let candidates = [
            root.appendingPathComponent("sparse/0", isDirectory: true),
            root.appendingPathComponent("sparse", isDirectory: true),
            root.appendingPathComponent("model", isDirectory: true),
            root,
        ]
        return candidates.contains(where: modelFilesPresent)
    }

    private nonisolated static func modelFilesPresent(in directory: URL) -> Bool {
        let fileManager = FileManager.default
        let hasCameras = ["cameras.bin", "cameras.txt"].contains {
            fileManager.fileExists(atPath: directory.appendingPathComponent($0).path)
        }
        let hasImages = ["images.bin", "images.txt"].contains {
            fileManager.fileExists(atPath: directory.appendingPathComponent($0).path)
        }
        return hasCameras && hasImages
    }

    private nonisolated static func isNerfstudio(_ root: URL) -> Bool {
        let fileManager = FileManager.default
        return fileManager.fileExists(atPath: root.appendingPathComponent("transforms.json").path)
            || fileManager.fileExists(atPath: root.appendingPathComponent("transforms_train.json").path)
    }

    private nonisolated static func isPolycam(_ root: URL) -> Bool {
        let keyframes = root.appendingPathComponent("keyframes", isDirectory: true)
        guard isDirectory(keyframes) else { return false }
        let hasCameras = isDirectory(keyframes.appendingPathComponent("cameras", isDirectory: true))
            || isDirectory(keyframes.appendingPathComponent("corrected_cameras", isDirectory: true))
        let hasImages = isDirectory(keyframes.appendingPathComponent("images", isDirectory: true))
            || isDirectory(keyframes.appendingPathComponent("corrected_images", isDirectory: true))
        return hasCameras && hasImages
    }

    private nonisolated static func isDirectory(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
            && isDirectory.boolValue
    }

    private nonisolated static func hasLooseImages(in root: URL) -> Bool {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return false
        }
        return entries.contains { url in
            imageExtensions.contains(url.pathExtension.lowercased())
                && (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true
        }
    }

    /// The single visible subdirectory of `url`, or nil when there are none or
    /// several. Files are ignored; only directories count as descent candidates.
    private nonisolated static func soleVisibleChildDirectory(of url: URL) -> URL? {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return nil
        }
        let directories = entries.filter {
            (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
        }
        guard directories.count == 1, let sole = directories.first else { return nil }
        // Rebuild from the caller's URL so the detected root keeps the path
        // form the user dropped (enumeration may resolve /var to /private/var).
        return url.appendingPathComponent(sole.lastPathComponent, isDirectory: true)
    }

    // MARK: - Zip detection

    /// Peeks at a zip's entry names (no extraction) and matches the same
    /// signatures folder detection uses, allowing one leading root-folder
    /// prefix. Returns nil for any zip that fails to list or match, so the
    /// caller can warn. Reads the central directory directly.
    nonisolated static func detectInZip(at url: URL) -> DatasetDetection? {
        guard let names = try? SafeArchiveExtractor.entryNames(inZipAt: url),
              !names.isEmpty else {
            return nil
        }
        let paths = Set(names)
        // Match at the archive root first; only when nothing matches there,
        // retry with a single wrapping folder stripped. Stripping first would
        // eat marker directories like a top-level `keyframes/`.
        if let detection = matchZipSignatures(paths, url: url) {
            return detection
        }
        guard let stripped = strippingSingleTopLevelPrefix(paths) else { return nil }
        return matchZipSignatures(stripped, url: url)
    }

    private nonisolated static func matchZipSignatures(
        _ paths: Set<String>,
        url: URL
    ) -> DatasetDetection? {
        if zipHasColmap(paths) { return .colmap(root: url) }
        if zipHasNerfstudio(paths) { return .nerfstudio(root: url) }
        if zipHasPolycam(paths) { return .polycam(root: url) }
        return nil
    }

    /// When every entry lives under one shared top-level folder, returns the
    /// same paths with that folder removed; nil when there is no such wrapper.
    private nonisolated static func strippingSingleTopLevelPrefix(
        _ paths: Set<String>
    ) -> Set<String>? {
        var firstComponents = Set<String>()
        var anyNested = false
        for path in paths {
            let components = path.split(separator: "/", omittingEmptySubsequences: true)
            guard let first = components.first else { continue }
            firstComponents.insert(String(first))
            if components.count > 1 { anyNested = true }
        }
        guard firstComponents.count == 1, anyNested, let prefix = firstComponents.first else {
            return nil
        }
        let stripped = paths.compactMap { path -> String? in
            guard path.hasPrefix(prefix + "/") else { return nil }
            let remainder = String(path.dropFirst(prefix.count + 1))
            return remainder.isEmpty ? nil : remainder
        }
        return Set(stripped)
    }

    private nonisolated static func zipHasColmap(_ paths: Set<String>) -> Bool {
        let modelPrefixes = ["sparse/0/", "sparse/", "model/", ""]
        let hasModel = modelPrefixes.contains { prefix in
            (paths.contains(prefix + "cameras.bin") || paths.contains(prefix + "cameras.txt"))
                && (paths.contains(prefix + "images.bin") || paths.contains(prefix + "images.txt"))
        }
        guard hasModel else { return false }
        return paths.contains { $0.hasPrefix("images/") || isImagePath($0) }
    }

    private nonisolated static func zipHasNerfstudio(_ paths: Set<String>) -> Bool {
        paths.contains("transforms.json") || paths.contains("transforms_train.json")
    }

    private nonisolated static func zipHasPolycam(_ paths: Set<String>) -> Bool {
        let hasCameras = paths.contains {
            $0.hasPrefix("keyframes/cameras/") || $0.hasPrefix("keyframes/corrected_cameras/")
        }
        let hasImages = paths.contains {
            $0.hasPrefix("keyframes/images/") || $0.hasPrefix("keyframes/corrected_images/")
        }
        return hasCameras && hasImages
    }

    private nonisolated static func isImagePath(_ path: String) -> Bool {
        guard !path.hasSuffix("/") else { return false }
        return imageExtensions.contains((path as NSString).pathExtension.lowercased())
    }
}

/// Accumulates archive entry names under a bounded budget.
private final class ZipNameCollector: @unchecked Sendable {
    private static let maximumEntryCount = 50_000
    private static let maximumTotalBytes = 8 * 1_024 * 1_024

    private let lock = NSLock()
    private var names: [String] = []
    private var totalBytes = 0
    private var overflowed = false

    func append(_ name: String) {
        lock.lock()
        defer { lock.unlock() }
        guard !overflowed else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        totalBytes += trimmed.utf8.count
        if names.count >= Self.maximumEntryCount || totalBytes > Self.maximumTotalBytes {
            overflowed = true
            return
        }
        names.append(trimmed)
    }

    func paths() -> Set<String> {
        lock.lock()
        let collected = names
        let didOverflow = overflowed
        lock.unlock()
        // A truncated listing may have dropped the markers we need; treat it as
        // undetectable rather than guess from a partial view.
        guard !didOverflow else { return [] }
        let cleaned = collected
            .map { $0.hasPrefix("./") ? String($0.dropFirst(2)) : $0 }
            .filter { !$0.isEmpty }
        return Set(cleaned)
    }
}
