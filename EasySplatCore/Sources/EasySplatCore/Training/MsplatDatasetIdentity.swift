import CryptoKit
import Darwin
import Foundation

struct MsplatDatasetIdentity: Sendable, Equatable {
    let inputDigest: String
    let geometryDigest: String

    private static let supportedImageExtensions: Set<String> = ["jpg", "jpeg", "png"]

    static func compute(
        imageDirectory: URL,
        sparseDirectory: URL
    ) throws -> MsplatDatasetIdentity {
        let entries = try FileManager.default.contentsOfDirectory(
            at: imageDirectory,
            includingPropertiesForKeys: nil,
            options: []
        )
        for entry in entries {
            guard !entry.lastPathComponent.hasPrefix("."),
                  supportedImageExtensions.contains(entry.pathExtension.lowercased()) else {
                throw MsplatDatasetIdentityError.unsupportedImageEntry(entry.lastPathComponent)
            }
        }
        return try compute(imageFiles: entries, sparseDirectory: sparseDirectory)
    }

    static func compute(
        imageFiles: [URL],
        sparseDirectory: URL
    ) throws -> MsplatDatasetIdentity {
        guard !imageFiles.isEmpty else {
            throw MsplatDatasetIdentityError.emptyImageSet
        }
        let sortedImages = imageFiles.sorted {
            $0.lastPathComponent.utf8.lexicographicallyPrecedes($1.lastPathComponent.utf8)
        }
        guard Set(sortedImages.map { Data($0.lastPathComponent.utf8) }).count
                == sortedImages.count else {
            throw MsplatDatasetIdentityError.ambiguousFileSet
        }
        let sparseFiles = [
            "cameras.bin",
            "images.bin",
            "points3D.bin",
            MsplatOrientationOverlay.fileName,
        ].map {
            sparseDirectory.appendingPathComponent($0)
        }
        return MsplatDatasetIdentity(
            inputDigest: try digest(sortedImages),
            geometryDigest: try digest(sparseFiles)
        )
    }

    private static func digest(_ files: [URL]) throws -> String {
        var digest = SHA256()
        digest.update(data: Data("EasySplat file digest v1".utf8))
        for file in files {
            let name = Data(file.lastPathComponent.utf8)
            updateInteger(UInt64(name.count), digest: &digest)
            digest.update(data: name)
            try updateFile(file, digest: &digest)
        }
        return digest.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func updateFile(_ url: URL, digest: inout SHA256) throws {
        let descriptor = Darwin.open(
            url.path,
            O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC
        )
        guard descriptor >= 0 else {
            throw MsplatDatasetIdentityError.cannotRead(url.lastPathComponent)
        }
        defer { Darwin.close(descriptor) }

        var initial = stat()
        guard fstat(descriptor, &initial) == 0,
              (initial.st_mode & S_IFMT) == S_IFREG,
              initial.st_nlink == 1,
              initial.st_size >= 0 else {
            throw MsplatDatasetIdentityError.cannotRead(url.lastPathComponent)
        }
        updateInteger(UInt64(initial.st_size), digest: &digest)

        var consumed: Int64 = 0
        var buffer = [UInt8](repeating: 0, count: 1_048_576)
        while true {
            let count = buffer.withUnsafeMutableBytes { bytes in
                Darwin.read(descriptor, bytes.baseAddress, bytes.count)
            }
            if count < 0 && errno == EINTR { continue }
            guard count >= 0 else {
                throw MsplatDatasetIdentityError.cannotRead(url.lastPathComponent)
            }
            if count == 0 { break }
            consumed += Int64(count)
            digest.update(data: Data(buffer[0..<count]))
        }

        var final = stat()
        guard fstat(descriptor, &final) == 0,
              (final.st_mode & S_IFMT) == S_IFREG,
              final.st_nlink == 1,
              final.st_dev == initial.st_dev,
              final.st_ino == initial.st_ino,
              final.st_size == initial.st_size,
              final.st_mtimespec.tv_sec == initial.st_mtimespec.tv_sec,
              final.st_mtimespec.tv_nsec == initial.st_mtimespec.tv_nsec,
              final.st_ctimespec.tv_sec == initial.st_ctimespec.tv_sec,
              final.st_ctimespec.tv_nsec == initial.st_ctimespec.tv_nsec,
              consumed == initial.st_size else {
            throw MsplatDatasetIdentityError.changedDuringRead(url.lastPathComponent)
        }

        var installed = stat()
        guard lstat(url.path, &installed) == 0,
              (installed.st_mode & S_IFMT) == S_IFREG,
              installed.st_nlink == 1,
              installed.st_dev == final.st_dev,
              installed.st_ino == final.st_ino,
              installed.st_size == final.st_size,
              installed.st_mtimespec.tv_sec == final.st_mtimespec.tv_sec,
              installed.st_mtimespec.tv_nsec == final.st_mtimespec.tv_nsec,
              installed.st_ctimespec.tv_sec == final.st_ctimespec.tv_sec,
              installed.st_ctimespec.tv_nsec == final.st_ctimespec.tv_nsec else {
            throw MsplatDatasetIdentityError.changedDuringRead(url.lastPathComponent)
        }
    }

    private static func updateInteger(_ value: UInt64, digest: inout SHA256) {
        var bigEndian = value.bigEndian
        withUnsafeBytes(of: &bigEndian) { bytes in
            digest.update(data: Data(bytes))
        }
    }
}

private enum MsplatDatasetIdentityError: Error, LocalizedError {
    case emptyImageSet
    case ambiguousFileSet
    case unsupportedImageEntry(String)
    case cannotRead(String)
    case changedDuringRead(String)

    var errorDescription: String? {
        switch self {
        case .emptyImageSet:
            return "Training input contains no images."
        case .ambiguousFileSet:
            return "Training input contains duplicate image names."
        case .unsupportedImageEntry(let name):
            return "Training input contains an unsupported entry named \(name)."
        case .cannotRead(let name):
            return "Could not safely read training file \(name)."
        case .changedDuringRead(let name):
            return "Training file \(name) changed while its identity was computed."
        }
    }
}
