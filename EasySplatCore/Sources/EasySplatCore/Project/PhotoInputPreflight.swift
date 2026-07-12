import CoreGraphics
import CryptoKit
import Darwin
import Foundation
import ImageIO

public struct PhotoInputPreflight: Equatable, Sendable {
    public enum InspectionError: Error, LocalizedError, Equatable {
        case folderUnavailable

        public var errorDescription: String? {
            switch self {
            case .folderUnavailable:
                return "The photo folder could not be read."
            }
        }
    }

    public let discoveredPhotoCount: Int
    public let validPhotoCount: Int
    public let unreadablePhotoCount: Int
    public let duplicatePhotoCount: Int

    static let supportedExtensions: Set<String> = ["jpg", "jpeg", "png", "heic", "heif"]

    struct Inspection: Sendable {
        let summary: PhotoInputPreflight
        let validPhotos: [URL]
    }

    public static func inspect(folder: URL) throws -> PhotoInputPreflight {
        try inspect(discoveredPhotos(in: folder)).summary
    }

    static func discoveredPhotos(in directory: URL) throws -> [URL] {
        let fileManager = FileManager.default
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: directory.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw InspectionError.folderUnavailable
        }

        let normalizedRoot = directory.standardizedFileURL
        let looksLikeProjectRoot = fileManager.fileExists(
            atPath: directory.appendingPathComponent("project.json").path
        )
        let excludedProjectDirectories: Set<String> = looksLikeProjectRoot
            ? ["Frames", "SfM", "Training", "Output", "Logs"]
            : []
        guard let enumerator = fileManager.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .nameKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            throw InspectionError.folderUnavailable
        }

        var photos: [URL] = []
        for case let url as URL in enumerator {
            try Task.checkCancellation()
            let values = try? url.resourceValues(
                forKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .nameKey]
            )
            if values?.isSymbolicLink == true {
                if values?.isDirectory == true { enumerator.skipDescendants() }
                continue
            }
            if values?.isDirectory == true {
                if looksLikeProjectRoot,
                   url.deletingLastPathComponent().standardizedFileURL == normalizedRoot,
                   let name = values?.name,
                   excludedProjectDirectories.contains(name) {
                    enumerator.skipDescendants()
                }
                continue
            }
            if values?.isRegularFile == true,
               supportedExtensions.contains(url.pathExtension.lowercased()) {
                photos.append(url)
            }
        }

        return photos.sorted { lhs, rhs in
            let prefix = directory.path + "/"
            let left = lhs.path.replacingOccurrences(of: prefix, with: "")
            let right = rhs.path.replacingOccurrences(of: prefix, with: "")
            return left < right
        }
    }

    static func inspect(_ photos: [URL]) throws -> Inspection {
        var validPhotos: [URL] = []
        var seenDigests = Set<String>()
        var unreadableCount = 0
        var duplicateCount = 0
        validPhotos.reserveCapacity(photos.count)

        for photo in photos {
            try Task.checkCancellation()
            guard try isReadableImage(photo), let digest = try sha256Digest(of: photo) else {
                unreadableCount += 1
                continue
            }
            guard seenDigests.insert(digest).inserted else {
                duplicateCount += 1
                continue
            }
            validPhotos.append(photo)
        }

        return Inspection(
            summary: PhotoInputPreflight(
                discoveredPhotoCount: photos.count,
                validPhotoCount: validPhotos.count,
                unreadablePhotoCount: unreadableCount,
                duplicatePhotoCount: duplicateCount
            ),
            validPhotos: validPhotos
        )
    }

    private static func isReadableImage(_ url: URL) throws -> Bool {
        try Task.checkCancellation()
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              CGImageSourceGetCount(source) > 0,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
              let height = properties[kCGImagePropertyPixelHeight] as? NSNumber,
              width.intValue > 0,
              height.intValue > 0 else {
            return false
        }
        try Task.checkCancellation()
        let thumbnail = CGImageSourceCreateThumbnailAtIndex(
            source,
            0,
            [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 16,
                kCGImageSourceShouldCache: false,
            ] as CFDictionary
        )
        try Task.checkCancellation()
        return thumbnail != nil
    }

    static func sha256Digest(of url: URL) throws -> String? {
        try Task.checkCancellation()
        let descriptor = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { return nil }
        defer { Darwin.close(descriptor) }
        var initial = stat()
        guard fstat(descriptor, &initial) == 0,
              (initial.st_mode & S_IFMT) == S_IFREG,
              initial.st_size >= 0 else {
            return nil
        }
        var hasher = SHA256()
        var consumed: Int64 = 0
        var buffer = [UInt8](repeating: 0, count: 1_048_576)
        while true {
            try Task.checkCancellation()
            let count = buffer.withUnsafeMutableBytes { bytes in
                Darwin.read(descriptor, bytes.baseAddress, bytes.count)
            }
            if count < 0 && errno == EINTR { continue }
            guard count >= 0 else { return nil }
            if count == 0 { break }
            consumed += Int64(count)
            hasher.update(data: Data(buffer[0..<count]))
        }
        try Task.checkCancellation()
        var final = stat()
        guard fstat(descriptor, &final) == 0,
              final.st_dev == initial.st_dev,
              final.st_ino == initial.st_ino,
              final.st_size == initial.st_size,
              final.st_mtimespec.tv_sec == initial.st_mtimespec.tv_sec,
              final.st_mtimespec.tv_nsec == initial.st_mtimespec.tv_nsec,
              consumed == initial.st_size else {
            return nil
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
