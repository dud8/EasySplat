import Darwin
import Foundation

enum ColmapTextFileLimits {
    static let cameras = 16 * 1_024 * 1_024
    // Long captures can legitimately exceed 512 MiB. Every production consumer
    // processes these files one bounded line at a time.
    static let images = 2 * 1_024 * 1_024 * 1_024
    static let points = 2 * 1_024 * 1_024 * 1_024
    static let maximumLine = 64 * 1_024 * 1_024
}

/// Reads a stable, ordinary UTF-8 file without materializing the complete file.
final class BoundedUTF8LineReader {
    struct Line: Sendable, Equatable {
        enum Terminator: Sendable, Equatable {
            case lf
            case crlf
            case endOfFile
        }

        let number: Int
        let text: String
        let terminator: Terminator
    }

    enum Error: Swift.Error, LocalizedError, Equatable {
        case invalidLimit
        case cannotOpen(String, Int32)
        case cannotRead(String, Int32)
        case notBoundedRegularFile(String)
        case changedDuringRead(String)
        case invalidUTF8(String)
        case lineTooLong(String)

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
            case .invalidUTF8(let name):
                return "\(name) contains invalid UTF-8."
            case .lineTooLong(let name):
                return "\(name) contains a line larger than the allowed size."
            }
        }
    }

    private struct Snapshot: Equatable {
        let device: dev_t
        let inode: ino_t
        let mode: mode_t
        let linkCount: nlink_t
        let size: off_t
        let modifiedSeconds: Int
        let modifiedNanoseconds: Int
        let changedSeconds: Int
        let changedNanoseconds: Int

        init(_ metadata: stat) {
            device = metadata.st_dev
            inode = metadata.st_ino
            mode = metadata.st_mode
            linkCount = metadata.st_nlink
            size = metadata.st_size
            modifiedSeconds = metadata.st_mtimespec.tv_sec
            modifiedNanoseconds = metadata.st_mtimespec.tv_nsec
            changedSeconds = metadata.st_ctimespec.tv_sec
            changedNanoseconds = metadata.st_ctimespec.tv_nsec
        }

        var isSingleLinkedRegularFile: Bool {
            (mode & S_IFMT) == S_IFREG && linkCount == 1 && size >= 0
        }

        func identifiesSameFile(as other: Snapshot) -> Bool {
            device == other.device && inode == other.inode
        }
    }

    private let url: URL
    private let descriptor: Int32
    private let initialSnapshot: Snapshot
    private let maximumLineBytes: Int
    private var readBuffer: [UInt8]
    private var readBufferCount = 0
    private var readBufferIndex = 0
    private var lineBuffer: [UInt8] = []
    private var bytesRead: off_t = 0
    private var lineNumber = 0
    private var reachedEnd = false

    init(
        at url: URL,
        maximumBytes: Int,
        maximumLineBytes: Int = 64 * 1_024 * 1_024,
        readChunkBytes: Int = 64 * 1_024
    ) throws {
        guard maximumBytes >= 0,
              maximumLineBytes >= 0,
              (1...(1_024 * 1_024)).contains(readChunkBytes) else {
            throw Error.invalidLimit
        }
        self.url = url
        self.maximumLineBytes = min(maximumLineBytes, maximumBytes)

        let descriptor = try Self.openForReading(url)
        self.descriptor = descriptor
        do {
            let descriptorSnapshot = Snapshot(try Self.descriptorMetadata(descriptor, name: url.lastPathComponent))
            let pathSnapshot = Snapshot(try Self.pathMetadata(url, opening: true))
            guard descriptorSnapshot.isSingleLinkedRegularFile,
                  pathSnapshot.isSingleLinkedRegularFile,
                  descriptorSnapshot.identifiesSameFile(as: pathSnapshot),
                  descriptorSnapshot.size <= off_t(maximumBytes) else {
                throw Error.notBoundedRegularFile(url.lastPathComponent)
            }
            initialSnapshot = descriptorSnapshot
            readBuffer = [UInt8](repeating: 0, count: readChunkBytes)
            lineBuffer.reserveCapacity(
                min(readChunkBytes, self.maximumLineBytes, Int(descriptorSnapshot.size))
            )
        } catch {
            Darwin.close(descriptor)
            throw error
        }
    }

    deinit {
        Darwin.close(descriptor)
    }

    func next(checkCancellation: () throws -> Void = {}) throws -> Line? {
        guard !reachedEnd else { return nil }

        while true {
            try checkCancellation()
            if readBufferIndex < readBufferCount {
                let newlineIndex = readBuffer[readBufferIndex..<readBufferCount]
                    .firstIndex(of: 0x0A)
                let fragmentEnd = newlineIndex ?? readBufferCount
                try appendToLine(readBuffer[readBufferIndex..<fragmentEnd])
                readBufferIndex = fragmentEnd
                if newlineIndex != nil {
                    readBufferIndex += 1
                    return try finishLine(hasTerminator: true)
                }
                continue
            }

            let count = try refill()
            if count > 0 { continue }

            reachedEnd = true
            try validateFinalState()
            guard !lineBuffer.isEmpty else { return nil }
            return try finishLine(hasTerminator: false)
        }
    }

    private func appendToLine(_ bytes: ArraySlice<UInt8>) throws {
        guard bytes.count <= maximumLineBytes - lineBuffer.count else {
            throw Error.lineTooLong(url.lastPathComponent)
        }
        lineBuffer.append(contentsOf: bytes)
    }

    private func refill() throws -> Int {
        while true {
            let count = readBuffer.withUnsafeMutableBytes { bytes in
                Darwin.read(descriptor, bytes.baseAddress, bytes.count)
            }
            if count < 0 && errno == EINTR { continue }
            guard count >= 0 else {
                throw Error.cannotRead(url.lastPathComponent, errno)
            }
            guard bytesRead <= initialSnapshot.size - off_t(count) else {
                throw Error.changedDuringRead(url.lastPathComponent)
            }
            bytesRead += off_t(count)
            readBufferCount = count
            readBufferIndex = 0
            return count
        }
    }

    private func finishLine(hasTerminator: Bool) throws -> Line {
        let hasCarriageReturn = hasTerminator && lineBuffer.last == 0x0D
        let content = hasCarriageReturn ? lineBuffer.dropLast() : lineBuffer[...]
        guard let text = String(bytes: content, encoding: .utf8) else {
            throw Error.invalidUTF8(url.lastPathComponent)
        }
        lineBuffer.removeAll(keepingCapacity: true)
        lineNumber += 1
        let terminator: Line.Terminator = if hasCarriageReturn {
            .crlf
        } else if hasTerminator {
            .lf
        } else {
            .endOfFile
        }
        return Line(number: lineNumber, text: text, terminator: terminator)
    }

    private func validateFinalState() throws {
        let descriptorSnapshot = Snapshot(
            try Self.descriptorMetadata(descriptor, name: url.lastPathComponent)
        )
        let pathSnapshot: Snapshot
        do {
            pathSnapshot = Snapshot(try Self.pathMetadata(url, opening: false))
        } catch {
            throw Error.changedDuringRead(url.lastPathComponent)
        }
        guard descriptorSnapshot == initialSnapshot,
              pathSnapshot == initialSnapshot,
              bytesRead == initialSnapshot.size else {
            throw Error.changedDuringRead(url.lastPathComponent)
        }
    }

    private static func openForReading(_ url: URL) throws -> Int32 {
        while true {
            let descriptor = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
            if descriptor < 0 && errno == EINTR { continue }
            guard descriptor >= 0 else {
                throw Error.cannotOpen(url.lastPathComponent, errno)
            }
            return descriptor
        }
    }

    private static func descriptorMetadata(_ descriptor: Int32, name: String) throws -> stat {
        while true {
            var metadata = stat()
            let result = Darwin.fstat(descriptor, &metadata)
            if result < 0 && errno == EINTR { continue }
            guard result == 0 else { throw Error.cannotRead(name, errno) }
            return metadata
        }
    }

    private static func pathMetadata(_ url: URL, opening: Bool) throws -> stat {
        while true {
            var metadata = stat()
            let result = Darwin.lstat(url.path, &metadata)
            if result < 0 && errno == EINTR { continue }
            guard result == 0 else {
                if opening { throw Error.cannotOpen(url.lastPathComponent, errno) }
                throw Error.cannotRead(url.lastPathComponent, errno)
            }
            return metadata
        }
    }
}

/// Writes UTF-8 text through a fresh ordinary file while preserving source line endings.
final class BufferedUTF8LineWriter {
    enum Error: Swift.Error, LocalizedError, Equatable {
        case invalidCapacity
        case cannotCreate(String, Int32)
        case cannotWrite(String, Int32)
        case notOrdinaryFile(String)
        case changedDuringWrite(String)
        case alreadyFinished

        var errorDescription: String? {
            switch self {
            case .invalidCapacity:
                return "File write buffer size is invalid."
            case .cannotCreate(let name, _):
                return "Could not safely create \(name)."
            case .cannotWrite(let name, _):
                return "Could not safely write \(name)."
            case .notOrdinaryFile(let name):
                return "\(name) is not a fresh ordinary file."
            case .changedDuringWrite(let name):
                return "\(name) changed while it was being written."
            case .alreadyFinished:
                return "The text output has already been finished."
            }
        }
    }

    private struct Identity: Equatable {
        let device: dev_t
        let inode: ino_t

        init(_ metadata: stat) {
            device = metadata.st_dev
            inode = metadata.st_ino
        }
    }

    private let url: URL
    private let identity: Identity
    private let capacity: Int
    private var descriptor: Int32
    private var buffer = Data()
    private var bytesWritten: off_t = 0
    private var isFinished = false

    init(at url: URL, capacity: Int = 256 * 1_024) throws {
        guard (1...(16 * 1_024 * 1_024)).contains(capacity) else {
            throw Error.invalidCapacity
        }
        self.url = url
        self.capacity = capacity

        let descriptor = try Self.openFreshFile(at: url)
        self.descriptor = descriptor
        var createdIdentity: Identity?
        do {
            let descriptorStatus = try Self.descriptorMetadata(
                descriptor,
                name: url.lastPathComponent
            )
            createdIdentity = Identity(descriptorStatus)
            let pathStatus = try Self.pathMetadata(url)
            guard Self.isFreshRegularFile(descriptorStatus),
                  Self.isFreshRegularFile(pathStatus),
                  Identity(descriptorStatus) == Identity(pathStatus) else {
                throw Error.notOrdinaryFile(url.lastPathComponent)
            }
            identity = Identity(descriptorStatus)
            buffer.reserveCapacity(capacity)
        } catch {
            _ = Darwin.close(descriptor)
            Self.removeIfIdentityMatches(url, identity: createdIdentity)
            throw error
        }
    }

    deinit {
        if descriptor >= 0 {
            _ = Darwin.close(descriptor)
        }
    }

    func write(_ line: BoundedUTF8LineReader.Line) throws {
        try append(line.text[...])
        try write(line.terminator)
    }

    func write(fragment: Substring) throws {
        try append(fragment)
    }

    func write(fragment: String) throws {
        try append(fragment[...])
    }

    func write(
        text: String,
        tokenRanges: [Range<String.Index>],
        replacements: [Int: String],
        terminator: BoundedUTF8LineReader.Line.Terminator
    ) throws {
        var cursor = text.startIndex
        for index in tokenRanges.indices {
            guard let replacement = replacements[index] else { continue }
            let range = tokenRanges[index]
            try append(text[cursor..<range.lowerBound])
            try append(replacement[...])
            cursor = range.upperBound
        }
        try append(text[cursor...])
        try write(terminator)
    }

    func write(_ terminator: BoundedUTF8LineReader.Line.Terminator) throws {
        try requireOpen()
        switch terminator {
        case .lf:
            try append(byte: 0x0A)
        case .crlf:
            try append(byte: 0x0D)
            try append(byte: 0x0A)
        case .endOfFile:
            return
        }
    }

    func finish() throws {
        if isFinished { return }
        do {
            try flush()
            try validateFinalState()
            try synchronize()
            try validateFinalState()
            try closeDescriptor()
            isFinished = true
        } catch {
            closeAfterFailure()
            isFinished = true
            throw error
        }
    }

    private func append(_ text: Substring) throws {
        try requireOpen()
        let utf8 = text.utf8
        var cursor = utf8.startIndex
        while cursor < utf8.endIndex {
            if buffer.count == capacity { try flush() }
            let available = capacity - buffer.count
            let end = utf8.index(
                cursor,
                offsetBy: available,
                limitedBy: utf8.endIndex
            ) ?? utf8.endIndex
            buffer.append(contentsOf: utf8[cursor..<end])
            cursor = end
        }
    }

    private func append(byte: UInt8) throws {
        if buffer.count == capacity { try flush() }
        buffer.append(byte)
    }

    private func requireOpen() throws {
        guard !isFinished, descriptor >= 0 else { throw Error.alreadyFinished }
    }

    private func flush() throws {
        try requireOpen()
        guard !buffer.isEmpty else { return }
        var offset = 0
        try buffer.withUnsafeBytes { bytes in
            guard let baseAddress = bytes.baseAddress else { return }
            while offset < bytes.count {
                let count = Darwin.write(
                    descriptor,
                    baseAddress.advanced(by: offset),
                    bytes.count - offset
                )
                if count < 0, errno == EINTR { continue }
                guard count > 0 else {
                    throw Error.cannotWrite(url.lastPathComponent, count < 0 ? errno : EIO)
                }
                offset += count
                bytesWritten += off_t(count)
            }
        }
        buffer.removeAll(keepingCapacity: true)
    }

    private func validateFinalState() throws {
        let descriptorStatus = try Self.descriptorMetadata(
            descriptor,
            name: url.lastPathComponent
        )
        let pathStatus: stat
        do {
            pathStatus = try Self.pathMetadata(url)
        } catch {
            throw Error.changedDuringWrite(url.lastPathComponent)
        }
        guard (descriptorStatus.st_mode & S_IFMT) == S_IFREG,
              descriptorStatus.st_nlink == 1,
              descriptorStatus.st_size == bytesWritten,
              Identity(descriptorStatus) == identity,
              Identity(pathStatus) == identity,
              (pathStatus.st_mode & S_IFMT) == S_IFREG,
              pathStatus.st_nlink == 1,
              pathStatus.st_size == bytesWritten else {
            throw Error.changedDuringWrite(url.lastPathComponent)
        }
    }

    private func synchronize() throws {
        while true {
            if Darwin.fsync(descriptor) == 0 { return }
            let code = errno
            if code == EINTR { continue }
            throw Error.cannotWrite(url.lastPathComponent, code)
        }
    }

    private func closeDescriptor() throws {
        let descriptorToClose = descriptor
        descriptor = -1
        guard Darwin.close(descriptorToClose) == 0 else {
            throw Error.cannotWrite(url.lastPathComponent, errno)
        }
    }

    private func closeAfterFailure() {
        guard descriptor >= 0 else { return }
        let descriptorToClose = descriptor
        descriptor = -1
        _ = Darwin.close(descriptorToClose)
    }

    private static func openFreshFile(at url: URL) throws -> Int32 {
        let flags = O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC
        while true {
            let descriptor = Darwin.open(
                url.path,
                flags,
                mode_t(S_IRUSR | S_IWUSR)
            )
            if descriptor < 0, errno == EINTR { continue }
            guard descriptor >= 0 else {
                throw Error.cannotCreate(url.lastPathComponent, errno)
            }
            return descriptor
        }
    }

    private static func descriptorMetadata(_ descriptor: Int32, name: String) throws -> stat {
        while true {
            var metadata = stat()
            if Darwin.fstat(descriptor, &metadata) == 0 { return metadata }
            let code = errno
            if code == EINTR { continue }
            throw Error.cannotWrite(name, code)
        }
    }

    private static func pathMetadata(_ url: URL) throws -> stat {
        while true {
            var metadata = stat()
            if Darwin.lstat(url.path, &metadata) == 0 { return metadata }
            let code = errno
            if code == EINTR { continue }
            throw Error.cannotWrite(url.lastPathComponent, code)
        }
    }

    private static func isFreshRegularFile(_ metadata: stat) -> Bool {
        (metadata.st_mode & S_IFMT) == S_IFREG
            && metadata.st_nlink == 1
            && metadata.st_size == 0
    }

    private static func removeIfIdentityMatches(_ url: URL, identity: Identity?) {
        guard let identity,
              let status = try? pathMetadata(url),
              Identity(status) == identity else {
            return
        }
        _ = Darwin.unlink(url.path)
    }
}
