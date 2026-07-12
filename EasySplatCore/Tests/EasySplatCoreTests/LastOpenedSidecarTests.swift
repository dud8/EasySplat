import XCTest
@testable import EasySplatCore

final class LastOpenedSidecarTests: XCTestCase {
    func testRoundTripPersistsTimestamp() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("last_opened.json")
        let stamp = Date(timeIntervalSince1970: 1_800_000_000)
        try LastOpenedSidecar.save(stamp, to: url)
        XCTAssertEqual(LastOpenedSidecar.load(from: url), stamp)
    }

    func testLoadReturnsNilForMissingFile() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("missing-\(UUID().uuidString).json")
        XCTAssertNil(LastOpenedSidecar.load(from: url))
    }

    func testLoadReturnsNilForCorruptFile() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("last_opened.json")
        try "not json".write(to: url, atomically: true, encoding: .utf8)
        XCTAssertNil(LastOpenedSidecar.load(from: url))
    }

    func testLoadRejectsOversizedOtherwiseValidSidecar() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("last_opened.json")
        let stamp = Date(timeIntervalSince1970: 1_800_000_000)
        try LastOpenedSidecar.save(stamp, to: url)
        var oversized = try Data(contentsOf: url)
        oversized.append(Data(repeating: 0x20, count: 8 * 1_024))
        try oversized.write(to: url, options: [.atomic])

        XCTAssertNil(LastOpenedSidecar.load(from: url))
    }

    func testLoadRejectsSymlinkWithoutFollowingTarget() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let outside = root.appendingPathComponent("outside.json")
        let stamp = Date(timeIntervalSince1970: 1_800_000_000)
        try LastOpenedSidecar.save(stamp, to: outside)
        let linked = root.appendingPathComponent("last_opened.json")
        try FileManager.default.createSymbolicLink(at: linked, withDestinationURL: outside)

        XCTAssertNil(LastOpenedSidecar.load(from: linked))
    }

    func testSaveCreatesParentDirectoryIfNeeded() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let nested = root.appendingPathComponent("nested/dir/last_opened.json")
        let stamp = Date(timeIntervalSince1970: 0)
        try LastOpenedSidecar.save(stamp, to: nested)
        XCTAssertEqual(LastOpenedSidecar.load(from: nested), stamp)
    }

    func testSaveRejectsSymlinkedParentWithoutWritingOutside() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let outside = root.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let linkedParent = root.appendingPathComponent("Linked.easysplatproj", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: linkedParent, withDestinationURL: outside)

        XCTAssertThrowsError(
            try LastOpenedSidecar.save(
                Date(timeIntervalSince1970: 1_800_000_000),
                to: linkedParent.appendingPathComponent("last_opened.json")
            )
        )
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: outside.appendingPathComponent("last_opened.json").path
            )
        )
    }
}
