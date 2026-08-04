import XCTest
@testable import EasySplatCore

/// Exercised against archives real tools produced, so the parser is checked
/// against the format rather than against a matching encoder of its own.
final class ZipArchiveReaderTests: XCTestCase {
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

    @discardableResult
    private func runZip(_ arguments: [String], in directory: URL) throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        process.arguments = arguments
        process.currentDirectoryURL = directory
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus
    }

    private func makePayload(_ files: [String: Data]) throws -> URL {
        let payload = root.appendingPathComponent("payload", isDirectory: true)
        for (name, data) in files {
            let target = payload.appendingPathComponent(name)
            try FileManager.default.createDirectory(
                at: target.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: target)
        }
        return payload
    }

    func testReadsEntriesAndExtractsDeflatedAndStoredContent() throws {
        // Highly repetitive content deflates; random content stores.
        let deflatable = Data(String(repeating: "easysplat ", count: 4096).utf8)
        let incompressible = Data((0..<4096).map { _ in UInt8.random(in: 0...255) })
        let payload = try makePayload([
            "frames/a.txt": deflatable,
            "frames/b.bin": incompressible,
        ])
        let archive = root.appendingPathComponent("dataset.zip")
        XCTAssertEqual(try runZip(["-q", "-r", archive.path, "."], in: payload), 0)

        let entries = try ZipArchiveReader.readEntries(at: archive)
        let files = entries.filter { !$0.isDirectory }
        XCTAssertEqual(
            Set(files.map(\.path)).intersection(["frames/a.txt", "frames/b.bin"]).count,
            2
        )

        let destination = root.appendingPathComponent("out", isDirectory: true)
        try FileManager.default.createDirectory(
            at: destination.appendingPathComponent("frames", isDirectory: true),
            withIntermediateDirectories: true
        )
        let descriptor = open(destination.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        XCTAssertGreaterThanOrEqual(descriptor, 0)
        defer { close(descriptor) }

        for entry in files where entry.path.hasPrefix("frames/") {
            try ZipArchiveReader.extract(
                entry: entry,
                from: archive,
                into: descriptor,
                relativePath: entry.path
            )
        }

        XCTAssertEqual(
            try Data(contentsOf: destination.appendingPathComponent("frames/a.txt")),
            deflatable
        )
        XCTAssertEqual(
            try Data(contentsOf: destination.appendingPathComponent("frames/b.bin")),
            incompressible
        )
    }

    func testReportsSymbolicLinkEntriesRatherThanMaterialisingThem() throws {
        let payload = root.appendingPathComponent("linked", isDirectory: true)
        try FileManager.default.createDirectory(at: payload, withIntermediateDirectories: true)
        try Data("real".utf8).write(to: payload.appendingPathComponent("real.txt"))
        try FileManager.default.createSymbolicLink(
            at: payload.appendingPathComponent("link.txt"),
            withDestinationURL: URL(fileURLWithPath: "/etc/passwd")
        )
        let archive = root.appendingPathComponent("linked.zip")
        // -y preserves the symlink as a symlink entry.
        XCTAssertEqual(try runZip(["-q", "-r", "-y", archive.path, "."], in: payload), 0)

        let entries = try ZipArchiveReader.readEntries(at: archive)
        let link = try XCTUnwrap(entries.first { $0.path.hasSuffix("link.txt") })
        XCTAssertTrue(link.isSymbolicLink, "a symlink entry must be recognisable before extraction")
        let regular = try XCTUnwrap(entries.first { $0.path.hasSuffix("real.txt") })
        XCTAssertFalse(regular.isSymbolicLink)
    }

    func testRejectsAnEncryptedEntry() throws {
        let payload = try makePayload(["secret.txt": Data("secret".utf8)])
        let archive = root.appendingPathComponent("encrypted.zip")
        XCTAssertEqual(
            try runZip(["-q", "-r", "-P", "hunter2", archive.path, "."], in: payload),
            0
        )

        XCTAssertThrowsError(try ZipArchiveReader.readEntries(at: archive)) { error in
            guard case ZipArchiveReader.ReaderError.encrypted = error else {
                return XCTFail("expected an encrypted-entry rejection, got \(error)")
            }
        }
    }

    func testRejectsContentThatDoesNotMatchItsChecksum() throws {
        let payload = try makePayload(["a.txt": Data(String(repeating: "x", count: 512).utf8)])
        let archive = root.appendingPathComponent("corrupt.zip")
        XCTAssertEqual(try runZip(["-q", "-r", "-0", archive.path, "."], in: payload), 0)

        // Stored entries put the payload verbatim in the file, so flipping a byte
        // inside it leaves every header intact and only the CRC disagrees.
        var bytes = try Data(contentsOf: archive)
        let target = try XCTUnwrap(bytes.firstRange(of: Data(String(repeating: "x", count: 32).utf8)))
        bytes[target.lowerBound] = UInt8(ascii: "y")
        try bytes.write(to: archive)

        let entry = try XCTUnwrap(
            try ZipArchiveReader.readEntries(at: archive).first { $0.path.hasSuffix("a.txt") }
        )
        let destination = root.appendingPathComponent("corrupt-out", isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let descriptor = open(destination.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        defer { close(descriptor) }

        XCTAssertThrowsError(
            try ZipArchiveReader.extract(
                entry: entry,
                from: archive,
                into: descriptor,
                relativePath: "a.txt"
            )
        ) { error in
            guard case ZipArchiveReader.ReaderError.checksumMismatch = error else {
                return XCTFail("expected a checksum rejection, got \(error)")
            }
        }
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: destination.appendingPathComponent("a.txt").path),
            "a rejected entry must not be left on disk"
        )
    }

    func testRefusesToFollowAnExistingSymlinkWhenWriting() throws {
        let payload = try makePayload(["a.txt": Data("payload".utf8)])
        let archive = root.appendingPathComponent("plain.zip")
        XCTAssertEqual(try runZip(["-q", "-r", archive.path, "."], in: payload), 0)

        let destination = root.appendingPathComponent("guarded", isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let victim = root.appendingPathComponent("victim.txt")
        try Data("original".utf8).write(to: victim)
        try FileManager.default.createSymbolicLink(
            at: destination.appendingPathComponent("a.txt"),
            withDestinationURL: victim
        )

        let entry = try XCTUnwrap(
            try ZipArchiveReader.readEntries(at: archive).first { $0.path.hasSuffix("a.txt") }
        )
        let descriptor = open(destination.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        defer { close(descriptor) }

        XCTAssertThrowsError(
            try ZipArchiveReader.extract(
                entry: entry,
                from: archive,
                into: descriptor,
                relativePath: "a.txt"
            )
        )
        XCTAssertEqual(try Data(contentsOf: victim), Data("original".utf8))
    }
}
