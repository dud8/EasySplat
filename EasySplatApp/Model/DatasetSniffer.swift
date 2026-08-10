import Darwin
import EasySplatCore
import Foundation

/// Stat-first detection of a pre-processed dataset input. Pure and
/// `nonisolated` so selection can classify a dropped URL without hopping the
/// main actor. Folder probes refuse links at the roots they classify; the zip
/// probe reads the central directory in process without extracting anything.
///
/// Precedence is COLMAP > Nerfstudio > Polycam so a folder that carries more
/// than one format's markers resolves deterministically to the richest one.
enum DatasetSniffer {
    private struct DirectDirectoryEntry {
        let name: String
        let mode: mode_t
    }

    private enum DirectDirectoryScan {
        case complete([DirectDirectoryEntry])
        case unavailableOrLimitExceeded
    }

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
        detect(at: url, maximumEntryCount: DatasetContract.maximumEntryCount)
    }

    /// Test seam for proving the production entry ceiling with small fixtures.
    /// The public selection path always supplies DatasetContract's 50,000-entry
    /// limit.
    nonisolated static func detect(
        at url: URL,
        maximumEntryCount: Int
    ) -> DatasetDetection? {
        if let detection = probeFolder(url) {
            return detection
        }
        guard let child = soleVisibleChildDirectory(
            of: url,
            maximumEntryCount: maximumEntryCount
        ) else {
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
        let hasCameras = ["cameras.bin", "cameras.txt"].contains {
            isRegularFile(directory.appendingPathComponent($0))
        }
        let hasImages = ["images.bin", "images.txt"].contains {
            isRegularFile(directory.appendingPathComponent($0))
        }
        return hasCameras && hasImages
    }

    private nonisolated static func isNerfstudio(_ root: URL) -> Bool {
        isRegularFile(
            root.appendingPathComponent(DatasetContract.nerfstudioManifestName)
        )
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
        var status = stat()
        return lstat(url.path, &status) == 0 && (status.st_mode & S_IFMT) == S_IFDIR
    }

    private nonisolated static func isRegularFile(_ url: URL) -> Bool {
        var status = stat()
        return lstat(url.path, &status) == 0 && (status.st_mode & S_IFMT) == S_IFREG
    }

    private nonisolated static func hasLooseImages(in root: URL) -> Bool {
        guard case let .complete(entries) = directDirectoryEntries(
            at: root,
            maximumEntryCount: DatasetContract.maximumEntryCount
        ) else {
            return false
        }
        return entries.contains { entry in
            (entry.mode & S_IFMT) == S_IFREG
                && imageExtensions.contains(
                    (entry.name as NSString).pathExtension.lowercased()
                )
        }
    }

    /// The single visible subdirectory of `url`, or nil when there are none or
    /// several. Files are ignored; only directories count as descent candidates.
    private nonisolated static func soleVisibleChildDirectory(
        of url: URL,
        maximumEntryCount: Int
    ) -> URL? {
        guard case let .complete(entries) = directDirectoryEntries(
            at: url,
            maximumEntryCount: maximumEntryCount
        ) else {
            return nil
        }
        let directories = entries.filter { ($0.mode & S_IFMT) == S_IFDIR }
        guard directories.count == 1, let sole = directories.first else { return nil }
        // Rebuild from the caller's URL so the detected root keeps the path
        // form the user dropped (enumeration may resolve /var to /private/var).
        return url.appendingPathComponent(sole.name, isDirectory: true)
    }

    /// Streams one directory through a descriptor and applies the budget before
    /// retaining more than the bounded result. Every visited entry counts,
    /// including hidden entries that are omitted from dataset matching.
    private nonisolated static func directDirectoryEntries(
        at url: URL,
        maximumEntryCount: Int
    ) -> DirectDirectoryScan {
        guard maximumEntryCount >= 0 else { return .unavailableOrLimitExceeded }
        var namedStatus = stat()
        guard lstat(url.path, &namedStatus) == 0,
              (namedStatus.st_mode & S_IFMT) == S_IFDIR else {
            return .unavailableOrLimitExceeded
        }
        let descriptor = Darwin.open(
            url.path,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard descriptor >= 0 else { return .unavailableOrLimitExceeded }
        defer { Darwin.close(descriptor) }
        var openedStatus = stat()
        guard fstat(descriptor, &openedStatus) == 0,
              openedStatus.st_dev == namedStatus.st_dev,
              openedStatus.st_ino == namedStatus.st_ino,
              (openedStatus.st_mode & S_IFMT) == S_IFDIR else {
            return .unavailableOrLimitExceeded
        }
        let duplicate = dup(descriptor)
        guard duplicate >= 0, let directory = fdopendir(duplicate) else {
            if duplicate >= 0 { Darwin.close(duplicate) }
            return .unavailableOrLimitExceeded
        }
        defer { closedir(directory) }

        var visited = 0
        var output: [DirectDirectoryEntry] = []
        output.reserveCapacity(min(maximumEntryCount, 1_024))
        errno = 0
        while let entry = readdir(directory) {
            let name = withUnsafePointer(to: entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) {
                    String(cString: $0)
                }
            }
            guard name != ".", name != ".." else {
                errno = 0
                continue
            }
            visited += 1
            guard visited <= maximumEntryCount else {
                return .unavailableOrLimitExceeded
            }
            var status = stat()
            guard name.withCString({
                fstatat(descriptor, $0, &status, AT_SYMLINK_NOFOLLOW)
            }) == 0 else {
                return .unavailableOrLimitExceeded
            }
            let isHidden = name.hasPrefix(".") || (status.st_flags & UInt32(UF_HIDDEN)) != 0
            if !isHidden {
                output.append(DirectDirectoryEntry(name: name, mode: status.st_mode))
            }
            errno = 0
        }
        guard errno == 0 else { return .unavailableOrLimitExceeded }
        return .complete(output)
    }

    // MARK: - Zip detection

    /// Peeks at a zip's entry names (no extraction) and matches the same
    /// signatures folder detection uses, allowing one leading root-folder
    /// prefix. Returns nil for any zip that fails to list or match, so the
    /// caller can warn. Reads the central directory directly.
    nonisolated static func detectInZip(at url: URL) -> DatasetDetection? {
        detectInZip(at: url, entryNameLoader: DatasetContract.archiveEntryNames)
    }

    /// Synchronous loader seam keeps exact ceiling/depth tests deterministic.
    nonisolated static func detectInZip(
        at url: URL,
        entryNameLoader: (URL) throws -> [String]
    ) -> DatasetDetection? {
        guard let names = try? entryNameLoader(url),
              names.count <= DatasetContract.maximumEntryCount,
              names.allSatisfy(DatasetContract.archivePathIsWithinDepthLimit),
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
        paths.contains(DatasetContract.nerfstudioManifestName)
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
