import Darwin
import Foundation

struct MsplatOrientationOverlay: Sendable, Equatable {
    static let fileName = "easysplat_orientation.json"

    private let sourceToCanonicalWXYZ: [Double]

    init(canonicalOrientation: CanonicalOrientationArtifact) throws {
        switch canonicalOrientation.status {
        case .unresolved:
            guard canonicalOrientation.sourceToCanonicalQuaternionWXYZ == nil else {
                throw MsplatOrientationOverlayError.invalidOrientation
            }
            sourceToCanonicalWXYZ = [1, 0, 0, 0]
        case .verified, .axisAlignedSignUnverified:
            guard let quaternion = canonicalOrientation.sourceToCanonicalQuaternionWXYZ,
                  Self.isFiniteUnitCanonical(quaternion) else {
                throw MsplatOrientationOverlayError.invalidOrientation
            }
            sourceToCanonicalWXYZ = [
                quaternion.w,
                quaternion.x,
                quaternion.y,
                quaternion.z,
            ]
        }
    }

    func encodedData() throws -> Data {
        var data = try JSONSerialization.data(
            withJSONObject: [
                "schema_version": 1,
                "source_to_canonical_wxyz": sourceToCanonicalWXYZ,
            ],
            options: [.sortedKeys]
        )
        data.append(0x0A)
        return data
    }

    static func write(
        canonicalOrientation: CanonicalOrientationArtifact,
        to sparseDirectory: URL
    ) throws {
        let overlay = try MsplatOrientationOverlay(canonicalOrientation: canonicalOrientation)
        try overlay.write(to: sparseDirectory)
    }

    private func write(to sparseDirectory: URL) throws {
        let data = try encodedData()
        let directory = try Self.openDirectory(at: sparseDirectory)
        defer { Darwin.close(directory) }

        let original = try Self.entryIdentity(named: Self.fileName, in: directory)
        let temporaryName = ".easysplat-orientation-\(UUID().uuidString).tmp"
        let temporary = try Self.createTemporaryFile(named: temporaryName, in: directory)
        var shouldRemoveTemporary = true
        defer {
            Darwin.close(temporary)
            if shouldRemoveTemporary {
                temporaryName.withCString { _ = unlinkat(directory, $0, 0) }
            }
        }

        try Self.writeAll(data, to: temporary)
        guard fchmod(temporary, mode_t(S_IRUSR | S_IWUSR)) == 0 else {
            throw MsplatOrientationOverlayError.posix(errno)
        }
        try Self.synchronize(temporary)
        let written = try Self.fileStatus(for: temporary)
        guard (written.st_mode & S_IFMT) == S_IFREG,
              written.st_nlink == 1,
              written.st_size == data.count,
              written.st_mode & mode_t(0o777) == mode_t(S_IRUSR | S_IWUSR) else {
            throw MsplatOrientationOverlayError.invalidDestination
        }

        let current = try Self.entryIdentity(named: Self.fileName, in: directory)
        guard current == original else {
            throw MsplatOrientationOverlayError.destinationChanged
        }

        let renameResult = temporaryName.withCString { temporaryNamePointer in
            Self.fileName.withCString { destinationNamePointer in
                renameat(
                    directory,
                    temporaryNamePointer,
                    directory,
                    destinationNamePointer
                )
            }
        }
        guard renameResult == 0 else {
            throw MsplatOrientationOverlayError.posix(errno)
        }
        shouldRemoveTemporary = false
        try Self.synchronize(directory)

        let installed = try Self.entryIdentity(named: Self.fileName, in: directory)
        guard let installed,
              installed.device == UInt64(bitPattern: Int64(written.st_dev)),
              installed.inode == UInt64(written.st_ino),
              installed.linkCount == 1,
              installed.size == data.count,
              installed.permissions == mode_t(S_IRUSR | S_IWUSR) else {
            throw MsplatOrientationOverlayError.invalidDestination
        }
    }

    private static func isFiniteUnitCanonical(_ quaternion: CanonicalQuaternionWXYZ) -> Bool {
        let values = [quaternion.w, quaternion.x, quaternion.y, quaternion.z]
        guard values.allSatisfy(\.isFinite) else { return false }
        let squaredNorm = values.reduce(0) { $0 + $1 * $1 }
        guard abs(squaredNorm - 1) <= 1e-6 else { return false }
        if quaternion.w > 0 { return true }
        if quaternion.w < 0 { return false }
        for value in [quaternion.x, quaternion.y, quaternion.z] where value != 0 {
            return value > 0
        }
        return false
    }

    private struct EntryIdentity: Equatable {
        let device: UInt64
        let inode: UInt64
        let linkCount: UInt16
        let size: Int
        let permissions: mode_t
        let modifiedSeconds: Int
        let modifiedNanoseconds: Int
        let changedSeconds: Int
        let changedNanoseconds: Int

        init(_ status: stat) throws {
            guard (status.st_mode & S_IFMT) == S_IFREG,
                  status.st_nlink == 1,
                  status.st_size >= 0,
                  status.st_size <= Int.max else {
                throw MsplatOrientationOverlayError.invalidDestination
            }
            device = UInt64(bitPattern: Int64(status.st_dev))
            inode = UInt64(status.st_ino)
            linkCount = status.st_nlink
            size = Int(status.st_size)
            permissions = status.st_mode & mode_t(0o777)
            modifiedSeconds = status.st_mtimespec.tv_sec
            modifiedNanoseconds = status.st_mtimespec.tv_nsec
            changedSeconds = status.st_ctimespec.tv_sec
            changedNanoseconds = status.st_ctimespec.tv_nsec
        }
    }

    private static func openDirectory(at url: URL) throws -> Int32 {
        while true {
            let descriptor = Darwin.open(
                url.path,
                O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
            )
            if descriptor >= 0 { return descriptor }
            let code = errno
            if code == EINTR { continue }
            if code == ELOOP || code == ENOTDIR {
                throw MsplatOrientationOverlayError.invalidDestination
            }
            throw MsplatOrientationOverlayError.posix(code)
        }
    }

    private static func createTemporaryFile(named name: String, in directory: Int32) throws -> Int32 {
        while true {
            let descriptor = name.withCString {
                openat(
                    directory,
                    $0,
                    O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
                    mode_t(S_IRUSR | S_IWUSR)
                )
            }
            if descriptor >= 0 { return descriptor }
            let code = errno
            if code == EINTR { continue }
            throw MsplatOrientationOverlayError.posix(code)
        }
    }

    private static func entryIdentity(named name: String, in directory: Int32) throws -> EntryIdentity? {
        while true {
            var status = stat()
            let result = name.withCString {
                fstatat(directory, $0, &status, AT_SYMLINK_NOFOLLOW)
            }
            if result == 0 { return try EntryIdentity(status) }
            let code = errno
            if code == EINTR { continue }
            if code == ENOENT { return nil }
            throw MsplatOrientationOverlayError.posix(code)
        }
    }

    private static func fileStatus(for descriptor: Int32) throws -> stat {
        while true {
            var status = stat()
            if fstat(descriptor, &status) == 0 { return status }
            let code = errno
            if code == EINTR { continue }
            throw MsplatOrientationOverlayError.posix(code)
        }
    }

    private static func writeAll(_ data: Data, to descriptor: Int32) throws {
        try data.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return }
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(
                    descriptor,
                    base.advanced(by: offset),
                    bytes.count - offset
                )
                if count < 0, errno == EINTR { continue }
                guard count > 0 else {
                    throw MsplatOrientationOverlayError.posix(errno)
                }
                offset += count
            }
        }
    }

    private static func synchronize(_ descriptor: Int32) throws {
        while true {
            if fsync(descriptor) == 0 { return }
            let code = errno
            if code == EINTR { continue }
            throw MsplatOrientationOverlayError.posix(code)
        }
    }
}

private enum MsplatOrientationOverlayError: Error, LocalizedError {
    case invalidOrientation
    case invalidDestination
    case destinationChanged
    case posix(Int32)

    var errorDescription: String? {
        switch self {
        case .invalidOrientation:
            return "The canonical training orientation is invalid."
        case .invalidDestination:
            return "The training orientation file is not a private ordinary file."
        case .destinationChanged:
            return "The training orientation file changed while it was prepared."
        case .posix(let code):
            return String(cString: strerror(code))
        }
    }
}
