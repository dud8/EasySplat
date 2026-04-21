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
