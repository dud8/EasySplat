import EasySplatCore
import Foundation
import UniformTypeIdentifiers

extension AppModel {
    func startWithVideo(url: URL) {
        clearPendingInputs()
        addInputs(urls: [url])
    }

    func startWithPhotoFolder(url: URL) {
        clearPendingInputs()
        addInputs(urls: [url])
    }

    func addInputs(urls: [URL]) {
        var newVideos: [URL] = []
        var newFolders: [URL] = []
        var seenFolderPaths: Set<String> = []
        var ignoredFiles: [URL] = []
        for url in urls {
            if url.hasDirectoryPath {
                let path = url.standardizedFileURL.path
                if seenFolderPaths.insert(path).inserted {
                    newFolders.append(url)
                }
            } else if let type = UTType(filenameExtension: url.pathExtension),
                      type.conforms(to: .movie) || type.conforms(to: .video) {
                newVideos.append(url)
            } else {
                ignoredFiles.append(url)
            }
        }

        if !newVideos.isEmpty {
            let existing = Set(pendingVideoURLs.map(\.path))
            let merged = pendingVideoURLs + newVideos.filter { !existing.contains($0.path) }
            pendingVideoURLs = merged
        }
        let newFolder = newFolders.first
        if let newFolder {
            pendingPhotosFolderURL = newFolder
        }

        var warnings: [String] = []
        if !ignoredFiles.isEmpty {
            warnings.append("Ignored \(ignoredFiles.count) file(s). Supported: video files and a photo folder.")
        }
        let additionalFolderCount = max(0, newFolders.count - 1)
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
            warnings.append("Continuous sequence works with one video. Input Order was reset to Automatic.")
        }
        selectionWarning = warnings.isEmpty ? nil : warnings.joined(separator: "\n")
        if let newFolder {
            schedulePhotoFolderCount(for: newFolder)
        }
    }

    /// Recommended floor used by the pre-flight check. Phrased as a quality
    /// recommendation rather than a hard minimum because the pipeline only
    /// fails outright below 2 selected frames.
    nonisolated static let minimumRecommendedPhotos: Int = 12

    /// Count non-hidden image files in a folder. Recurses into subdirectories
    /// to match the pipeline's photo discovery, but stops as soon as the UI's
    /// recommendation threshold is met. Returns nil when the folder cannot be enumerated.
    nonisolated static func countImageFiles(
        in folder: URL,
        maximumVisitedEntries: Int = 4_096
    ) -> Int? {
        guard maximumVisitedEntries > 0, !Task.isCancelled else { return nil }
        let allowedExtensions: Set<String> = ["jpg", "jpeg", "png", "heic", "heif"]
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
            if allowedExtensions.contains(url.pathExtension.lowercased()) {
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
            let message = "\"\(folder.lastPathComponent)\" has \(count) image file\(count == 1 ? "" : "s"). \(Self.minimumRecommendedPhotos)+ images is the recommended floor for a high-coverage solve, but EasySplat will still attempt the run."
            if let warning = self.selectionWarning, !warning.isEmpty {
                self.selectionWarning = warning + "\n" + message
            } else {
                self.selectionWarning = message
            }
        }
    }
}
