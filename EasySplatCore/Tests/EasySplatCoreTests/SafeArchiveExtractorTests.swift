import XCTest
@testable import EasySplatCore

/// Driven by archives built byte by byte, so entries no ordinary zip tool will
/// produce — absolute paths, traversal, case collisions, device nodes — can
/// still be exercised.
final class SafeArchiveExtractorTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
        try super.tearDownWithError()
    }

    private func destination() -> URL {
        root.appendingPathComponent("out-\(UUID().uuidString)", isDirectory: true)
    }

    private func archive(_ name: String, _ entries: [ZipFixtureBuilder.Entry]) throws -> URL {
        try ZipFixtureBuilder.build(at: root.appendingPathComponent(name), entries: entries)
    }

    private func assertThrows(
        _ expected: SafeArchiveExtractor.ExtractionError,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ body: () throws -> Void
    ) {
        XCTAssertThrowsError(try body(), file: file, line: line) { error in
            XCTAssertEqual(
                error as? SafeArchiveExtractor.ExtractionError,
                expected,
                file: file,
                line: line
            )
        }
    }

    // MARK: - Happy path

    func testExtractReturnsSortedInventoryWithByteCounts() throws {
        let zip = try archive("ok.zip", [
            .directory(path: "images/"),
            .file(path: "images/1.jpg", contents: Data(count: 8)),
            .file(path: "images/0.jpg", contents: Data(count: 12)),
            .file(path: "transforms.json", contents: Data(count: 20)),
        ])

        let inventory = try SafeArchiveExtractor.extract(zipURL: zip, to: destination())

        XCTAssertEqual(inventory.entries, [
            .init(relativePath: "images/0.jpg", byteCount: 12),
            .init(relativePath: "images/1.jpg", byteCount: 8),
            .init(relativePath: "transforms.json", byteCount: 20),
        ])
        XCTAssertEqual(inventory.totalBytes, 40)
    }

    func testDirectoryEntriesWithTrailingSlashAreOptIn() throws {
        let zip = try archive("dirs.zip", [
            .directory(path: "images/"),
            .file(path: "images/a.txt", contents: Data("a".utf8)),
        ])

        let inventory = try SafeArchiveExtractor.extract(zipURL: zip, to: destination())
        XCTAssertEqual(inventory.entries.map(\.relativePath), ["images/a.txt"])

        // The toolchain path keeps the strict default and rejects the marker.
        XCTAssertThrowsError(
            try SafeArchiveExtractor.validateEntryPaths(["images/", "images/a.txt"])
        )
    }

    // MARK: - Pre-extraction listing rejections

    func testRejectsSymbolicLinkEntry() throws {
        let zip = try archive("link.zip", [
            .symlink(path: "bin/escape", target: "/etc/passwd"),
            .file(path: "bin/tool", contents: Data(count: 10)),
        ])
        assertThrows(.symbolicLinkEntry) {
            _ = try SafeArchiveExtractor.extract(zipURL: zip, to: self.destination())
        }
    }

    func testRejectsSpecialFileEntry() throws {
        let zip = try archive("fifo.zip", [
            .special(path: "pipe", mode: S_IFIFO | 0o644),
            .file(path: "a.txt", contents: Data(count: 4)),
        ])
        assertThrows(.specialFileEntry) {
            _ = try SafeArchiveExtractor.extract(zipURL: zip, to: self.destination())
        }
    }

    func testRejectsAbsolutePathEntry() throws {
        let zip = try archive("abs.zip", [
            .file(path: "/etc/passwd", contents: Data("x".utf8)),
        ])
        XCTAssertThrowsError(
            try SafeArchiveExtractor.extract(zipURL: zip, to: destination())
        )
    }

    func testRejectsTraversalEntry() throws {
        let zip = try archive("traverse.zip", [
            .file(path: "../escape.txt", contents: Data("x".utf8)),
        ])
        XCTAssertThrowsError(
            try SafeArchiveExtractor.extract(zipURL: zip, to: destination())
        )
    }

    func testRejectsCaseInsensitiveCollision() throws {
        let zip = try archive("collide.zip", [
            .file(path: "Image.PNG", contents: Data("a".utf8)),
            .file(path: "image.png", contents: Data("b".utf8)),
        ])
        XCTAssertThrowsError(
            try SafeArchiveExtractor.extract(zipURL: zip, to: destination())
        )
    }

    // MARK: - Limits

    func testRejectsPerEntrySizeCap() throws {
        let zip = try archive("big.zip", [
            .file(path: "big.bin", contents: Data(count: 4096)),
        ])
        let limits = SafeArchiveExtractor.ExtractionLimits(
            maxEntryCount: 64,
            maxEntryUncompressedBytes: 1024,
            maxTotalUncompressedBytes: 1 << 20
        )
        XCTAssertThrowsError(
            try SafeArchiveExtractor.extract(zipURL: zip, to: destination(), limits: limits)
        )
    }

    func testRejectsAggregateSizeCap() throws {
        let zip = try archive("total.zip", (0..<8).map {
            .file(path: "f\($0).bin", contents: Data(count: 512))
        })
        let limits = SafeArchiveExtractor.ExtractionLimits(
            maxEntryCount: 64,
            maxEntryUncompressedBytes: 1 << 20,
            maxTotalUncompressedBytes: 1024
        )
        XCTAssertThrowsError(
            try SafeArchiveExtractor.extract(zipURL: zip, to: destination(), limits: limits)
        )
    }

    func testRejectsEntryCountCap() throws {
        let zip = try archive("many.zip", (0..<12).map {
            .file(path: "f\($0).txt", contents: Data("x".utf8))
        })
        let limits = SafeArchiveExtractor.ExtractionLimits(
            maxEntryCount: 4,
            maxEntryUncompressedBytes: 1 << 20,
            maxTotalUncompressedBytes: 1 << 20
        )
        assertThrows(.entryCountExceeded(limit: 4)) {
            _ = try SafeArchiveExtractor.extract(
                zipURL: zip,
                to: self.destination(),
                limits: limits
            )
        }
    }

    func testRejectsAnUnreadableArchive() {
        assertThrows(.listingFailed) {
            _ = try SafeArchiveExtractor.extract(
                zipURL: self.root.appendingPathComponent("absent.zip"),
                to: self.destination()
            )
        }
    }

    // MARK: - Post-extraction

    func testRejectsExtractedSymbolicLink() throws {
        let target = destination()
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: target.appendingPathComponent("planted.txt"),
            withDestinationURL: URL(fileURLWithPath: "/etc/passwd")
        )
        XCTAssertThrowsError(try SafeArchiveExtractor.inventory(of: target))
    }
}
