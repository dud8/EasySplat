import Darwin
import EasySplatCore
import Foundation
import UniformTypeIdentifiers

extension AppModel {
    private static let supportedVideoExtensions: Set<String> = [
        "3gp", "avi", "m2ts", "m4v", "mkv", "mov", "mp4", "mpeg", "mpg", "mts", "qt",
    ]

    private enum SelectedInputKind: Hashable {
        case regularFile
        case directory
        case unsupported
    }

    private struct SelectedInputIdentity: Hashable {
        enum Storage: Hashable {
            case fileSystem(device: UInt64, inode: UInt64)
            case resolvedPath(String)
        }

        let kind: SelectedInputKind
        let storage: Storage
    }

    private struct ClassifiedInput {
        let kind: SelectedInputKind
        let identity: SelectedInputIdentity?
    }

    func startWithVideo(url: URL) {
        clearPendingInputs()
        addInputs(urls: [url])
    }

    func startWithPhotoFolder(url: URL) {
        clearPendingInputs()
        addInputs(urls: [url])
    }

    /// Accepts any mix of photo files, video files, and folders. A folder is
    /// expanded into the compatible photos and videos it contains, so a single
    /// capture folder with both kinds of media brings all of it in. Photos and
    /// videos coming from different folders are merged into one selection.
    func addInputs(urls: [URL]) {
        var videoIdentities = Set(pendingVideoURLs.compactMap { Self.classifyInput($0).identity })
        var photoIdentities = Set(pendingPhotoURLs.compactMap { Self.classifyInput($0).identity })

        var newVideos: [URL] = []
        var newPhotos: [URL] = []
        var ignoredFileCount = 0

        func admitVideo(_ url: URL) {
            guard let identity = Self.classifyInput(url).identity,
                  videoIdentities.insert(identity).inserted else { return }
            newVideos.append(url)
        }
        func admitPhoto(_ url: URL) {
            guard let identity = Self.classifyInput(url).identity,
                  photoIdentities.insert(identity).inserted else { return }
            newPhotos.append(url)
        }

        for url in urls {
            let input = Self.classifyInput(url)
            switch input.kind {
            case .directory:
                let expanded = Self.expandFolder(url)
                expanded.videos.forEach(admitVideo)
                expanded.images.forEach(admitPhoto)
            case .regularFile:
                if Self.isSupportedVideo(url) {
                    admitVideo(url)
                } else if Self.isSupportedImage(url) {
                    admitPhoto(url)
                } else {
                    ignoredFileCount += 1
                }
            case .unsupported:
                ignoredFileCount += 1
            }
        }

        pendingVideoURLs.append(contentsOf: newVideos)
        pendingPhotoURLs.append(contentsOf: newPhotos)

        var warnings: [String] = []
        if ignoredFileCount > 0 {
            let noun = ignoredFileCount == 1 ? "file" : "files"
            warnings.append(
                "Ignored \(ignoredFileCount) \(noun). Supported: photos, videos, or folders of them."
            )
        }
        if requestedRunOptions.inputOrdering == .continuous,
           let input = buildInputSpec(),
           !RunPlanResolver.supports(inputOrdering: .continuous, input: input) {
            requestedRunOptions.inputOrdering = .automatic
            warnings.append("Continuous sequence can't combine videos and photos. Input Order was reset to Automatic.")
        }
        if let hint = lowPhotoCountWarning() {
            warnings.append(hint)
        }
        selectionWarning = warnings.isEmpty ? nil : warnings.joined(separator: "\n")
    }

    /// A short quality hint when a photo-only selection is thin. Photos beside a
    /// video are optional, so no floor applies then.
    private func lowPhotoCountWarning() -> String? {
        guard pendingVideoURLs.isEmpty else { return nil }
        let count = pendingPhotoURLs.count
        guard count > 0, count < Self.minimumRecommendedPhotos else { return nil }
        let countText = "\(count) \(count == 1 ? "photo" : "photos")"
        if count < RunPlanResolver.minimumReconstructionImageCount {
            return "Selected \(countText). Add at least \(RunPlanResolver.minimumReconstructionImageCount) from different viewpoints."
        }
        return "Selected \(countText). \(Self.minimumRecommendedPhotos) or more is recommended for reliable coverage."
    }

    private static func classifyInput(_ url: URL) -> ClassifiedInput {
        var linkStatus = stat()
        let linkResult: Int32 = url.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return -1 }
            return Darwin.lstat(path, &linkStatus)
        }

        if linkResult == 0 {
            let linkKind = linkStatus.st_mode & S_IFMT
            if linkKind == S_IFLNK {
                let resolvedURL = url.standardizedFileURL.resolvingSymlinksInPath()
                var targetStatus = stat()
                let targetResult: Int32 = resolvedURL.withUnsafeFileSystemRepresentation { path -> Int32 in
                    guard let path else { return -1 }
                    return Darwin.lstat(path, &targetStatus)
                }
                guard targetResult == 0 else {
                    return ClassifiedInput(kind: .unsupported, identity: nil)
                }
                return classifiedInput(from: targetStatus)
            }
            return classifiedInput(from: linkStatus)
        }

        let kind: SelectedInputKind
        if url.hasDirectoryPath {
            kind = .directory
        } else if isSupportedVideo(url) || isSupportedImage(url) {
            kind = .regularFile
        } else {
            kind = .unsupported
        }
        guard kind != .unsupported else {
            return ClassifiedInput(kind: .unsupported, identity: nil)
        }
        let resolvedPath = url.standardizedFileURL.resolvingSymlinksInPath().path
        return ClassifiedInput(
            kind: kind,
            identity: SelectedInputIdentity(kind: kind, storage: .resolvedPath(resolvedPath))
        )
    }

    private static func classifiedInput(from status: stat) -> ClassifiedInput {
        let fileType = status.st_mode & S_IFMT
        let kind: SelectedInputKind
        if fileType == S_IFREG {
            kind = .regularFile
        } else if fileType == S_IFDIR {
            kind = .directory
        } else {
            return ClassifiedInput(kind: .unsupported, identity: nil)
        }
        return ClassifiedInput(
            kind: kind,
            identity: SelectedInputIdentity(
                kind: kind,
                storage: .fileSystem(
                    device: UInt64(status.st_dev),
                    inode: UInt64(status.st_ino)
                )
            )
        )
    }

    private static func isSupportedVideo(_ url: URL) -> Bool {
        let pathExtension = url.pathExtension.lowercased()
        if supportedVideoExtensions.contains(pathExtension) {
            return true
        }
        guard let type = UTType(filenameExtension: pathExtension) else {
            return false
        }
        return type.conforms(to: .movie) || type.conforms(to: .video)
    }

    /// Matches what photo admission accepts: anything conforming to `public.image`
    /// by its extension, which includes JPEG, PNG, HEIC, and camera RAW.
    static func isSupportedImage(_ url: URL) -> Bool {
        guard let type = UTType(filenameExtension: url.pathExtension.lowercased()) else {
            return false
        }
        return type.conforms(to: .image)
    }

    /// Enumerates a selected folder for the photos and videos it holds. Mirrors
    /// the pipeline's photo discovery: bounded depth, hidden files skipped, and a
    /// project bundle's own output directories excluded so a re-selected project
    /// doesn't ingest its generated frames. Symlinks are skipped here so photo
    /// admission's fail-closed symlink rejection is never tripped by expansion.
    private static func expandFolder(_ folder: URL) -> (images: [URL], videos: [URL]) {
        let fileManager = FileManager.default
        guard let enumerator = fileManager.enumerator(
            at: folder,
            includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey, .nameKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants],
            errorHandler: { _, _ in true }
        ) else {
            return ([], [])
        }
        let maxDepth = 3
        let maxVisitedEntries = 50_000
        let normalizedRoot = folder.standardizedFileURL
        let looksLikeProjectRoot = fileManager.fileExists(
            atPath: folder.appendingPathComponent("project.json").path
        )
        let excludedProjectDirectories: Set<String> = looksLikeProjectRoot
            ? ["Frames", "SfM", "Training", "Output", "Logs"]
            : []

        var images: [URL] = []
        var videos: [URL] = []
        var visited = 0
        for case let url as URL in enumerator {
            guard visited < maxVisitedEntries else { break }
            visited += 1
            if enumerator.level > maxDepth {
                enumerator.skipDescendants()
                continue
            }
            let values = try? url.resourceValues(
                forKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey, .nameKey]
            )
            if values?.isSymbolicLink == true {
                if values?.isDirectory == true { enumerator.skipDescendants() }
                continue
            }
            if values?.isDirectory == true {
                if !excludedProjectDirectories.isEmpty,
                   url.deletingLastPathComponent().standardizedFileURL == normalizedRoot,
                   let name = values?.name,
                   excludedProjectDirectories.contains(name) {
                    enumerator.skipDescendants()
                }
                continue
            }
            guard values?.isRegularFile == true else { continue }
            if isSupportedVideo(url) {
                videos.append(url)
            } else if isSupportedImage(url) {
                images.append(url)
            }
        }
        return (images, videos)
    }

    /// Recommended floor used by the pre-flight check. Phrased as a quality
    /// recommendation rather than the pipeline's three-view hard minimum.
    nonisolated static let minimumRecommendedPhotos: Int = 12

    /// Count non-hidden image files in a folder. Recurses into subdirectories
    /// to match the pipeline's photo discovery, but stops as soon as the UI's
    /// recommendation threshold is met. Returns nil when the folder cannot be enumerated.
    nonisolated static func countImageFiles(
        in folder: URL,
        maximumVisitedEntries: Int = 4_096
    ) -> Int? {
        guard maximumVisitedEntries > 0, !Task.isCancelled else { return nil }
        let fm = FileManager.default
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: folder.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return nil
        }
        guard let enumerator = fm.enumerator(
            at: folder,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants],
            errorHandler: { _, _ in true }
        ) else {
            return nil
        }
        let maxDepth = 3
        var visitedEntries = 0
        var count = 0
        for case let url as URL in enumerator {
            guard !Task.isCancelled, visitedEntries < maximumVisitedEntries else {
                return nil
            }
            visitedEntries += 1
            if enumerator.level > maxDepth {
                enumerator.skipDescendants()
                continue
            }
            if let declaredType = UTType(filenameExtension: url.pathExtension),
               declaredType.conforms(to: .image) {
                count += 1
                if count >= minimumRecommendedPhotos {
                    return count
                }
            }
        }
        return count
    }

    func removeVideo(at offsets: IndexSet) {
        pendingVideoURLs.remove(atOffsets: offsets)
    }

    func clearPendingInputs() {
        pendingVideoURLs = []
        pendingPhotoURLs = []
        selectionWarning = nil
    }

    func removeAllPhotos() {
        pendingPhotoURLs = []
        selectionWarning = nil
    }

    func buildInputSpec() -> InputSpec? {
        let videos = pendingVideoURLs
        let photosFolder = nominalPhotosFolderPath(for: pendingPhotoURLs)
        if !videos.isEmpty, let photosFolder {
            return .mixed(videos: videos.map(\.path), photosFolder: photosFolder)
        }
        if !videos.isEmpty {
            return .video(files: videos.map(\.path))
        }
        if let photosFolder {
            return .photos(folder: photosFolder)
        }
        return nil
    }

    /// A representative directory path for a set of selected photos, used only to
    /// label the project and satisfy the pre-adoption input shape. Adoption
    /// replaces it with the controlled `Originals/Photos` location, so this value
    /// is never persisted and never walked (the file list drives preflight).
    private func nominalPhotosFolderPath(for photos: [URL]) -> String? {
        guard let first = photos.first else { return nil }
        guard photos.count > 1 else {
            return first.deletingLastPathComponent().path
        }
        let componentLists = photos.map {
            $0.deletingLastPathComponent().standardizedFileURL.pathComponents
        }
        let shortest = componentLists.map(\.count).min() ?? 0
        var shared: [String] = []
        for index in 0..<shortest {
            let component = componentLists[0][index]
            guard componentLists.allSatisfy({ $0[index] == component }) else { break }
            shared.append(component)
        }
        guard shared.count > 1 else {
            // No meaningful common ancestor (e.g. different volumes); fall back
            // to the first photo's parent so the label stays a real directory.
            return first.deletingLastPathComponent().path
        }
        return NSString.path(withComponents: shared)
    }

    func projectTitle(for input: InputSpec) -> String {
        if let firstVideo = input.videoFiles.first {
            return URL(fileURLWithPath: firstVideo).deletingPathExtension().lastPathComponent
        }
        if let photosFolder = input.photosFolder {
            return URL(fileURLWithPath: photosFolder).lastPathComponent
        }
        return "Project"
    }
}
