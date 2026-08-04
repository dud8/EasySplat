import Darwin
import Foundation
@testable import EasySplatCore

/// Writes zip archives byte by byte.
///
/// The rejections that matter most — absolute paths, traversal, case collisions,
/// symlink and device entries — are precisely the ones `zip(1)` refuses to
/// produce, so they have to be assembled by hand.
enum ZipFixtureBuilder {
    struct Entry {
        var path: String
        var contents: Data
        var mode: mode_t

        static func file(path: String, contents: Data) -> Entry {
            Entry(path: path, contents: contents, mode: S_IFREG | 0o644)
        }

        static func directory(path: String) -> Entry {
            Entry(
                path: path.hasSuffix("/") ? path : path + "/",
                contents: Data(),
                mode: S_IFDIR | 0o755
            )
        }

        static func symlink(path: String, target: String) -> Entry {
            Entry(path: path, contents: Data(target.utf8), mode: S_IFLNK | 0o777)
        }

        static func special(path: String, mode: mode_t) -> Entry {
            Entry(path: path, contents: Data(), mode: mode)
        }
    }

    @discardableResult
    static func build(at url: URL, entries: [Entry]) throws -> URL {
        var archive = Data()
        var central = Data()
        var count: UInt16 = 0

        for entry in entries {
            let name = Data(entry.path.utf8)
            let crc = ZipArchiveReader.crc32(entry.contents)
            let offset = UInt32(archive.count)

            // Local file header, stored (method 0) so the payload is verbatim.
            archive.append(uint32: 0x0403_4B50)
            archive.append(uint16: 20)
            archive.append(uint16: 0)
            archive.append(uint16: 0)
            archive.append(uint16: 0)
            archive.append(uint16: 0)
            archive.append(uint32: crc)
            archive.append(uint32: UInt32(entry.contents.count))
            archive.append(uint32: UInt32(entry.contents.count))
            archive.append(uint16: UInt16(name.count))
            archive.append(uint16: 0)
            archive.append(name)
            archive.append(entry.contents)

            central.append(uint32: 0x0201_4B50)
            central.append(uint16: 0x031E)          // made by a Unix host
            central.append(uint16: 20)
            central.append(uint16: 0)
            central.append(uint16: 0)
            central.append(uint16: 0)
            central.append(uint16: 0)
            central.append(uint32: crc)
            central.append(uint32: UInt32(entry.contents.count))
            central.append(uint32: UInt32(entry.contents.count))
            central.append(uint16: UInt16(name.count))
            central.append(uint16: 0)
            central.append(uint16: 0)
            central.append(uint16: 0)
            central.append(uint16: 0)
            central.append(uint32: UInt32(entry.mode) << 16)
            central.append(uint32: offset)
            central.append(name)
            count += 1
        }

        let centralOffset = UInt32(archive.count)
        archive.append(central)
        archive.append(uint32: 0x0605_4B50)
        archive.append(uint16: 0)
        archive.append(uint16: 0)
        archive.append(uint16: count)
        archive.append(uint16: count)
        archive.append(uint32: UInt32(central.count))
        archive.append(uint32: centralOffset)
        archive.append(uint16: 0)

        try archive.write(to: url)
        return url
    }
}

private extension Data {
    mutating func append(uint16 value: UInt16) {
        append(UInt8(value & 0xFF))
        append(UInt8((value >> 8) & 0xFF))
    }

    mutating func append(uint32 value: UInt32) {
        for shift in stride(from: 0, through: 24, by: 8) {
            append(UInt8((value >> UInt32(shift)) & 0xFF))
        }
    }
}
