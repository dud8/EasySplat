import Compression
import Darwin
import Foundation

/// Reads zip archives without shelling out.
///
/// A sandboxed process cannot lend its file access to `/usr/bin/unzip`: that
/// binary carries no entitlements, so a child spawned from a sandboxed parent
/// sees the parent's restrictions and none of the extensions the parent was
/// granted for a file the user chose. Reading in process removes the question,
/// and it also means nothing unsafe is ever materialised — entries are checked
/// against the central directory before a byte is written.
enum ZipArchiveReader {
    struct Entry {
        var path: String
        var compressedSize: UInt64
        var uncompressedSize: UInt64
        var crc32: UInt32
        var compressionMethod: UInt16
        var localHeaderOffset: UInt64
        var isDirectory: Bool
        var externalAttributes: UInt32

        /// Zip stores the Unix mode in the high 16 bits when it was written on a
        /// Unix host. Anything that is not a plain file or a directory — a
        /// symlink above all — must never be materialised.
        var unixMode: mode_t {
            mode_t((externalAttributes >> 16) & 0xFFFF)
        }

        var isSymbolicLink: Bool {
            (unixMode & S_IFMT) == S_IFLNK
        }
    }

    enum ReaderError: Error, Equatable {
        case unreadable
        case malformed(String)
        case unsupported(String)
        case encrypted(String)
        case checksumMismatch(String)
    }

    private static let endOfCentralDirectorySignature: UInt32 = 0x0605_4B50
    private static let zip64LocatorSignature: UInt32 = 0x0706_4B50
    private static let zip64EndSignature: UInt32 = 0x0606_4B50
    private static let centralFileHeaderSignature: UInt32 = 0x0201_4B50
    private static let localFileHeaderSignature: UInt32 = 0x0403_4B50
    private static let maximumEntryCount = 512_000
    private static let maximumEntryBytes: UInt64 = 8 << 30

    // MARK: - Central directory

    /// Parses the central directory. Local headers are never trusted for sizes:
    /// a mismatch between the two is a classic way to smuggle content past a
    /// check that read only one of them.
    static func readEntries(at url: URL) throws -> [Entry] {
        let data = try mappedContents(of: url)
        let eocd = try locateEndOfCentralDirectory(in: data)
        var entryCount = Int(read16(data, eocd + 10))
        var directoryOffset = UInt64(read32(data, eocd + 16))
        var directorySize = UInt64(read32(data, eocd + 12))

        if entryCount == 0xFFFF || directoryOffset == 0xFFFF_FFFF || directorySize == 0xFFFF_FFFF {
            let locator = try locateZip64Locator(in: data, endOfCentralDirectory: eocd)
            guard let zip64End = boundedOffset(read64(data, locator + 8), limit: data.count),
                  zip64End + 56 <= data.count,
                  read32(data, zip64End) == zip64EndSignature else {
                throw ReaderError.malformed("zip64 end record is missing")
            }
            guard let declaredCount = boundedOffset(
                read64(data, zip64End + 32),
                limit: maximumEntryCount
            ) else {
                throw ReaderError.malformed("zip64 entry count is out of range")
            }
            entryCount = declaredCount
            directorySize = read64(data, zip64End + 40)
            directoryOffset = read64(data, zip64End + 48)
        }

        guard entryCount >= 0, entryCount <= maximumEntryCount else {
            throw ReaderError.malformed("archive declares too many entries")
        }
        guard directoryOffset <= UInt64(data.count),
              directorySize <= UInt64(data.count),
              directoryOffset + directorySize <= UInt64(data.count) else {
            throw ReaderError.malformed("central directory lies outside the archive")
        }

        var entries: [Entry] = []
        entries.reserveCapacity(entryCount)
        var cursor = Int(directoryOffset)
        for _ in 0..<entryCount {
            guard cursor + 46 <= data.count,
                  read32(data, cursor) == centralFileHeaderSignature else {
                throw ReaderError.malformed("central directory header is malformed")
            }
            let flags = read16(data, cursor + 8)
            let method = read16(data, cursor + 10)
            let crc = read32(data, cursor + 16)
            var compressed = UInt64(read32(data, cursor + 20))
            var uncompressed = UInt64(read32(data, cursor + 24))
            let nameLength = Int(read16(data, cursor + 28))
            let extraLength = Int(read16(data, cursor + 30))
            let commentLength = Int(read16(data, cursor + 32))
            let attributes = read32(data, cursor + 38)
            var localOffset = UInt64(read32(data, cursor + 42))

            let nameStart = cursor + 46
            guard nameStart + nameLength + extraLength + commentLength <= data.count else {
                throw ReaderError.malformed("central directory entry overruns the archive")
            }
            guard let name = String(
                data: data.subdata(in: nameStart..<(nameStart + nameLength)),
                encoding: .utf8
            ) else {
                throw ReaderError.malformed("entry name is not UTF-8")
            }
            if flags & 0x1 != 0 {
                throw ReaderError.encrypted(name)
            }

            if uncompressed == 0xFFFF_FFFF || compressed == 0xFFFF_FFFF || localOffset == 0xFFFF_FFFF {
                let extraStart = nameStart + nameLength
                try readZip64Extra(
                    data,
                    start: extraStart,
                    length: extraLength,
                    uncompressed: &uncompressed,
                    compressed: &compressed,
                    localHeaderOffset: &localOffset,
                    name: name
                )
            }

            entries.append(Entry(
                path: name,
                compressedSize: compressed,
                uncompressedSize: uncompressed,
                crc32: crc,
                compressionMethod: method,
                localHeaderOffset: localOffset,
                isDirectory: name.hasSuffix("/"),
                externalAttributes: attributes
            ))
            cursor = nameStart + nameLength + extraLength + commentLength
        }
        return entries
    }

    // MARK: - Extraction

    /// Writes one entry's bytes. The caller has already validated the name, so
    /// this only has to refuse to follow anything and verify what it produced.
    static func extract(
        entry: Entry,
        from url: URL,
        into directoryDescriptor: Int32,
        relativePath: String
    ) throws {
        let data = try mappedContents(of: url)
        let payload = try payloadRange(data, entry: entry)
        let produced: Data
        switch entry.compressionMethod {
        case 0:
            produced = data.subdata(in: payload)
        case 8:
            guard let expected = boundedOffset(
                entry.uncompressedSize,
                limit: Int(maximumEntryBytes)
            ) else {
                throw ReaderError.malformed("entry declares an unusable size: \(entry.path)")
            }
            produced = try inflate(
                data.subdata(in: payload),
                expectedSize: expected,
                name: entry.path
            )
        default:
            throw ReaderError.unsupported(
                "entry uses an unsupported compression method: \(entry.path)"
            )
        }

        guard UInt64(produced.count) == entry.uncompressedSize else {
            throw ReaderError.malformed("entry size does not match its declaration: \(entry.path)")
        }
        guard crc32(produced) == entry.crc32 else {
            throw ReaderError.checksumMismatch(entry.path)
        }

        let descriptor = relativePath.withCString {
            openat(directoryDescriptor, $0, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o644)
        }
        guard descriptor >= 0 else {
            throw ReaderError.malformed("cannot create \(relativePath)")
        }
        defer { close(descriptor) }

        var written = 0
        try produced.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return }
            while written < produced.count {
                let count = Darwin.write(descriptor, base.advanced(by: written), produced.count - written)
                if count < 0 {
                    if errno == EINTR { continue }
                    throw ReaderError.malformed("cannot write \(relativePath)")
                }
                if count == 0 { break }
                written += count
            }
        }
        guard written == produced.count else {
            throw ReaderError.malformed("short write for \(relativePath)")
        }
    }

    // MARK: - Reading helpers

    private static func mappedContents(of url: URL) throws -> Data {
        do {
            return try Data(contentsOf: url, options: [.mappedIfSafe])
        } catch {
            throw ReaderError.unreadable
        }
    }

    private static func payloadRange(_ data: Data, entry: Entry) throws -> Range<Int> {
        guard let offset = boundedOffset(entry.localHeaderOffset, limit: data.count),
              let compressed = boundedOffset(entry.compressedSize, limit: data.count),
              offset + 30 <= data.count,
              read32(data, offset) == localFileHeaderSignature else {
            throw ReaderError.malformed("local header is malformed: \(entry.path)")
        }
        let nameLength = Int(read16(data, offset + 26))
        let extraLength = Int(read16(data, offset + 28))
        let start = offset + 30 + nameLength + extraLength
        let (end, overflowed) = start.addingReportingOverflow(compressed)
        guard start >= 0, !overflowed, end <= data.count else {
            throw ReaderError.malformed("entry payload overruns the archive: \(entry.path)")
        }
        return start..<end
    }

    /// Narrows an archive-declared 64-bit value to an in-range offset, or nil.
    private static func boundedOffset(_ value: UInt64, limit: Int) -> Int? {
        guard limit >= 0, value <= UInt64(limit) else { return nil }
        return Int(value)
    }

    private static func readZip64Extra(
        _ data: Data,
        start: Int,
        length: Int,
        uncompressed: inout UInt64,
        compressed: inout UInt64,
        localHeaderOffset: inout UInt64,
        name: String
    ) throws {
        var cursor = start
        let limit = start + length
        while cursor + 4 <= limit {
            let headerID = read16(data, cursor)
            let size = Int(read16(data, cursor + 2))
            let body = cursor + 4
            guard body + size <= limit else {
                throw ReaderError.malformed("zip64 extra field overruns: \(name)")
            }
            if headerID == 0x0001 {
                var field = body
                if uncompressed == 0xFFFF_FFFF {
                    guard field + 8 <= body + size else {
                        throw ReaderError.malformed("zip64 extra field is short: \(name)")
                    }
                    uncompressed = read64(data, field)
                    field += 8
                }
                if compressed == 0xFFFF_FFFF {
                    guard field + 8 <= body + size else {
                        throw ReaderError.malformed("zip64 extra field is short: \(name)")
                    }
                    compressed = read64(data, field)
                    field += 8
                }
                if localHeaderOffset == 0xFFFF_FFFF {
                    guard field + 8 <= body + size else {
                        throw ReaderError.malformed("zip64 extra field is short: \(name)")
                    }
                    localHeaderOffset = read64(data, field)
                }
                return
            }
            cursor = body + size
        }
        throw ReaderError.malformed("zip64 sizes are declared but absent: \(name)")
    }

    private static func locateEndOfCentralDirectory(in data: Data) throws -> Int {
        let minimum = 22
        guard data.count >= minimum else { throw ReaderError.malformed("archive is too small") }
        let searchLimit = min(data.count, minimum + 65_535)
        var offset = data.count - minimum
        let lowest = data.count - searchLimit
        while offset >= lowest {
            if read32(data, offset) == endOfCentralDirectorySignature {
                let commentLength = Int(read16(data, offset + 20))
                if offset + minimum + commentLength == data.count {
                    return offset
                }
            }
            offset -= 1
        }
        throw ReaderError.malformed("end of central directory record is missing")
    }

    private static func locateZip64Locator(in data: Data, endOfCentralDirectory: Int) throws -> Int {
        let locator = endOfCentralDirectory - 20
        guard locator >= 0, read32(data, locator) == zip64LocatorSignature else {
            throw ReaderError.malformed("zip64 locator is missing")
        }
        return locator
    }

    private static func inflate(_ data: Data, expectedSize: Int, name: String) throws -> Data {
        guard expectedSize >= 0 else {
            throw ReaderError.malformed("entry declares a negative size: \(name)")
        }
        if expectedSize == 0 { return Data() }
        var output = Data(count: expectedSize)
        let produced: Int = output.withUnsafeMutableBytes { destination in
            data.withUnsafeBytes { source -> Int in
                guard let destinationBase = destination.baseAddress?.assumingMemoryBound(to: UInt8.self),
                      let sourceBase = source.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
                    return 0
                }
                return compression_decode_buffer(
                    destinationBase,
                    expectedSize,
                    sourceBase,
                    data.count,
                    nil,
                    COMPRESSION_ZLIB
                )
            }
        }
        guard produced == expectedSize else {
            throw ReaderError.malformed("entry did not inflate to its declared size: \(name)")
        }
        return output
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
