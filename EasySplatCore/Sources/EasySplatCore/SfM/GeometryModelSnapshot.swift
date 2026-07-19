import CryptoKit
import Darwin
import Foundation

/// Binds the accepted COLMAP text model to the exact files measured by the
/// residual analyzer. Validation is stat-only after the initial stable hash.
enum GeometryModelSnapshot {
    enum Error: Swift.Error, LocalizedError, Equatable {
        case unsafeModel
        case modelChanged

        var errorDescription: String? {
            switch self {
            case .unsafeModel:
                return "The geometry model is not an ordinary private directory."
            case .modelChanged:
                return "The geometry model changed after it was measured."
            }
        }
    }

    struct Verified: Sendable {
        fileprivate let state: DirectoryState

        var modelHashes: [String: String] {
            state.files.mapValues(\.sha256)
        }
    }

    fileprivate struct DirectoryIdentity: Sendable, Equatable {
        let device: UInt64
        let inode: UInt64
    }

    fileprivate struct Timestamp: Sendable, Equatable {
        let seconds: Int64
        let nanoseconds: Int64

        init(_ value: timespec) {
            seconds = Int64(value.tv_sec)
            nanoseconds = Int64(value.tv_nsec)
        }
    }

    fileprivate struct FileState: Sendable {
        let device: UInt64
        let inode: UInt64
        let byteCount: UInt64
        let modifiedAt: Timestamp
        let changedAt: Timestamp
        let sha256: String
    }

    fileprivate struct DirectoryState: Sendable {
        let identity: DirectoryIdentity
        let files: [String: FileState]
    }

    private static let requiredFiles = ["cameras.txt", "images.txt", "points3D.txt"]
    private static let cancellationIntervalBytes: UInt64 = 4 * 1_024 * 1_024

    static func capture(
        in directory: URL,
        checkCancellation: () throws -> Void = {}
    ) throws -> Verified {
        let descriptor = try openDirectory(at: directory)
        defer { Darwin.close(descriptor) }

        let initial = try status(of: descriptor)
        guard (initial.st_mode & S_IFMT) == S_IFDIR else { throw Error.unsafeModel }
        let identity = directoryIdentity(initial)
        let files = try Dictionary(uniqueKeysWithValues: requiredFiles.map { name in
            (
                name,
                try captureFile(
                    named: name,
                    in: descriptor,
                    checkCancellation: checkCancellation
                )
            )
        })
        let state = DirectoryState(identity: identity, files: files)
        guard try matches(state, directoryDescriptor: descriptor) else {
            throw Error.modelChanged
        }
        return Verified(state: state)
    }

    static func validate(_ snapshot: Verified, at directory: URL) throws {
        let descriptor: Int32
        do {
            descriptor = try openDirectory(at: directory)
        } catch {
            throw Error.modelChanged
        }
        defer { Darwin.close(descriptor) }
        guard try matches(snapshot.state, directoryDescriptor: descriptor) else {
            throw Error.modelChanged
        }
    }

    private static func captureFile(
        named name: String,
        in directory: Int32,
        checkCancellation: () throws -> Void
    ) throws -> FileState {
        let descriptor = try openFile(named: name, in: directory)
        defer { Darwin.close(descriptor) }
        let initial = try status(of: descriptor)
        guard isPrivateRegularFile(initial) else { throw Error.unsafeModel }

        let expectedByteCount = UInt64(initial.st_size)
        var consumed: UInt64 = 0
        var nextCancellationCheck = cancellationIntervalBytes
        var digest = SHA256()
        var buffer = [UInt8](repeating: 0, count: 1_048_576)
        while true {
            let count = buffer.withUnsafeMutableBytes { bytes in
                Darwin.read(descriptor, bytes.baseAddress, bytes.count)
            }
            if count < 0, errno == EINTR { continue }
            guard count >= 0 else { throw posixError() }
            if count == 0 { break }
            guard consumed <= expectedByteCount,
                  UInt64(count) <= expectedByteCount - consumed else {
                throw Error.modelChanged
            }
            digest.update(data: Data(buffer[0..<count]))
            consumed += UInt64(count)
            if consumed >= nextCancellationCheck {
                try checkCancellation()
                nextCancellationCheck += cancellationIntervalBytes
            }
        }

        let final = try status(of: descriptor)
        guard stable(final, matches: initial), consumed == expectedByteCount else {
            throw Error.modelChanged
        }
        return FileState(
            device: UInt64(bitPattern: Int64(initial.st_dev)),
            inode: UInt64(initial.st_ino),
            byteCount: expectedByteCount,
            modifiedAt: Timestamp(initial.st_mtimespec),
            changedAt: Timestamp(initial.st_ctimespec),
            sha256: digest.finalize().map { String(format: "%02x", $0) }.joined()
        )
    }

    private static func matches(_ state: DirectoryState, directoryDescriptor: Int32) throws -> Bool {
        guard directoryIdentity(try status(of: directoryDescriptor)) == state.identity,
              state.files.keys.sorted() == requiredFiles.sorted() else {
            return false
        }
        for name in requiredFiles {
            guard let expected = state.files[name],
                  try fileMatches(named: name, in: directoryDescriptor, expected: expected) else {
                return false
            }
        }
        return directoryIdentity(try status(of: directoryDescriptor)) == state.identity
    }

    private static func fileMatches(
        named name: String,
        in directory: Int32,
        expected: FileState
    ) throws -> Bool {
        let descriptor: Int32
        do {
            descriptor = try openFile(named: name, in: directory)
        } catch {
            return false
        }
        defer { Darwin.close(descriptor) }
        let current = try status(of: descriptor)
        return isPrivateRegularFile(current)
            && UInt64(bitPattern: Int64(current.st_dev)) == expected.device
            && UInt64(current.st_ino) == expected.inode
            && UInt64(current.st_size) == expected.byteCount
            && Timestamp(current.st_mtimespec) == expected.modifiedAt
            && Timestamp(current.st_ctimespec) == expected.changedAt
    }

    private static func openDirectory(at url: URL) throws -> Int32 {
        while true {
            let descriptor = Darwin.open(
                url.path,
                O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
            )
            if descriptor >= 0 { return descriptor }
            if errno == EINTR { continue }
            if errno == ELOOP || errno == ENOTDIR { throw Error.unsafeModel }
            throw posixError()
        }
    }

    private static func openFile(named name: String, in directory: Int32) throws -> Int32 {
        while true {
            let descriptor = openat(directory, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
            if descriptor >= 0 { return descriptor }
            if errno == EINTR { continue }
            if errno == ELOOP { throw Error.unsafeModel }
            throw posixError()
        }
    }

    private static func status(of descriptor: Int32) throws -> stat {
        while true {
            var value = stat()
            if fstat(descriptor, &value) == 0 { return value }
            if errno == EINTR { continue }
            throw posixError()
        }
    }

    private static func isPrivateRegularFile(_ value: stat) -> Bool {
        (value.st_mode & S_IFMT) == S_IFREG && value.st_nlink == 1 && value.st_size >= 0
    }

    private static func stable(_ current: stat, matches expected: stat) -> Bool {
        isPrivateRegularFile(current)
            && current.st_dev == expected.st_dev
            && current.st_ino == expected.st_ino
            && current.st_size == expected.st_size
            && current.st_mtimespec.tv_sec == expected.st_mtimespec.tv_sec
            && current.st_mtimespec.tv_nsec == expected.st_mtimespec.tv_nsec
            && current.st_ctimespec.tv_sec == expected.st_ctimespec.tv_sec
            && current.st_ctimespec.tv_nsec == expected.st_ctimespec.tv_nsec
    }

    private static func directoryIdentity(_ value: stat) -> DirectoryIdentity {
        DirectoryIdentity(
            device: UInt64(bitPattern: Int64(value.st_dev)),
            inode: UInt64(value.st_ino)
        )
    }

    private static func posixError() -> NSError {
        NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
    }
}
