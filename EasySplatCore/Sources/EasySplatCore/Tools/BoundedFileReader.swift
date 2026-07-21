import Darwin
import Foundation

public enum BoundedFileReader {
    static func isMissingFileError(_ error: Error) -> Bool {
        guard let error = error as? BoundedFileReadError,
              case .cannotOpen(_, let code) = error else {
            return false
        }
        return code == ENOENT
    }

    public static func readRegularFile(at url: URL, maximumBytes: Int) throws -> Data {
        guard maximumBytes >= 0 else { throw BoundedFileReadError.invalidLimit }
        let descriptor = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else {
            throw BoundedFileReadError.cannotOpen(url.lastPathComponent, errno)
        }
        defer { Darwin.close(descriptor) }

        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0,
              (metadata.st_mode & S_IFMT) == S_IFREG,
              metadata.st_nlink == 1,
              metadata.st_size >= 0,
              metadata.st_size <= off_t(maximumBytes) else {
            throw BoundedFileReadError.notBoundedRegularFile(url.lastPathComponent)
        }
        let initialSize = metadata.st_size
        var data = Data()
        data.reserveCapacity(Int(initialSize))
        var buffer = [UInt8](repeating: 0, count: min(1_048_576, maximumBytes + 1))
        if buffer.isEmpty { buffer = [0] }

        while true {
            let count = buffer.withUnsafeMutableBytes { bytes in
                Darwin.read(descriptor, bytes.baseAddress, bytes.count)
            }
            if count < 0 && errno == EINTR { continue }
            guard count >= 0 else {
                throw BoundedFileReadError.cannotRead(url.lastPathComponent, errno)
            }
            if count == 0 { break }
            guard data.count <= maximumBytes - count else {
                throw BoundedFileReadError.notBoundedRegularFile(url.lastPathComponent)
            }
            data.append(contentsOf: buffer[0..<count])
        }

        var finalMetadata = stat()
        guard fstat(descriptor, &finalMetadata) == 0,
              (finalMetadata.st_mode & S_IFMT) == S_IFREG,
              finalMetadata.st_nlink == 1,
              finalMetadata.st_size == initialSize,
              data.count == Int(initialSize) else {
            throw BoundedFileReadError.changedDuringRead(url.lastPathComponent)
        }
        return data
    }

    public static func readRegularFileTail(
        at url: URL,
        maximumBytes: Int
    ) throws -> (data: Data, startsAtFileBeginning: Bool) {
        guard maximumBytes >= 0 else { throw BoundedFileReadError.invalidLimit }
        let descriptor = Darwin.open(
            url.path,
            O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC
        )
        guard descriptor >= 0 else {
            throw BoundedFileReadError.cannotOpen(url.lastPathComponent, errno)
        }
        defer { Darwin.close(descriptor) }

        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0,
              (metadata.st_mode & S_IFMT) == S_IFREG,
              metadata.st_nlink == 1,
              metadata.st_size >= 0 else {
            throw BoundedFileReadError.notBoundedRegularFile(url.lastPathComponent)
        }

        let initialSize = metadata.st_size
        let readLength = min(initialSize, off_t(maximumBytes))
        let offset = initialSize - readLength
        var data = Data(count: Int(readLength))
        var bytesRead = 0
        while bytesRead < data.count {
            let count = data.withUnsafeMutableBytes { bytes in
                Darwin.pread(
                    descriptor,
                    bytes.baseAddress?.advanced(by: bytesRead),
                    bytes.count - bytesRead,
                    offset + off_t(bytesRead)
                )
            }
            if count < 0 && errno == EINTR { continue }
            guard count > 0 else {
                if count < 0 {
                    throw BoundedFileReadError.cannotRead(url.lastPathComponent, errno)
                }
                throw BoundedFileReadError.changedDuringRead(url.lastPathComponent)
            }
            bytesRead += count
        }

        var finalMetadata = stat()
        guard fstat(descriptor, &finalMetadata) == 0,
              (finalMetadata.st_mode & S_IFMT) == S_IFREG,
              finalMetadata.st_nlink == 1,
              finalMetadata.st_size == initialSize else {
            throw BoundedFileReadError.changedDuringRead(url.lastPathComponent)
        }
        return (data, offset == 0)
    }
}

private enum BoundedFileReadError: Error, LocalizedError {
    case invalidLimit
    case cannotOpen(String, Int32)
    case cannotRead(String, Int32)
    case notBoundedRegularFile(String)
    case changedDuringRead(String)

    var errorDescription: String? {
        switch self {
        case .invalidLimit:
            return "File read limit is invalid."
        case .cannotOpen(let name, _):
            return "Could not safely open \(name)."
        case .cannotRead(let name, _):
            return "Could not safely read \(name)."
        case .notBoundedRegularFile(let name):
            return "\(name) is not an ordinary file within the allowed size."
        case .changedDuringRead(let name):
            return "\(name) changed while it was being read."
        }
    }
}
