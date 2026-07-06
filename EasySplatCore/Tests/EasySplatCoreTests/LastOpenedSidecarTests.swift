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

    func testSaveCreatesParentDirectoryIfNeeded() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let nested = root.appendingPathComponent("nested/dir/last_opened.json")
        let stamp = Date(timeIntervalSince1970: 0)
        try LastOpenedSidecar.save(stamp, to: nested)
        XCTAssertEqual(LastOpenedSidecar.load(from: nested), stamp)
    }
}
