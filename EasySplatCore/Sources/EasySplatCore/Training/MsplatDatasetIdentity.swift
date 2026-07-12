import CryptoKit
import Darwin
import Foundation

struct MsplatDatasetIdentity: Sendable, Equatable {
    let inputDigest: String
    let geometryDigest: String

    static func compute(
        imageFiles: [URL],
        sparseDirectory: URL
    ) throws -> MsplatDatasetIdentity {
        guard !imageFiles.isEmpty else {
            throw MsplatDatasetIdentityError.emptyImageSet
        }
        let sortedImages = imageFiles.sorted { $0.lastPathComponent < $1.lastPathComponent }
        guard Set(sortedImages.map(\.lastPathComponent)).count == sortedImages.count else {
            throw MsplatDatasetIdentityError.ambiguousFileSet
        }
        let sparseFiles = ["cameras.bin", "images.bin", "points3D.bin"].map {
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
        let descriptor = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else {
            throw MsplatDatasetIdentityError.cannotRead(url.lastPathComponent)
        }
        defer { Darwin.close(descriptor) }

        var initial = stat()
        guard fstat(descriptor, &initial) == 0,
              (initial.st_mode & S_IFMT) == S_IFREG,
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
              final.st_dev == initial.st_dev,
              final.st_ino == initial.st_ino,
              final.st_size == initial.st_size,
              final.st_mtimespec.tv_sec == initial.st_mtimespec.tv_sec,
              final.st_mtimespec.tv_nsec == initial.st_mtimespec.tv_nsec,
              consumed == initial.st_size else {
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
    case cannotRead(String)
    case changedDuringRead(String)

    var errorDescription: String? {
        switch self {
        case .emptyImageSet:
            return "Training input contains no images."
        case .ambiguousFileSet:
            return "Training input contains duplicate image names."
        case .cannotRead(let name):
            return "Could not safely read training file \(name)."
        case .changedDuringRead(let name):
            return "Training file \(name) changed while its identity was computed."
        }
    }
}
