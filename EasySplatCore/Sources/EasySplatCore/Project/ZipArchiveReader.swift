import Compression
import CryptoKit
import Darwin
import Foundation

/// Reads zip archives in process without ever reopening a validated pathname.
enum ZipArchiveReader {
    struct FileIdentity: Sendable, Equatable {
        let device: dev_t
        let inode: ino_t
        let kind: mode_t

        init(_ status: stat) {
            device = status.st_dev
            inode = status.st_ino
            kind = status.st_mode & S_IFMT
        }

        func matches(_ status: stat) -> Bool {
            status.st_dev == device
                && status.st_ino == inode
                && (status.st_mode & S_IFMT) == kind
        }
    }

    struct ExtractedFile: Sendable, Equatable {
        let byteCount: UInt64
        let identity: FileIdentity
        let permissions: mode_t
        let linkCount: UInt64
        let modificationSeconds: Int64
        let modificationNanoseconds: Int64
        let changeSeconds: Int64
        let changeNanoseconds: Int64
        let birthSeconds: Int64
        let birthNanoseconds: Int64
        let sha256: Data

        init(byteCount: UInt64, identity: FileIdentity, status: stat, sha256: Data) {
            self.byteCount = byteCount
            self.identity = identity
            permissions = status.st_mode & 0o7777
            linkCount = UInt64(status.st_nlink)
            modificationSeconds = Int64(status.st_mtimespec.tv_sec)
            modificationNanoseconds = Int64(status.st_mtimespec.tv_nsec)
            changeSeconds = Int64(status.st_ctimespec.tv_sec)
            changeNanoseconds = Int64(status.st_ctimespec.tv_nsec)
            birthSeconds = Int64(status.st_birthtimespec.tv_sec)
            birthNanoseconds = Int64(status.st_birthtimespec.tv_nsec)
            self.sha256 = sha256
        }

        func matchesStableStatus(_ status: stat) -> Bool {
            status.st_size >= 0
                && status.st_nlink >= 0
                && (status.st_mode & S_IFMT) == S_IFREG
                && identity.matches(status)
                && UInt64(status.st_size) == byteCount
                && (status.st_mode & 0o7777) == permissions
                && UInt64(status.st_nlink) == linkCount
                && Int64(status.st_mtimespec.tv_sec) == modificationSeconds
                && Int64(status.st_mtimespec.tv_nsec) == modificationNanoseconds
                && Int64(status.st_ctimespec.tv_sec) == changeSeconds
                && Int64(status.st_ctimespec.tv_nsec) == changeNanoseconds
                && Int64(status.st_birthtimespec.tv_sec) == birthSeconds
                && Int64(status.st_birthtimespec.tv_nsec) == birthNanoseconds
        }
    }

    struct Entry: Sendable, Equatable {
        let path: String
        let compressedSize: UInt64
        let uncompressedSize: UInt64
        let crc32: UInt32
        let compressionMethod: UInt16
        let generalPurposeFlags: UInt16
        let localHeaderOffset: UInt64
        let payloadOffset: UInt64
        let usesZip64DataDescriptor: Bool
        let isDirectory: Bool
        let externalAttributes: UInt32
        fileprivate let snapshotIdentifier: UUID
        fileprivate let ordinal: Int

        /// Zip stores the Unix mode in the high 16 bits when it was written on a
        /// Unix host. Anything other than a plain file or directory is rejected
        /// before the destination is created.
        var unixMode: mode_t {
            mode_t((externalAttributes >> 16) & 0xFFFF)
        }

        var isSymbolicLink: Bool {
            (unixMode & S_IFMT) == S_IFLNK
        }
    }

    enum ReaderError: Error, Equatable {
        case unreadable
        case archiveChanged
        case malformed(String)
        case unsupported(String)
        case encrypted(String)
        case checksumMismatch(String)
        case entryCountExceeded(Int)
        case listingTooLarge
    }

    /// One descriptor-bound view of an archive. The source is opened once with
    /// `O_NOFOLLOW`; central-directory parsing and every payload read use
    /// positional reads from that same descriptor. Complete descriptor evidence
    /// is checked after parsing and at extraction boundaries, so pathname swaps
    /// cannot redirect reads and in-place mutation fails closed.
    final class Snapshot: @unchecked Sendable {
        let entries: [Entry]

        private let descriptor: Int32
        private let evidence: FileEvidence
        private let identifier: UUID

        init(
            opening url: URL,
            maximumEntryCount: Int = ZipArchiveReader.maximumEntryCount,
            maximumNameBytes: Int = ZipArchiveReader.maximumNameBytes,
            maximumArchiveBytes: UInt64 = ZipArchiveReader.maximumArchiveBytes,
            maximumPathComponents: Int = .max,
            shouldCancel: @escaping @Sendable () -> Bool = { false }
        ) throws {
            try ZipArchiveReader.throwIfCancelled(shouldCancel)
            let descriptor = Darwin.open(
                url.path,
                O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC
            )
            guard descriptor >= 0 else { throw ReaderError.unreadable }

            do {
                var status = stat()
                guard Darwin.fstat(descriptor, &status) == 0,
                      (status.st_mode & S_IFMT) == S_IFREG,
                      status.st_size >= 0,
                      UInt64(status.st_size) <= maximumArchiveBytes else {
                    throw ReaderError.unreadable
                }
                let evidence = FileEvidence(status)
                let identifier = UUID()
                let entries = try ZipArchiveReader.parseEntries(
                    descriptor: descriptor,
                    fileSize: evidence.size,
                    maximumEntryCount: maximumEntryCount,
                    maximumNameBytes: maximumNameBytes,
                    maximumPathComponents: maximumPathComponents,
                    snapshotIdentifier: identifier,
                    shouldCancel: shouldCancel
                )
                guard evidence.matchesCurrentStatus(of: descriptor) else {
                    throw ReaderError.archiveChanged
                }
                self.descriptor = descriptor
                self.evidence = evidence
                self.identifier = identifier
                self.entries = entries
            } catch {
                Darwin.close(descriptor)
                throw error
            }
        }

        deinit {
            Darwin.close(descriptor)
        }

        func requireUnchanged() throws {
            guard evidence.matchesCurrentStatus(
                of: descriptor,
                allowingOneRemovedLink: true
            ) else {
                throw ReaderError.archiveChanged
            }
        }

        /// Stream one validated entry into a leaf opened relative to an already
        /// validated parent directory descriptor.
        @discardableResult
        func extract(
            entry: Entry,
            into directoryDescriptor: Int32,
            leafName: String,
            maximumOutputBytes: UInt64,
            shouldCancel: @escaping @Sendable () -> Bool,
            privateOutputCreated: ((Int32, String) -> Void)? = nil
        ) throws -> ExtractedFile {
            guard entry.snapshotIdentifier == identifier,
                  entries.indices.contains(entry.ordinal),
                  entries[entry.ordinal] == entry,
                  !leafName.isEmpty,
                  leafName != ".",
                  leafName != "..",
                  !leafName.contains("/"),
                  !leafName.contains("\\"),
                  !entry.isDirectory else {
                throw ReaderError.malformed("invalid extraction target: \(leafName)")
            }
            let entry = entries[entry.ordinal]
            guard entry.uncompressedSize <= maximumOutputBytes,
                  entry.uncompressedSize <= ZipArchiveReader.maximumEntryBytes else {
                throw ReaderError.malformed("entry declares an unusable size: \(entry.path)")
            }
            try requireUnchanged()
            try ZipArchiveReader.throwIfCancelled(shouldCancel)

            var privateLeaf: String?
            var output: Int32 = -1
            for _ in 0..<8 {
                let candidate = ".easysplat-entry-\(UUID().uuidString)"
                output = candidate.withCString {
                    Darwin.openat(
                        directoryDescriptor,
                        $0,
                        O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
                        mode_t(S_IRUSR | S_IWUSR)
                    )
                }
                if output >= 0 {
                    privateLeaf = candidate
                    break
                }
                guard errno == EEXIST else { break }
            }
            guard output >= 0, let privateLeaf else {
                throw ReaderError.malformed("cannot create \(entry.path)")
            }
            defer { Darwin.close(output) }

            var initialOutputStatus = stat()
            guard Darwin.fstat(output, &initialOutputStatus) == 0,
                  (initialOutputStatus.st_mode & S_IFMT) == S_IFREG else {
                throw ReaderError.malformed("cannot bind \(entry.path)")
            }
            let outputIdentity = FileIdentity(initialOutputStatus)
            guard Darwin.fchmod(output, mode_t(S_IRUSR | S_IWUSR)) == 0 else {
                throw ReaderError.malformed("cannot secure \(entry.path)")
            }
            privateOutputCreated?(directoryDescriptor, privateLeaf)
            try ZipArchiveReader.throwIfCancelled(shouldCancel)
            let produced: UInt64
            var hasher = SHA256()
            switch entry.compressionMethod {
            case 0:
                produced = try extractStored(
                    entry: entry,
                    into: output,
                    maximumOutputBytes: maximumOutputBytes,
                    hasher: &hasher,
                    shouldCancel: shouldCancel
                )
            case 8:
                produced = try extractDeflated(
                    entry: entry,
                    into: output,
                    maximumOutputBytes: maximumOutputBytes,
                    hasher: &hasher,
                    shouldCancel: shouldCancel
                )
            default:
                throw ReaderError.unsupported(
                    "entry uses an unsupported compression method: \(entry.path)"
                )
            }
            guard produced == entry.uncompressedSize else {
                throw ReaderError.malformed(
                    "entry size does not match its declaration: \(entry.path)"
                )
            }
            var outputStatus = stat()
            var privateNamedStatus = stat()
            guard Darwin.fstat(output, &outputStatus) == 0,
                  (outputStatus.st_mode & S_IFMT) == S_IFREG,
                  outputStatus.st_size >= 0,
                  UInt64(outputStatus.st_size) == produced,
                  outputStatus.st_nlink == 1,
                  (outputStatus.st_mode & 0o7777) == mode_t(S_IRUSR | S_IWUSR),
                  outputIdentity.matches(outputStatus),
                  privateLeaf.withCString({
                      Darwin.fstatat(
                          directoryDescriptor,
                          $0,
                          &privateNamedStatus,
                          AT_SYMLINK_NOFOLLOW
                      )
                  }) == 0,
                  outputIdentity.matches(privateNamedStatus) else {
                throw ReaderError.malformed("written entry is invalid: \(entry.path)")
            }
            try requireUnchanged()
            try ZipArchiveReader.throwIfCancelled(shouldCancel)
            let published = privateLeaf.withCString { source in
                leafName.withCString { destination in
                    Darwin.renameatx_np(
                        directoryDescriptor,
                        source,
                        directoryDescriptor,
                        destination,
                        UInt32(RENAME_EXCL | RENAME_NOFOLLOW_ANY)
                    )
                }
            }
            guard published == 0 else {
                throw ReaderError.malformed("cannot publish \(entry.path)")
            }

            var finalOutputStatus = stat()
            var namedOutputStatus = stat()
            guard Darwin.fstat(output, &finalOutputStatus) == 0,
                  outputIdentity.matches(finalOutputStatus),
                  finalOutputStatus.st_size >= 0,
                  UInt64(finalOutputStatus.st_size) == produced,
                  finalOutputStatus.st_nlink == 1,
                  (finalOutputStatus.st_mode & 0o7777) == mode_t(S_IRUSR | S_IWUSR),
                  leafName.withCString({
                      Darwin.fstatat(
                          directoryDescriptor,
                          $0,
                          &namedOutputStatus,
                          AT_SYMLINK_NOFOLLOW
                      )
                  }) == 0,
                  outputIdentity.matches(namedOutputStatus) else {
                throw ReaderError.malformed("published entry is invalid: \(entry.path)")
            }
            let extracted = ExtractedFile(
                byteCount: produced,
                identity: outputIdentity,
                status: finalOutputStatus,
                sha256: Data(hasher.finalize())
            )
            guard extracted.matchesStableStatus(namedOutputStatus) else {
                throw ReaderError.malformed("written entry changed: \(entry.path)")
            }
            return extracted
        }

        private func extractStored(
            entry: Entry,
            into output: Int32,
            maximumOutputBytes: UInt64,
            hasher: inout SHA256,
            shouldCancel: @escaping @Sendable () -> Bool
        ) throws -> UInt64 {
            guard entry.compressedSize == entry.uncompressedSize else {
                throw ReaderError.malformed("stored entry sizes disagree: \(entry.path)")
            }
            var buffer = [UInt8](repeating: 0, count: ZipArchiveReader.bufferSize)
            var sourceOffset = entry.payloadOffset
            var remaining = entry.compressedSize
            var produced: UInt64 = 0
            var crc: UInt32 = 0xFFFF_FFFF

            while remaining > 0 {
                try ZipArchiveReader.throwIfCancelled(shouldCancel)
                let requested = min(buffer.count, Int(remaining))
                let count = try buffer.withUnsafeMutableBytes { bytes in
                    try ZipArchiveReader.readSome(
                        descriptor: descriptor,
                        into: bytes.baseAddress,
                        count: requested,
                        offset: sourceOffset
                    )
                }
                guard count > 0 else {
                    throw ReaderError.malformed("entry payload is short: \(entry.path)")
                }
                try buffer.withUnsafeBytes { bytes in
                    guard let base = bytes.baseAddress else { return }
                    try ZipArchiveReader.consumeOutput(
                        base,
                        count: count,
                        output: output,
                        produced: &produced,
                        expected: entry.uncompressedSize,
                        maximum: maximumOutputBytes,
                        crc: &crc,
                        hasher: &hasher,
                        name: entry.path
                    )
                }
                sourceOffset += UInt64(count)
                remaining -= UInt64(count)
            }

            guard (crc ^ 0xFFFF_FFFF) == entry.crc32 else {
                throw ReaderError.checksumMismatch(entry.path)
            }
            return produced
        }

        private func extractDeflated(
            entry: Entry,
            into output: Int32,
            maximumOutputBytes: UInt64,
            hasher: inout SHA256,
            shouldCancel: @escaping @Sendable () -> Bool
        ) throws -> UInt64 {
            var input = [UInt8](repeating: 0, count: ZipArchiveReader.bufferSize)
            var decoded = [UInt8](repeating: 0, count: ZipArchiveReader.bufferSize)

            return try input.withUnsafeMutableBufferPointer { inputBuffer in
                try decoded.withUnsafeMutableBufferPointer { outputBuffer in
                    guard let inputBase = inputBuffer.baseAddress,
                          let outputBase = outputBuffer.baseAddress else {
                        throw ReaderError.malformed("cannot allocate inflate buffers: \(entry.path)")
                    }
                    var stream = compression_stream(
                        dst_ptr: outputBase,
                        dst_size: outputBuffer.count,
                        src_ptr: UnsafePointer(inputBase),
                        src_size: 0,
                        state: nil
                    )
                    guard compression_stream_init(
                        &stream,
                        COMPRESSION_STREAM_DECODE,
                        COMPRESSION_ZLIB
                    ) == COMPRESSION_STATUS_OK else {
                        throw ReaderError.malformed("cannot initialise inflater: \(entry.path)")
                    }
                    defer { compression_stream_destroy(&stream) }

                    var sourceOffset = entry.payloadOffset
                    var compressedRemaining = entry.compressedSize
                    var inputCount = 0
                    var inputOffset = 0
                    var produced: UInt64 = 0
                    var crc: UInt32 = 0xFFFF_FFFF

                    while true {
                        try ZipArchiveReader.throwIfCancelled(shouldCancel)
                        if inputOffset == inputCount, compressedRemaining > 0 {
                            let requested = min(inputBuffer.count, Int(compressedRemaining))
                            inputCount = try ZipArchiveReader.readSome(
                                descriptor: descriptor,
                                into: inputBase,
                                count: requested,
                                offset: sourceOffset
                            )
                            guard inputCount > 0 else {
                                throw ReaderError.malformed("entry payload is short: \(entry.path)")
                            }
                            inputOffset = 0
                            sourceOffset += UInt64(inputCount)
                            compressedRemaining -= UInt64(inputCount)
                        }

                        stream.src_ptr = UnsafePointer(inputBase.advanced(by: inputOffset))
                        stream.src_size = inputCount - inputOffset
                        stream.dst_ptr = outputBase
                        stream.dst_size = outputBuffer.count
                        let availableInput = stream.src_size
                        let flags = compressedRemaining == 0
                            ? Int32(COMPRESSION_STREAM_FINALIZE.rawValue)
                            : 0
                        let status = compression_stream_process(&stream, flags)
                        let consumed = availableInput - stream.src_size
                        inputOffset += consumed
                        let outputCount = outputBuffer.count - stream.dst_size

                        if outputCount > 0 {
                            try ZipArchiveReader.consumeOutput(
                                outputBase,
                                count: outputCount,
                                output: output,
                                produced: &produced,
                                expected: entry.uncompressedSize,
                                maximum: maximumOutputBytes,
                                crc: &crc,
                                hasher: &hasher,
                                name: entry.path
                            )
                        }

                        switch status {
                        case COMPRESSION_STATUS_END:
                            guard compressedRemaining == 0, inputOffset == inputCount else {
                                throw ReaderError.malformed(
                                    "entry contains trailing compressed bytes: \(entry.path)"
                                )
                            }
                            guard (crc ^ 0xFFFF_FFFF) == entry.crc32 else {
                                throw ReaderError.checksumMismatch(entry.path)
                            }
                            return produced
                        case COMPRESSION_STATUS_OK:
                            if consumed == 0,
                               outputCount == 0,
                               compressedRemaining == 0,
                               inputOffset == inputCount {
                                throw ReaderError.malformed(
                                    "entry did not inflate to completion: \(entry.path)"
                                )
                            }
                        default:
                            throw ReaderError.malformed("entry could not be inflated: \(entry.path)")
                        }
                    }
                }
            }
        }
    }

    /// Reads only the central directory and local headers needed for
    /// selection-time format sniffing. Unlike `Snapshot`, this deliberately
    /// does not copy or read payload bytes and must never be used as extraction
    /// authority. The descriptor's complete identity is checked before and
    /// after parsing so an in-place mutation fails closed.
    static func boundedEntryNames(
        inArchiveAt url: URL,
        maximumEntryCount: Int = sniffingMaximumEntryCount,
        maximumListingBytes: Int = sniffingMaximumListingBytes,
        maximumPathComponents: Int = archiveMaximumPathComponents,
        shouldCancel: @escaping @Sendable () -> Bool = { false },
        beforeFinalIdentityCheck: ((Int32) -> Void)? = nil
    ) throws -> [String] {
        guard maximumEntryCount >= 0, maximumListingBytes >= 0 else {
            throw ReaderError.listingTooLarge
        }
        try throwIfCancelled(shouldCancel)
        let descriptor = Darwin.open(
            url.path,
            O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC
        )
        guard descriptor >= 0 else { throw ReaderError.unreadable }
        defer { Darwin.close(descriptor) }

        var status = stat()
        guard Darwin.fstat(descriptor, &status) == 0,
              (status.st_mode & S_IFMT) == S_IFREG,
              status.st_size >= 0 else {
            throw ReaderError.unreadable
        }
        let evidence = FileEvidence(status)
        let identifier = UUID()
        let entries = try parseEntries(
            descriptor: descriptor,
            fileSize: evidence.size,
            maximumEntryCount: maximumEntryCount,
            maximumNameBytes: maximumListingBytes,
            maximumPathComponents: maximumPathComponents,
            snapshotIdentifier: identifier,
            shouldCancel: shouldCancel
        )
        beforeFinalIdentityCheck?(descriptor)
        try throwIfCancelled(shouldCancel)
        guard evidence.matchesCurrentStatus(of: descriptor) else {
            throw ReaderError.archiveChanged
        }
        return entries.map(\.path)
    }

    private struct FileEvidence: Sendable {
        let device: UInt64
        let inode: UInt64
        let size: UInt64
        let linkCount: UInt64
        let modificationSeconds: Int64
        let modificationNanoseconds: Int64
        let changeSeconds: Int64
        let changeNanoseconds: Int64
        let birthSeconds: Int64
        let birthNanoseconds: Int64

        init(_ status: stat) {
            device = UInt64(status.st_dev)
            inode = UInt64(status.st_ino)
            size = UInt64(status.st_size)
            linkCount = UInt64(status.st_nlink)
            modificationSeconds = Int64(status.st_mtimespec.tv_sec)
            modificationNanoseconds = Int64(status.st_mtimespec.tv_nsec)
            changeSeconds = Int64(status.st_ctimespec.tv_sec)
            changeNanoseconds = Int64(status.st_ctimespec.tv_nsec)
            birthSeconds = Int64(status.st_birthtimespec.tv_sec)
            birthNanoseconds = Int64(status.st_birthtimespec.tv_nsec)
        }

        func matchesCurrentStatus(
            of descriptor: Int32,
            allowingOneRemovedLink: Bool = false
        ) -> Bool {
            var current = stat()
            guard Darwin.fstat(descriptor, &current) == 0,
                  current.st_nlink >= 0 else { return false }
            let currentLinkCount = UInt64(current.st_nlink)
            let oneLinkWasRemoved = allowingOneRemovedLink
                && linkCount > 0
                && currentLinkCount + 1 == linkCount
            return (current.st_mode & S_IFMT) == S_IFREG
                && UInt64(current.st_dev) == device
                && UInt64(current.st_ino) == inode
                && current.st_size >= 0
                && UInt64(current.st_size) == size
                && (currentLinkCount == linkCount || oneLinkWasRemoved)
                && Int64(current.st_mtimespec.tv_sec) == modificationSeconds
                && Int64(current.st_mtimespec.tv_nsec) == modificationNanoseconds
                && (oneLinkWasRemoved
                    || (Int64(current.st_ctimespec.tv_sec) == changeSeconds
                        && Int64(current.st_ctimespec.tv_nsec) == changeNanoseconds))
                && Int64(current.st_birthtimespec.tv_sec) == birthSeconds
                && Int64(current.st_birthtimespec.tv_nsec) == birthNanoseconds
        }
    }

    private struct DirectoryRecord {
        let entryCount: Int
        let offset: UInt64
        let size: UInt64
        let structureOffset: UInt64
    }

    private static let endOfCentralDirectorySignature: UInt32 = 0x0605_4B50
    private static let zip64LocatorSignature: UInt32 = 0x0706_4B50
    private static let zip64EndSignature: UInt32 = 0x0606_4B50
    private static let centralFileHeaderSignature: UInt32 = 0x0201_4B50
    private static let localFileHeaderSignature: UInt32 = 0x0403_4B50
    private static let dataDescriptorSignature: UInt32 = 0x0807_4B50
    private static let maximumEntryCount = 512_000
    private static let maximumNameBytes = 128 * 1024 * 1024
    static let sniffingMaximumEntryCount = 50_000
    static let sniffingMaximumListingBytes = 128 * 1024 * 1024
    static let archiveMaximumPathComponents = 64
    private static let maximumEntryBytes: UInt64 = 8 << 30
    private static let maximumArchiveBytes: UInt64 = 16 << 30
    private static let bufferSize = 64 * 1024
    private static let encryptionFlagMask: UInt16 = 0x2041
    private static let dataDescriptorFlag: UInt16 = 0x0008
    private static let deflateOptionFlagMask: UInt16 = 0x0006
    private static let utf8Flag: UInt16 = 0x0800
    private static let compressedPatchedDataFlag: UInt16 = 0x0020

    // MARK: - Snapshot parsing

    private static func parseEntries(
        descriptor: Int32,
        fileSize: UInt64,
        maximumEntryCount: Int,
        maximumNameBytes: Int,
        maximumPathComponents: Int,
        snapshotIdentifier: UUID,
        shouldCancel: @escaping @Sendable () -> Bool
    ) throws -> [Entry] {
        guard maximumEntryCount >= 0,
              maximumNameBytes >= 0,
              maximumPathComponents >= 0 else {
            throw ReaderError.malformed("archive limits are invalid")
        }
        let directory = try centralDirectoryRecord(
            descriptor: descriptor,
            fileSize: fileSize,
            maximumEntryCount: maximumEntryCount
        )
        guard directory.size <= UInt64(maximumNameBytes) else {
            throw ReaderError.listingTooLarge
        }
        guard let directoryEnd = checkedEnd(
            offset: directory.offset,
            length: directory.size,
            limit: fileSize
        ), directoryEnd <= directory.structureOffset else {
            throw ReaderError.malformed("central directory lies outside the archive")
        }

        var entries: [Entry] = []
        entries.reserveCapacity(directory.entryCount)
        var cursor = directory.offset
        var nameBytes = 0

        for ordinal in 0..<directory.entryCount {
            try throwIfCancelled(shouldCancel)
            guard let fixedEnd = checkedEnd(offset: cursor, length: 46, limit: directoryEnd) else {
                throw ReaderError.malformed("central directory header is malformed")
            }
            let header = try readData(descriptor: descriptor, offset: cursor, count: 46)
            guard read32(header, 0) == centralFileHeaderSignature else {
                throw ReaderError.malformed("central directory header is malformed")
            }
            let flags = read16(header, 8)
            let method = read16(header, 10)
            let crc = read32(header, 16)
            var compressed = UInt64(read32(header, 20))
            var uncompressed = UInt64(read32(header, 24))
            let nameLength = Int(read16(header, 28))
            let extraLength = Int(read16(header, 30))
            let commentLength = UInt64(read16(header, 32))
            var diskNumber = UInt64(read16(header, 34))
            let attributes = read32(header, 38)
            var localOffset = UInt64(read32(header, 42))

            guard method == 0 || method == 8 else {
                throw ReaderError.unsupported("archive uses an unsupported compression method")
            }
            let variableLength = UInt64(nameLength + extraLength)
            guard let variableEnd = checkedEnd(
                offset: fixedEnd,
                length: variableLength,
                limit: directoryEnd
            ), let entryEnd = checkedEnd(
                offset: variableEnd,
                length: commentLength,
                limit: directoryEnd
            ) else {
                throw ReaderError.malformed("central directory entry overruns the archive")
            }
            let variable = try readData(
                descriptor: descriptor,
                offset: fixedEnd,
                count: nameLength + extraLength
            )
            let nameData = variable.prefix(nameLength)
            let extra = Data(variable.dropFirst(nameLength))
            guard rawPathComponentCount(nameData) <= maximumPathComponents else {
                throw ReaderError.malformed("entry path has too many components")
            }
            guard let name = String(data: nameData, encoding: .utf8) else {
                throw ReaderError.malformed("entry name is not UTF-8")
            }
            let nextNameBytes = nameBytes.addingReportingOverflow(nameData.count + 1)
            guard !nextNameBytes.overflow, nextNameBytes.partialValue <= maximumNameBytes else {
                throw ReaderError.listingTooLarge
            }
            nameBytes = nextNameBytes.partialValue

            try validateGeneralPurposeFlags(flags, method: method, name: name)
            let hasZip64Extra = try containsExtraField(
                identifier: 0x0001,
                in: extra,
                name: name
            )
            if compressed == UInt64(UInt32.max)
                || uncompressed == UInt64(UInt32.max)
                || localOffset == UInt64(UInt32.max)
                || diskNumber == UInt64(UInt16.max) {
                try resolveZip64Extra(
                    extra,
                    uncompressed: &uncompressed,
                    compressed: &compressed,
                    localHeaderOffset: &localOffset,
                    diskNumber: &diskNumber,
                    name: name
                )
            }
            guard diskNumber == 0 else {
                throw ReaderError.unsupported("multi-disk zip archives are unsupported")
            }
            guard uncompressed <= maximumEntryBytes else {
                throw ReaderError.malformed("entry declares an unusable size: \(name)")
            }

            entries.append(Entry(
                path: name,
                compressedSize: compressed,
                uncompressedSize: uncompressed,
                crc32: crc,
                compressionMethod: method,
                generalPurposeFlags: flags,
                localHeaderOffset: localOffset,
                payloadOffset: 0,
                usesZip64DataDescriptor: hasZip64Extra,
                isDirectory: name.hasSuffix("/"),
                externalAttributes: attributes,
                snapshotIdentifier: snapshotIdentifier,
                ordinal: ordinal
            ))
            cursor = entryEnd
        }

        guard cursor == directoryEnd else {
            throw ReaderError.malformed("central directory size does not match its entries")
        }
        var validated = Array<Entry?>(repeating: nil, count: entries.count)
        var remainingLocalHeaderBytes = maximumNameBytes
        let entriesByLocalOffset = entries.sorted {
            $0.localHeaderOffset < $1.localHeaderOffset
        }
        for (index, entry) in entriesByLocalOffset.enumerated() {
            try throwIfCancelled(shouldCancel)
            let payloadLimit = index + 1 < entriesByLocalOffset.count
                ? entriesByLocalOffset[index + 1].localHeaderOffset
                : directory.offset
            guard entry.localHeaderOffset < payloadLimit else {
                throw ReaderError.malformed("local file headers overlap")
            }
            validated[entry.ordinal] = try validateLocalHeader(
                descriptor: descriptor,
                entry: entry,
                payloadLimit: payloadLimit,
                remainingListingBytes: &remainingLocalHeaderBytes
            )
        }
        guard validated.allSatisfy({ $0 != nil }) else {
            throw ReaderError.malformed("central directory entry is missing a local header")
        }
        return validated.compactMap { $0 }
    }

    /// Counts path components directly in the central-directory bytes so a
    /// deeply nested hostile name is rejected before allocating or retaining a
    /// Swift `String`. A terminal slash denotes a directory and does not add an
    /// empty component.
    private static func rawPathComponentCount<T: DataProtocol>(_ bytes: T) -> Int {
        guard !bytes.isEmpty else { return 0 }
        var count = 1
        var remaining = bytes.count
        for region in bytes.regions {
            for byte in region {
                remaining -= 1
                if byte == UInt8(ascii: "/"), remaining > 0 {
                    count += 1
                }
            }
        }
        return count
    }

    private static func centralDirectoryRecord(
        descriptor: Int32,
        fileSize: UInt64,
        maximumEntryCount: Int
    ) throws -> DirectoryRecord {
        let minimumEOCD = 22
        guard fileSize >= UInt64(minimumEOCD) else {
            throw ReaderError.malformed("archive is too small")
        }
        let tailCount = Int(min(fileSize, UInt64(minimumEOCD + 65_535)))
        let tailOffset = fileSize - UInt64(tailCount)
        let tail = try readData(descriptor: descriptor, offset: tailOffset, count: tailCount)
        guard let relativeEOCD = locateEndOfCentralDirectory(in: tail) else {
            throw ReaderError.malformed("end of central directory record is missing")
        }
        let eocdOffset = tailOffset + UInt64(relativeEOCD)
        let disk = read16(tail, relativeEOCD + 4)
        let centralDisk = read16(tail, relativeEOCD + 6)
        let entriesOnDisk = read16(tail, relativeEOCD + 8)
        let totalEntries = read16(tail, relativeEOCD + 10)
        let directorySize32 = read32(tail, relativeEOCD + 12)
        let directoryOffset32 = read32(tail, relativeEOCD + 16)
        guard disk == 0, centralDisk == 0, entriesOnDisk == totalEntries else {
            throw ReaderError.unsupported("multi-disk zip archives are unsupported")
        }

        let usesZip64 = totalEntries == UInt16.max
            || directorySize32 == UInt32.max
            || directoryOffset32 == UInt32.max
        if !usesZip64 {
            let count = Int(totalEntries)
            guard count <= maximumEntryCount else {
                throw ReaderError.entryCountExceeded(maximumEntryCount)
            }
            return DirectoryRecord(
                entryCount: count,
                offset: UInt64(directoryOffset32),
                size: UInt64(directorySize32),
                structureOffset: eocdOffset
            )
        }

        guard eocdOffset >= 20 else {
            throw ReaderError.malformed("zip64 locator is missing")
        }
        let locatorOffset = eocdOffset - 20
        let locator = try readData(descriptor: descriptor, offset: locatorOffset, count: 20)
        guard read32(locator, 0) == zip64LocatorSignature,
              read32(locator, 4) == 0,
              read32(locator, 16) == 1 else {
            throw ReaderError.malformed("zip64 locator is missing")
        }
        let zip64Offset = read64(locator, 8)
        guard let minimumZip64End = checkedEnd(
            offset: zip64Offset,
            length: 56,
            limit: locatorOffset
        ) else {
            throw ReaderError.malformed("zip64 end record is missing")
        }
        let zip64 = try readData(descriptor: descriptor, offset: zip64Offset, count: 56)
        let recordSize = read64(zip64, 4)
        let recordLength = UInt64(12).addingReportingOverflow(recordSize)
        guard read32(zip64, 0) == zip64EndSignature,
              recordSize >= 44,
              !recordLength.overflow,
              let recordEnd = checkedEnd(
                offset: zip64Offset,
                length: recordLength.partialValue,
                limit: locatorOffset
              ), recordEnd >= minimumZip64End,
              read32(zip64, 16) == 0,
              read32(zip64, 20) == 0,
              read64(zip64, 24) == read64(zip64, 32) else {
            throw ReaderError.malformed("zip64 end record is malformed")
        }
        let declaredCount = read64(zip64, 32)
        guard declaredCount <= UInt64(maximumEntryCount),
              declaredCount <= UInt64(Int.max) else {
            throw ReaderError.entryCountExceeded(maximumEntryCount)
        }
        return DirectoryRecord(
            entryCount: Int(declaredCount),
            offset: read64(zip64, 48),
            size: read64(zip64, 40),
            structureOffset: zip64Offset
        )
    }

    private static func validateLocalHeader(
        descriptor: Int32,
        entry: Entry,
        payloadLimit: UInt64,
        remainingListingBytes: inout Int
    ) throws -> Entry {
        guard let fixedEnd = checkedEnd(
            offset: entry.localHeaderOffset,
            length: 30,
            limit: payloadLimit
        ) else {
            throw ReaderError.malformed("local header is malformed: \(entry.path)")
        }
        let header = try readData(
            descriptor: descriptor,
            offset: entry.localHeaderOffset,
            count: 30
        )
        guard read32(header, 0) == localFileHeaderSignature else {
            throw ReaderError.malformed("local header is malformed: \(entry.path)")
        }
        let flags = read16(header, 6)
        let method = read16(header, 8)
        let localCRC = read32(header, 14)
        var localCompressed = UInt64(read32(header, 18))
        var localUncompressed = UInt64(read32(header, 22))
        let nameLength = Int(read16(header, 26))
        let extraLength = Int(read16(header, 28))
        let localHeaderBytes = 30 + nameLength + extraLength
        guard localHeaderBytes <= remainingListingBytes else {
            throw ReaderError.listingTooLarge
        }
        remainingListingBytes -= localHeaderBytes
        guard flags == entry.generalPurposeFlags,
              method == entry.compressionMethod else {
            throw ReaderError.malformed("local header disagrees with central directory: \(entry.path)")
        }
        try validateGeneralPurposeFlags(flags, method: method, name: entry.path)
        guard let payloadOffset = checkedEnd(
            offset: fixedEnd,
            length: UInt64(nameLength + extraLength),
            limit: payloadLimit
        ), checkedEnd(
            offset: payloadOffset,
            length: entry.compressedSize,
            limit: payloadLimit
        ) != nil else {
            throw ReaderError.malformed("entry payload overruns the archive: \(entry.path)")
        }
        let variable = try readData(
            descriptor: descriptor,
            offset: fixedEnd,
            count: nameLength + extraLength
        )
        guard Data(variable.prefix(nameLength)) == Data(entry.path.utf8) else {
            throw ReaderError.malformed("local entry name disagrees: \(entry.path)")
        }
        let localExtra = Data(variable.dropFirst(nameLength))
        let localHasZip64Extra = try containsExtraField(
            identifier: 0x0001,
            in: localExtra,
            name: entry.path
        )

        if flags & 0x8 == 0 {
            var ignoredOffset: UInt64 = 0
            var ignoredDisk: UInt64 = 0
            if localCompressed == UInt64(UInt32.max)
                || localUncompressed == UInt64(UInt32.max) {
                try resolveZip64Extra(
                    Data(variable.dropFirst(nameLength)),
                    uncompressed: &localUncompressed,
                    compressed: &localCompressed,
                    localHeaderOffset: &ignoredOffset,
                    diskNumber: &ignoredDisk,
                    name: entry.path
                )
            }
            guard localCRC == entry.crc32,
                  localCompressed == entry.compressedSize,
                  localUncompressed == entry.uncompressedSize else {
                throw ReaderError.malformed(
                    "local sizes disagree with central directory: \(entry.path)"
                )
            }
        } else {
            guard (localCRC == 0 || localCRC == entry.crc32),
                  (localCompressed == 0
                    || localCompressed == UInt64(UInt32.max)
                    || localCompressed == entry.compressedSize),
                  (localUncompressed == 0
                    || localUncompressed == UInt64(UInt32.max)
                    || localUncompressed == entry.uncompressedSize) else {
                throw ReaderError.malformed(
                    "local streaming values disagree with central directory: \(entry.path)"
                )
            }
            guard let payloadEnd = checkedEnd(
                offset: payloadOffset,
                length: entry.compressedSize,
                limit: payloadLimit
            ) else {
                throw ReaderError.malformed("entry payload overruns the archive: \(entry.path)")
            }
            try validateDataDescriptor(
                descriptor: descriptor,
                offset: payloadEnd,
                limit: payloadLimit,
                entry: entry,
                usesZip64: entry.usesZip64DataDescriptor || localHasZip64Extra
            )
        }

        return Entry(
            path: entry.path,
            compressedSize: entry.compressedSize,
            uncompressedSize: entry.uncompressedSize,
            crc32: entry.crc32,
            compressionMethod: entry.compressionMethod,
            generalPurposeFlags: entry.generalPurposeFlags,
            localHeaderOffset: entry.localHeaderOffset,
            payloadOffset: payloadOffset,
            usesZip64DataDescriptor: entry.usesZip64DataDescriptor || localHasZip64Extra,
            isDirectory: entry.isDirectory,
            externalAttributes: entry.externalAttributes,
            snapshotIdentifier: entry.snapshotIdentifier,
            ordinal: entry.ordinal
        )
    }

    private static func validateGeneralPurposeFlags(
        _ flags: UInt16,
        method: UInt16,
        name: String
    ) throws {
        if flags & encryptionFlagMask != 0 {
            throw ReaderError.encrypted(name)
        }
        if flags & compressedPatchedDataFlag != 0 {
            throw ReaderError.unsupported("compressed patched data is unsupported: \(name)")
        }
        let allowed = dataDescriptorFlag
            | utf8Flag
            | (method == 8 ? deflateOptionFlagMask : 0)
        guard flags & ~allowed == 0 else {
            throw ReaderError.unsupported(
                "entry uses unsupported general-purpose flags: \(name)"
            )
        }
    }

    private static func validateDataDescriptor(
        descriptor: Int32,
        offset: UInt64,
        limit: UInt64,
        entry: Entry,
        usesZip64: Bool
    ) throws {
        let sizeWidth = usesZip64 ? 8 : 4
        let unsignedLength = 4 + (2 * sizeWidth)
        let signedLength = unsignedLength + 4
        guard offset <= limit else {
            throw ReaderError.malformed("data descriptor is missing: \(entry.path)")
        }
        let available = limit - offset
        let readCount = Int(min(UInt64(signedLength), available))
        let bytes = try readData(descriptor: descriptor, offset: offset, count: readCount)

        func matches(at start: Int) -> Bool {
            guard start + unsignedLength <= bytes.count,
                  read32(bytes, start) == entry.crc32 else {
                return false
            }
            if usesZip64 {
                return read64(bytes, start + 4) == entry.compressedSize
                    && read64(bytes, start + 12) == entry.uncompressedSize
            }
            return UInt64(read32(bytes, start + 4)) == entry.compressedSize
                && UInt64(read32(bytes, start + 8)) == entry.uncompressedSize
        }

        if bytes.count >= signedLength,
           read32(bytes, 0) == dataDescriptorSignature,
           matches(at: 4) {
            return
        }
        // A descriptor signature is optional. Trying the unsigned shape as a
        // second candidate also handles the valid edge case where the CRC is
        // itself 0x08074b50.
        guard matches(at: 0) else {
            throw ReaderError.malformed("data descriptor disagrees: \(entry.path)")
        }
    }

    private static func containsExtraField(
        identifier: UInt16,
        in data: Data,
        name: String
    ) throws -> Bool {
        var cursor = 0
        var found = false
        while cursor < data.count {
            guard cursor + 4 <= data.count else {
                throw ReaderError.malformed("extra field is truncated: \(name)")
            }
            let fieldIdentifier = read16(data, cursor)
            let fieldSize = Int(read16(data, cursor + 2))
            let body = cursor + 4
            guard body + fieldSize <= data.count else {
                throw ReaderError.malformed("extra field overruns: \(name)")
            }
            if fieldIdentifier == identifier { found = true }
            cursor = body + fieldSize
        }
        return found
    }

    private static func resolveZip64Extra(
        _ data: Data,
        uncompressed: inout UInt64,
        compressed: inout UInt64,
        localHeaderOffset: inout UInt64,
        diskNumber: inout UInt64,
        name: String
    ) throws {
        var cursor = 0
        while cursor + 4 <= data.count {
            let headerID = read16(data, cursor)
            let size = Int(read16(data, cursor + 2))
            let body = cursor + 4
            guard body + size <= data.count else {
                throw ReaderError.malformed("zip64 extra field overruns: \(name)")
            }
            if headerID == 0x0001 {
                var field = body
                let limit = body + size
                if uncompressed == UInt64(UInt32.max) {
                    guard field + 8 <= limit else {
                        throw ReaderError.malformed("zip64 extra field is short: \(name)")
                    }
                    uncompressed = read64(data, field)
                    field += 8
                }
                if compressed == UInt64(UInt32.max) {
                    guard field + 8 <= limit else {
                        throw ReaderError.malformed("zip64 extra field is short: \(name)")
                    }
                    compressed = read64(data, field)
                    field += 8
                }
                if localHeaderOffset == UInt64(UInt32.max) {
                    guard field + 8 <= limit else {
                        throw ReaderError.malformed("zip64 extra field is short: \(name)")
                    }
                    localHeaderOffset = read64(data, field)
                    field += 8
                }
                if diskNumber == UInt64(UInt16.max) {
                    guard field + 4 <= limit else {
                        throw ReaderError.malformed("zip64 extra field is short: \(name)")
                    }
                    diskNumber = UInt64(read32(data, field))
                }
                return
            }
            cursor = body + size
        }
        throw ReaderError.malformed("zip64 values are declared but absent: \(name)")
    }

    // MARK: - Bounded descriptor I/O

    private static func readData(descriptor: Int32, offset: UInt64, count: Int) throws -> Data {
        guard count >= 0,
              offset <= UInt64(Int64.max),
              UInt64(count) <= UInt64(Int64.max) - offset else {
            throw ReaderError.malformed("archive offset is out of range")
        }
        var data = Data(count: count)
        var completed = 0
        try data.withUnsafeMutableBytes { bytes in
            while completed < count {
                let result = Darwin.pread(
                    descriptor,
                    bytes.baseAddress?.advanced(by: completed),
                    count - completed,
                    off_t(offset + UInt64(completed))
                )
                if result < 0, errno == EINTR { continue }
                guard result > 0 else { throw ReaderError.unreadable }
                completed += result
            }
        }
        return data
    }

    private static func readSome(
        descriptor: Int32,
        into buffer: UnsafeMutableRawPointer?,
        count: Int,
        offset: UInt64
    ) throws -> Int {
        guard count > 0, offset <= UInt64(Int64.max) else { return 0 }
        while true {
            let result = Darwin.pread(descriptor, buffer, count, off_t(offset))
            if result < 0, errno == EINTR { continue }
            guard result >= 0 else { throw ReaderError.unreadable }
            return result
        }
    }

    private static func consumeOutput(
        _ bytes: UnsafeRawPointer,
        count: Int,
        output: Int32,
        produced: inout UInt64,
        expected: UInt64,
        maximum: UInt64,
        crc: inout UInt32,
        hasher: inout SHA256,
        name: String
    ) throws {
        let next = produced.addingReportingOverflow(UInt64(count))
        guard !next.overflow,
              next.partialValue <= expected,
              next.partialValue <= maximum else {
            throw ReaderError.malformed("entry exceeds its output budget: \(name)")
        }
        let typed = bytes.assumingMemoryBound(to: UInt8.self)
        for index in 0..<count {
            crc = crcTable[Int((crc ^ UInt32(typed[index])) & 0xFF)] ^ (crc >> 8)
        }
        hasher.update(data: Data(bytes: bytes, count: count))
        var written = 0
        while written < count {
            let result = Darwin.write(output, bytes.advanced(by: written), count - written)
            if result < 0, errno == EINTR { continue }
            guard result > 0 else {
                throw ReaderError.malformed("cannot write \(name)")
            }
            written += result
        }
        produced = next.partialValue
    }

    private static func checkedEnd(offset: UInt64, length: UInt64, limit: UInt64) -> UInt64? {
        let end = offset.addingReportingOverflow(length)
        guard !end.overflow, end.partialValue <= limit else { return nil }
        return end.partialValue
    }

    private static func locateEndOfCentralDirectory(in data: Data) -> Int? {
        guard data.count >= 22 else { return nil }
        for offset in stride(from: data.count - 22, through: 0, by: -1) {
            guard read32(data, offset) == endOfCentralDirectorySignature else { continue }
            let commentLength = Int(read16(data, offset + 20))
            if offset + 22 + commentLength == data.count { return offset }
        }
        return nil
    }

    private static func throwIfCancelled(
        _ shouldCancel: @escaping @Sendable () -> Bool
    ) throws {
        if shouldCancel() { throw CancellationError() }
    }

    private static let crcTable: [UInt32] = {
        (0..<256).map { index -> UInt32 in
            var value = UInt32(index)
            for _ in 0..<8 {
                value = (value & 1) != 0 ? (0xEDB8_8320 ^ (value >> 1)) : (value >> 1)
            }
            return value
        }
    }()

    static func crc32(_ data: Data) -> UInt32 {
        var value: UInt32 = 0xFFFF_FFFF
        for byte in data {
            value = crcTable[Int((value ^ UInt32(byte)) & 0xFF)] ^ (value >> 8)
        }
        return value ^ 0xFFFF_FFFF
    }

    private static func read16(_ data: Data, _ offset: Int) -> UInt16 {
        guard offset >= 0, offset + 2 <= data.count else { return 0 }
        return UInt16(data[offset]) | (UInt16(data[offset + 1]) << 8)
    }

    private static func read32(_ data: Data, _ offset: Int) -> UInt32 {
        guard offset >= 0, offset + 4 <= data.count else { return 0 }
        var value: UInt32 = 0
        for index in (0..<4).reversed() {
            value = (value << 8) | UInt32(data[offset + index])
        }
        return value
    }

    private static func read64(_ data: Data, _ offset: Int) -> UInt64 {
        guard offset >= 0, offset + 8 <= data.count else { return 0 }
        var value: UInt64 = 0
        for index in (0..<8).reversed() {
            value = (value << 8) | UInt64(data[offset + index])
        }
        return value
    }
}
