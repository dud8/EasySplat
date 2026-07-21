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

    func addInputs(urls: [URL]) {
        var videoIdentities = Set(
            pendingVideoURLs.compactMap { url -> SelectedInputIdentity? in
                let input = Self.classifyInput(url)
                return input.kind == .regularFile ? input.identity : nil
            }
        )
        var folderIdentities: Set<SelectedInputIdentity> = []
        if let pendingPhotosFolderURL {
            let input = Self.classifyInput(pendingPhotosFolderURL)
            if input.kind == .directory, let identity = input.identity {
                folderIdentities.insert(identity)
            }
        }

        var newVideos: [URL] = []
        var ignoredFiles: [URL] = []
        var selectedFolder = pendingPhotosFolderURL
        var selectedFolderWasAdded = false
        var additionalFolderCount = 0
        for url in urls {
            let input = Self.classifyInput(url)
            switch input.kind {
            case .directory:
                guard let identity = input.identity,
                      folderIdentities.insert(identity).inserted else {
                    continue
                }
                if selectedFolder == nil {
                    selectedFolder = url
                    selectedFolderWasAdded = true
                } else {
                    additionalFolderCount += 1
                }
            case .regularFile:
                guard Self.isSupportedVideo(url),
                      let identity = input.identity,
                      videoIdentities.insert(identity).inserted else {
                    if !Self.isSupportedVideo(url) {
                        ignoredFiles.append(url)
                    }
                    continue
                }
                newVideos.append(url)
            case .unsupported:
                ignoredFiles.append(url)
            }
        }

        if !newVideos.isEmpty {
            pendingVideoURLs.append(contentsOf: newVideos)
        }
        pendingPhotosFolderURL = selectedFolder

        var warnings: [String] = []
        if !ignoredFiles.isEmpty {
            warnings.append("Ignored \(ignoredFiles.count) file(s). Supported: video files and a photo folder.")
        }
        if additionalFolderCount > 0 {
            let noun = additionalFolderCount == 1 ? "folder" : "folders"
            warnings.append(
                "Ignored \(additionalFolderCount) additional photo \(noun). EasySplat uses one photo folder per splat."
            )
        }

        if requestedRunOptions.inputOrdering == .continuous,
           let input = buildInputSpec(),
           !RunPlanResolver.supports(inputOrdering: .continuous, input: input) {
            requestedRunOptions.inputOrdering = .automatic
            warnings.append("Continuous sequence can't combine videos and photos. Input Order was reset to Automatic.")
        }
        selectionWarning = warnings.isEmpty ? nil : warnings.joined(separator: "\n")
        if selectedFolderWasAdded, let selectedFolder {
            schedulePhotoFolderCount(for: selectedFolder)
        }
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
        } else if isSupportedVideo(url) {
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
        photoFolderCountTask?.cancel()
        photoFolderCountTask = nil
        pendingVideoURLs = []
        pendingPhotosFolderURL = nil
        selectionWarning = nil
    }

    func removePhotoFolder() {
        photoFolderCountTask?.cancel()
        photoFolderCountTask = nil
        pendingPhotosFolderURL = nil
        selectionWarning = nil
    }

    func buildInputSpec() -> InputSpec? {
        let videos = pendingVideoURLs
        if !videos.isEmpty, let photosFolder = pendingPhotosFolderURL {
            return .mixed(videos: videos.map(\.path), photosFolder: photosFolder.path)
        }
        if !videos.isEmpty {
            return .video(files: videos.map(\.path))
        }
        if let photosFolder = pendingPhotosFolderURL {
            return .photos(folder: photosFolder.path)
        }
        return nil
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

    private func schedulePhotoFolderCount(for folder: URL) {
        photoFolderCountTask?.cancel()
        let folderIdentity = folder.standardizedFileURL
        let scan = Task.detached(priority: .utility) {
            Self.countImageFiles(in: folder)
        }
        photoFolderCountTask = Task { [weak self] in
            let count = await withTaskCancellationHandler {
                await scan.value
            } onCancel: {
                scan.cancel()
            }
            guard !Task.isCancelled, let self else { return }
            self.photoFolderCountTask = nil
            guard self.pendingPhotosFolderURL?.standardizedFileURL == folderIdentity,
                  let count,
                  count < Self.minimumRecommendedPhotos else {
                return
            }
            // A photo folder is optional beside video input, so its count is
            // neither a reconstruction floor nor a useful warning.
            guard self.pendingVideoURLs.isEmpty else { return }
            let countText = "\(count) \(count == 1 ? "photo" : "photos")"
            let message: String
            if count < RunPlanResolver.minimumReconstructionImageCount {
                message = "\"\(folder.lastPathComponent)\" has \(countText). Add at least \(RunPlanResolver.minimumReconstructionImageCount) from different viewpoints."
            } else {
                message = "\"\(folder.lastPathComponent)\" has \(countText). \(Self.minimumRecommendedPhotos) or more is recommended for reliable coverage."
            }
            if let warning = self.selectionWarning, !warning.isEmpty {
                self.selectionWarning = warning + "\n" + message
            } else {
                self.selectionWarning = message
            }
        }
    }
}
