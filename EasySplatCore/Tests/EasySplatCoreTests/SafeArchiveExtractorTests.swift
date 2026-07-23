import XCTest
@testable import EasySplatCore

final class SafeArchiveExtractorTests: XCTestCase {

    // MARK: - Scripting helpers

    private func archiveURL() -> URL {
        URL(fileURLWithPath: "/tmp/safe-archive-\(UUID().uuidString).zip")
    }

    /// Builds one `zipinfo -l` long-format row: mode, uncompressed size, and name.
    private func metadataLine(mode: String, size: Int, name: String) -> String {
        "\(mode)  3.0 unx \(size) bx \(size) defN 01-Jan-26 00:00 \(name)"
    }

    private func zipinfoScript(_ lines: [String]) -> MockSubprocessRunner.Script {
        .init(
            path: "/usr/bin/zipinfo",
            argsPrefix: ["-l"],
            result: .init(exitCode: 0, terminationReason: .exit, stdout: "", stderr: ""),
            stdoutLines: lines
        )
    }

    private func unzipListScript(_ names: [String]) -> MockSubprocessRunner.Script {
        .init(
            path: "/usr/bin/unzip",
            argsPrefix: ["-Z1"],
            result: .init(exitCode: 0, terminationReason: .exit, stdout: "", stderr: ""),
            stdoutLines: names
        )
    }

    private func unzipExtractScript(
        onRun: @escaping @Sendable ([String]) throws -> Void
    ) -> MockSubprocessRunner.Script {
        .init(
            path: "/usr/bin/unzip",
            argsPrefix: ["-o"],
            result: .init(exitCode: 0, terminationReason: .exit, stdout: "", stderr: ""),
            onRun: onRun
        )
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
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let destination = root.appendingPathComponent("out", isDirectory: true)

        let names = ["transforms.json", "images/0.jpg", "images/1.jpg"]
        let metadata = [
            metadataLine(mode: "drwxr-xr-x", size: 0, name: "images/"),
            metadataLine(mode: "-rw-r--r--", size: 12, name: "images/0.jpg"),
            metadataLine(mode: "-rw-r--r--", size: 8, name: "images/1.jpg"),
            metadataLine(mode: "-rw-r--r--", size: 20, name: "transforms.json"),
        ]
        let extractScript = unzipExtractScript { args in
            guard let index = args.firstIndex(of: "-d") else { return }
            let destination = URL(fileURLWithPath: args[index + 1], isDirectory: true)
            for (relative, length) in [("images/0.jpg", 12), ("images/1.jpg", 8), ("transforms.json", 20)] {
                let file = destination.appendingPathComponent(relative)
                try FileManager.default.createDirectory(
                    at: file.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try Data(count: length).write(to: file)
            }
        }
        let runner = MockSubprocessRunner(
            scripts: [zipinfoScript(metadata), unzipListScript(names), extractScript]
        )

        let inventory = try SafeArchiveExtractor.extract(
            zipURL: archiveURL(),
            to: destination,
            runner: runner
        )

        XCTAssertEqual(inventory.entries, [
            .init(relativePath: "images/0.jpg", byteCount: 12),
            .init(relativePath: "images/1.jpg", byteCount: 8),
            .init(relativePath: "transforms.json", byteCount: 20),
        ])
        XCTAssertEqual(inventory.totalBytes, 40)
    }

    // MARK: - Pre-extraction listing rejections

    func testRejectsSymbolicLinkEntry() {
        let runner = MockSubprocessRunner(scripts: [
            zipinfoScript([
                metadataLine(mode: "lrwxr-xr-x", size: 12, name: "bin/escape"),
                metadataLine(mode: "-rw-r--r--", size: 10, name: "bin/tool"),
            ]),
        ])
        assertThrows(.symbolicLinkEntry) {
            _ = try SafeArchiveExtractor.extract(
                zipURL: archiveURL(),
                to: URL(fileURLWithPath: "/tmp/unused"),
                runner: runner
            )
        }
    }

    func testRejectsSpecialFileEntry() {
        let runner = MockSubprocessRunner(scripts: [
            zipinfoScript([
                metadataLine(mode: "prw-r--r--", size: 0, name: "bin/pipe"),
                metadataLine(mode: "-rw-r--r--", size: 10, name: "bin/tool"),
            ]),
        ])
        assertThrows(.specialFileEntry) {
            _ = try SafeArchiveExtractor.extract(
                zipURL: archiveURL(),
                to: URL(fileURLWithPath: "/tmp/unused"),
                runner: runner
            )
        }
    }

    func testRejectsAbsolutePathEntry() {
        let runner = MockSubprocessRunner(scripts: [
            zipinfoScript([metadataLine(mode: "-rw-r--r--", size: 4, name: "escape")]),
            unzipListScript(["/etc/passwd"]),
        ])
        assertThrows(.unsafeEntryPath("/etc/passwd")) {
            _ = try SafeArchiveExtractor.extract(
                zipURL: archiveURL(),
                to: URL(fileURLWithPath: "/tmp/unused"),
                runner: runner
            )
        }
    }

    func testRejectsTraversalEntry() {
        let runner = MockSubprocessRunner(scripts: [
            zipinfoScript([metadataLine(mode: "-rw-r--r--", size: 4, name: "escape")]),
            unzipListScript(["bin/../../escape"]),
        ])
        assertThrows(.pathTraversal("bin/../../escape")) {
            _ = try SafeArchiveExtractor.extract(
                zipURL: archiveURL(),
                to: URL(fileURLWithPath: "/tmp/unused"),
                runner: runner
            )
        }
    }

    func testRejectsCaseInsensitiveCollision() {
        let runner = MockSubprocessRunner(scripts: [
            zipinfoScript([
                metadataLine(mode: "-rw-r--r--", size: 4, name: "Photo.JPG"),
                metadataLine(mode: "-rw-r--r--", size: 4, name: "photo.jpg"),
            ]),
            unzipListScript(["Photo.JPG", "photo.jpg"]),
        ])
        assertThrows(.caseInsensitiveCollision("Photo.JPG", "photo.jpg")) {
            _ = try SafeArchiveExtractor.extract(
                zipURL: archiveURL(),
                to: URL(fileURLWithPath: "/tmp/unused"),
                runner: runner
            )
        }
    }

    // MARK: - Size and count caps

    func testRejectsPerEntrySizeCap() {
        let limits = SafeArchiveExtractor.ExtractionLimits(
            maxEntryCount: 1_000,
            maxEntryUncompressedBytes: 50,
            maxTotalUncompressedBytes: 1_000_000
        )
        let runner = MockSubprocessRunner(scripts: [
            zipinfoScript([metadataLine(mode: "-rw-r--r--", size: 100, name: "big.bin")]),
            unzipListScript(["big.bin"]),
        ])
        assertThrows(.entryTooLarge(path: "big.bin", bytes: 100, limit: 50)) {
            _ = try SafeArchiveExtractor.extract(
                zipURL: archiveURL(),
                to: URL(fileURLWithPath: "/tmp/unused"),
                limits: limits,
                runner: runner
            )
        }
    }

    func testRejectsAggregateSizeCap() {
        let limits = SafeArchiveExtractor.ExtractionLimits(
            maxEntryCount: 1_000,
            maxEntryUncompressedBytes: 1_000,
            maxTotalUncompressedBytes: 150
        )
        let runner = MockSubprocessRunner(scripts: [
            zipinfoScript([
                metadataLine(mode: "-rw-r--r--", size: 100, name: "a.bin"),
                metadataLine(mode: "-rw-r--r--", size: 100, name: "b.bin"),
            ]),
            unzipListScript(["a.bin", "b.bin"]),
        ])
        assertThrows(.totalSizeExceeded(bytes: 200, limit: 150)) {
            _ = try SafeArchiveExtractor.extract(
                zipURL: archiveURL(),
                to: URL(fileURLWithPath: "/tmp/unused"),
                limits: limits,
                runner: runner
            )
        }
    }

    func testRejectsEntryCountCap() {
        let limits = SafeArchiveExtractor.ExtractionLimits(
            maxEntryCount: 2,
            maxEntryUncompressedBytes: 1_000,
            maxTotalUncompressedBytes: 1_000_000
        )
        let runner = MockSubprocessRunner(scripts: [
            zipinfoScript([metadataLine(mode: "-rw-r--r--", size: 4, name: "a.bin")]),
            unzipListScript(["a.bin", "b.bin", "c.bin"]),
        ])
        assertThrows(.entryCountExceeded(limit: 2)) {
            _ = try SafeArchiveExtractor.extract(
                zipURL: archiveURL(),
                to: URL(fileURLWithPath: "/tmp/unused"),
                limits: limits,
                runner: runner
            )
        }
    }

    // MARK: - Post-extraction rejection

    func testRejectsExtractedSymbolicLink() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let destination = root.appendingPathComponent("out", isDirectory: true)

        let extractScript = unzipExtractScript { args in
            guard let index = args.firstIndex(of: "-d") else { return }
            let destination = URL(fileURLWithPath: args[index + 1], isDirectory: true)
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
            try FileManager.default.createSymbolicLink(
                at: destination.appendingPathComponent("evil"),
                withDestinationURL: URL(fileURLWithPath: "/etc/passwd")
            )
        }
        let runner = MockSubprocessRunner(scripts: [
            zipinfoScript([metadataLine(mode: "-rw-r--r--", size: 4, name: "evil")]),
            unzipListScript(["evil"]),
            extractScript,
        ])

        assertThrows(.extractedSymbolicLink("evil")) {
            _ = try SafeArchiveExtractor.extract(
                zipURL: archiveURL(),
                to: destination,
                runner: runner
            )
        }
    }

    func testRejectsListingSubprocessFailure() {
        let runner = MockSubprocessRunner(scripts: [
            .init(
                path: "/usr/bin/zipinfo",
                argsPrefix: ["-l"],
                result: .init(exitCode: 9, terminationReason: .exit, stdout: "", stderr: "boom")
            ),
        ])
        assertThrows(.listingFailed) {
            _ = try SafeArchiveExtractor.extract(
                zipURL: archiveURL(),
                to: URL(fileURLWithPath: "/tmp/unused"),
                runner: runner
            )
        }
    }
    func testDirectoryEntriesWithTrailingSlashAreOptIn() throws {
        XCTAssertNoThrow(
            try SafeArchiveExtractor.validateEntryPaths(
                ["wrapper/", "wrapper/images/", "wrapper/images/a.jpg"],
                allowingDirectoryEntries: true
            )
        )
        // The strict default (toolchain archives) still rejects them.
        XCTAssertThrowsError(try SafeArchiveExtractor.validateEntryPaths(["wrapper/"]))
        // Interior empty components and dot traversal are rejected either way.
        for entry in ["a//b.jpg", "wrapper/../a.jpg", "/"] {
            XCTAssertThrowsError(
                try SafeArchiveExtractor.validateEntryPaths([entry], allowingDirectoryEntries: true)
            )
        }
    }

}
