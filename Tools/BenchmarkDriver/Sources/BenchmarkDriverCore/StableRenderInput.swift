import CryptoKit
import Darwin
import Foundation

struct StableArtifactInput {
    let artifactRoot: URL
    let relativePath: String
    let label: String
    let fingerprint: StableFileFingerprint

    static func capture(
        artifactRoot: URL,
        relativePath: String,
        expectedSHA256: String,
        label: String
    ) throws -> StableArtifactInput {
        let descriptor = try SecureRelativeFile.open(
            root: artifactRoot,
            relativePath: relativePath,
            label: label
        )
        defer { close(descriptor) }
        let fingerprint = try StableFileFingerprint.capture(
            descriptor: descriptor,
            expectedSHA256: expectedSHA256,
            label: label
        )
        return StableArtifactInput(
            artifactRoot: artifactRoot,
            relativePath: relativePath,
            label: label,
            fingerprint: fingerprint
        )
    }

    func verifyUnchanged() throws {
        let current = try Self.capture(
            artifactRoot: artifactRoot,
            relativePath: relativePath,
            expectedSHA256: fingerprint.sha256,
            label: label
        )
        guard current.fingerprint == fingerprint else {
            throw BenchmarkDriverError.invalidJob("The \(label) changed during rendering.")
        }
    }
}

struct StableFileSnapshot {
    let directory: RenderInputSnapshotDirectory
    let filename: String
    let fingerprint: StableFileFingerprint

    var url: URL {
        directory.url.appendingPathComponent(filename, isDirectory: false)
    }

    func verifyUnchanged() throws {
        let current = try directory.fingerprint(
            filename: filename,
            expectedSHA256: fingerprint.sha256,
            label: "render source snapshot"
        )
        guard current == fingerprint else {
            throw BenchmarkDriverError.invalidJob(
                "The render source snapshot changed while the scene was loaded."
            )
        }
    }
}

final class RenderInputSnapshotDirectory {
    let url: URL
    private let descriptor: Int32

    init() throws {
        let base = FileManager.default.temporaryDirectory
            .resolvingSymlinksInPath()
            .standardizedFileURL
        var createdURL: URL?
        for _ in 0..<16 {
            let candidate = base.appendingPathComponent(
                "easysplat-render-inputs-\(UUID().uuidString)",
                isDirectory: true
            )
            if candidate.path.withCString({ mkdir($0, S_IRWXU) }) == 0 {
                createdURL = candidate
                break
            }
            if errno != EEXIST {
                throw BenchmarkDriverError.invalidJob(
                    "The protected render-input directory could not be created."
                )
            }
        }
        guard let createdURL else {
            throw BenchmarkDriverError.invalidJob(
                "The protected render-input directory could not be allocated."
            )
        }
        let directoryDescriptor = createdURL.path.withCString {
            open($0, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        }
        guard directoryDescriptor >= 0 else {
            try? FileManager.default.removeItem(at: createdURL)
            throw BenchmarkDriverError.invalidJob(
                "The protected render-input directory could not be opened."
            )
        }
        url = createdURL
        descriptor = directoryDescriptor
    }

    deinit {
        close(descriptor)
        try? FileManager.default.removeItem(at: url)
    }

    func copy(
        artifactRoot: URL,
        relativePath: String,
        expectedSHA256: String,
        filename: String
    ) throws -> StableFileSnapshot {
        guard BenchmarkRenderJob.isSafeRelativePath(filename), !filename.contains("/") else {
            throw BenchmarkDriverError.invalidJob("The render snapshot filename is unsafe.")
        }
        let source = try SecureRelativeFile.open(
            root: artifactRoot,
            relativePath: relativePath,
            label: "source PLY"
        )
        defer { close(source) }
        let destination = filename.withCString {
            openat(
                descriptor,
                $0,
                O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
                S_IRUSR
            )
        }
        guard destination >= 0 else {
            throw BenchmarkDriverError.invalidJob(
                "The protected render source snapshot could not be created."
            )
        }
        var shouldRemove = true
        defer {
            close(destination)
            if shouldRemove {
                _ = filename.withCString { unlinkat(descriptor, $0, 0) }
            }
        }

        let sourceBefore = try StableFileMetadata.read(
            descriptor: source,
            label: "source PLY"
        )
        let sha256 = try StableFileFingerprint.copyAndHash(
            source: source,
            destination: destination,
            label: "source PLY"
        )
        let sourceAfter = try StableFileMetadata.read(
            descriptor: source,
            label: "source PLY"
        )
        guard sourceBefore == sourceAfter, sha256 == expectedSHA256 else {
            throw BenchmarkDriverError.invalidJob(
                "The source PLY changed while its immutable snapshot was created."
            )
        }
        guard fsync(destination) == 0, fchmod(destination, S_IRUSR) == 0 else {
            throw BenchmarkDriverError.invalidJob(
                "The protected render source snapshot could not be sealed."
            )
        }
        let destinationMetadata = try StableFileMetadata.read(
            descriptor: destination,
            label: "render source snapshot"
        )
        let snapshot = StableFileSnapshot(
            directory: self,
            filename: filename,
            fingerprint: StableFileFingerprint(
                metadata: destinationMetadata,
                sha256: sha256
            )
        )
        shouldRemove = false
        return snapshot
    }

    func fingerprint(
        filename: String,
        expectedSHA256: String,
        label: String
    ) throws -> StableFileFingerprint {
        let file = filename.withCString {
            openat(descriptor, $0, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        }
        guard file >= 0 else {
            throw BenchmarkDriverError.invalidJob("The \(label) is missing or unsafe.")
        }
        defer { close(file) }
        return try StableFileFingerprint.capture(
            descriptor: file,
            expectedSHA256: expectedSHA256,
            label: label
        )
    }
}

struct StableFileFingerprint: Equatable {
    let metadata: StableFileMetadata
    let sha256: String

    static func capture(
        descriptor: Int32,
        expectedSHA256: String,
        label: String
    ) throws -> StableFileFingerprint {
        let before = try StableFileMetadata.read(descriptor: descriptor, label: label)
        let digest = try hash(descriptor: descriptor, label: label)
        let after = try StableFileMetadata.read(descriptor: descriptor, label: label)
        guard before == after, digest == expectedSHA256 else {
            throw BenchmarkDriverError.invalidJob("The \(label) changed while it was read.")
        }
        return StableFileFingerprint(metadata: after, sha256: digest)
    }

    static func copyAndHash(
        source: Int32,
        destination: Int32,
        label: String
    ) throws -> String {
        try stream(source: source, destination: destination, label: label)
    }

    private static func hash(descriptor: Int32, label: String) throws -> String {
        guard lseek(descriptor, 0, SEEK_SET) >= 0 else {
            throw BenchmarkDriverError.invalidJob("The \(label) could not be read safely.")
        }
        return try stream(source: descriptor, destination: nil, label: label)
    }

    private static func stream(
        source: Int32,
        destination: Int32?,
        label: String
    ) throws -> String {
        var hasher = SHA256()
        var buffer = [UInt8](repeating: 0, count: 1024 * 1024)
        while true {
            let count = buffer.withUnsafeMutableBytes { bytes in
                Darwin.read(source, bytes.baseAddress, bytes.count)
            }
            if count == 0 { break }
            if count < 0 {
                if errno == EINTR { continue }
                throw BenchmarkDriverError.invalidJob("The \(label) could not be read safely.")
            }
            hasher.update(data: Data(buffer[0..<count]))
            if let destination {
                var written = 0
                while written < count {
                    let result = buffer.withUnsafeBytes { bytes in
                        Darwin.write(
                            destination,
                            bytes.baseAddress!.advanced(by: written),
                            count - written
                        )
                    }
                    if result < 0 {
                        if errno == EINTR { continue }
                        throw BenchmarkDriverError.invalidJob(
                            "The protected render source snapshot could not be written."
                        )
                    }
                    written += result
                }
            }
        }
        return "sha256:" + hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

struct StableFileMetadata: Equatable {
    let device: UInt64
    let inode: UInt64
    let size: Int64
    let mode: UInt16
    let modifiedSeconds: Int64
    let modifiedNanoseconds: Int64
    let changedSeconds: Int64
    let changedNanoseconds: Int64

    static func read(descriptor: Int32, label: String) throws -> StableFileMetadata {
        var value = stat()
        guard fstat(descriptor, &value) == 0, (value.st_mode & S_IFMT) == S_IFREG else {
            throw BenchmarkDriverError.invalidJob("The \(label) is not a regular file.")
        }
        return StableFileMetadata(
            device: UInt64(value.st_dev),
            inode: UInt64(value.st_ino),
            size: Int64(value.st_size),
            mode: UInt16(value.st_mode),
            modifiedSeconds: Int64(value.st_mtimespec.tv_sec),
            modifiedNanoseconds: Int64(value.st_mtimespec.tv_nsec),
            changedSeconds: Int64(value.st_ctimespec.tv_sec),
            changedNanoseconds: Int64(value.st_ctimespec.tv_nsec)
        )
    }
}

private enum SecureRelativeFile {
    static func open(root: URL, relativePath: String, label: String) throws -> Int32 {
        guard BenchmarkRenderJob.isSafeRelativePath(relativePath) else {
            throw BenchmarkDriverError.invalidJob("The \(label) path is unsafe.")
        }
        var current = root.path.withCString {
            Darwin.open($0, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        }
        guard current >= 0 else {
            throw BenchmarkDriverError.invalidJob("The render artifact root is unsafe.")
        }
        let parts = relativePath.split(separator: "/").map(String.init)
        for component in parts.dropLast() {
            let next = component.withCString {
                openat(current, $0, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
            }
            close(current)
            guard next >= 0 else {
                throw BenchmarkDriverError.invalidJob(
                    "The \(label) path contains a symbolic link or invalid directory."
                )
            }
            current = next
        }
        let file = parts.last!.withCString {
            openat(current, $0, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        }
        close(current)
        guard file >= 0 else {
            throw BenchmarkDriverError.invalidJob(
                "The \(label) is missing or is a symbolic link."
            )
        }
        do {
            _ = try StableFileMetadata.read(descriptor: file, label: label)
            return file
        } catch {
            close(file)
            throw error
        }
    }
}
