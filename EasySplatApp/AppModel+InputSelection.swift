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
        var newFolder: URL?
        var ignoredFiles: [URL] = []
        for url in urls {
            if url.hasDirectoryPath {
                newFolder = url
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
        if let newFolder {
            pendingPhotosFolderURL = newFolder
        }

        if ignoredFiles.isEmpty {
            selectionWarning = nil
        } else {
            selectionWarning = "Ignored \(ignoredFiles.count) file(s). Supported: video files and a photo folder."
        }

        if let folder = newFolder, let count = AppModel.countImageFiles(in: folder), count < AppModel.minimumRecommendedPhotos {
            let message = "\"\(folder.lastPathComponent)\" has \(count) image file\(count == 1 ? "" : "s"). \(AppModel.minimumRecommendedPhotos)+ images is the recommended floor for a high-coverage solve, but EasySplat will still attempt the run."
            selectionWarning = selectionWarning.map { "\($0)\n\(message)" } ?? message
        }
    }

    /// Recommended floor used by the pre-flight check. Phrased as a quality
    /// recommendation rather than a hard minimum because the pipeline only
    /// fails outright below 2 selected frames.
    static let minimumRecommendedPhotos: Int = 12

    /// Count non-hidden image files in a folder. Recurses into subdirectories
    /// to match the pipeline's photo discovery, but caps the walk to a
    /// reasonable depth so dropping a giant unrelated folder (e.g., ~/Pictures)
    /// does not stall the UI. Returns nil when the folder cannot be enumerated.
    static func countImageFiles(in folder: URL) -> Int? {
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
        var count = 0
        for case let url as URL in enumerator {
            if enumerator.level > maxDepth {
                enumerator.skipDescendants()
                continue
            }
            if allowedExtensions.contains(url.pathExtension.lowercased()) {
                count += 1
            }
        }
        return count
    }

    func removeVideo(at offsets: IndexSet) {
        pendingVideoURLs.remove(atOffsets: offsets)
    }

    func clearPendingInputs() {
        pendingVideoURLs = []
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
}
