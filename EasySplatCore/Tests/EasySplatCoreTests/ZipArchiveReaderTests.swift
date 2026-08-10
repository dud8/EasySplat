import Darwin
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

        let snapshot = try ZipArchiveReader.Snapshot(opening: archive)
        let files = snapshot.entries.filter { !$0.isDirectory }
        XCTAssertEqual(
            Set(files.map(\.path)).intersection(["frames/a.txt", "frames/b.bin"]).count,
            2
        )

        let destination = root.appendingPathComponent("out", isDirectory: true)
        try FileManager.default.createDirectory(
            at: destination.appendingPathComponent("frames", isDirectory: true),
            withIntermediateDirectories: true
        )
        let descriptor = open(
            destination.appendingPathComponent("frames").path,
            O_RDONLY | O_DIRECTORY | O_CLOEXEC
        )
        XCTAssertGreaterThanOrEqual(descriptor, 0)
        defer { close(descriptor) }

        for entry in files where entry.path.hasPrefix("frames/") {
            _ = try snapshot.extract(
                entry: entry,
                into: descriptor,
                leafName: URL(fileURLWithPath: entry.path).lastPathComponent,
                maximumOutputBytes: 1 << 20,
                shouldCancel: { false }
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

        let snapshot = try ZipArchiveReader.Snapshot(opening: archive)
        let link = try XCTUnwrap(snapshot.entries.first { $0.path.hasSuffix("link.txt") })
        XCTAssertTrue(link.isSymbolicLink, "a symlink entry must be recognisable before extraction")
        let regular = try XCTUnwrap(snapshot.entries.first { $0.path.hasSuffix("real.txt") })
        XCTAssertFalse(regular.isSymbolicLink)
    }

    func testRejectsAnEncryptedEntry() throws {
        let payload = try makePayload(["secret.txt": Data("secret".utf8)])
        let archive = root.appendingPathComponent("encrypted.zip")
        XCTAssertEqual(
            try runZip(["-q", "-r", "-P", "hunter2", archive.path, "."], in: payload),
            0
        )

        XCTAssertThrowsError(try ZipArchiveReader.Snapshot(opening: archive)) { error in
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

        let snapshot = try ZipArchiveReader.Snapshot(opening: archive)
        let entry = try XCTUnwrap(snapshot.entries.first { $0.path.hasSuffix("a.txt") })
        let destination = root.appendingPathComponent("corrupt-out", isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let descriptor = open(destination.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        defer { close(descriptor) }

        XCTAssertThrowsError(
            try snapshot.extract(
                entry: entry,
                into: descriptor,
                leafName: "a.txt",
                maximumOutputBytes: 1 << 20,
                shouldCancel: { false }
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

        let snapshot = try ZipArchiveReader.Snapshot(opening: archive)
        let entry = try XCTUnwrap(snapshot.entries.first { $0.path.hasSuffix("a.txt") })
        let descriptor = open(destination.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        defer { close(descriptor) }

        XCTAssertThrowsError(
            try snapshot.extract(
                entry: entry,
                into: descriptor,
                leafName: "a.txt",
                maximumOutputBytes: 1 << 20,
                shouldCancel: { false }
            )
        )
        XCTAssertEqual(try Data(contentsOf: victim), Data("original".utf8))
    }

    func testSnapshotRefusesArchiveSymlink() throws {
        let archive = try ZipFixtureBuilder.build(
            at: root.appendingPathComponent("real.zip"),
            entries: [.file(path: "a.txt", contents: Data("a".utf8))]
        )
        let link = root.appendingPathComponent("link.zip")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: archive)

        XCTAssertThrowsError(try ZipArchiveReader.Snapshot(opening: link)) { error in
            XCTAssertEqual(error as? ZipArchiveReader.ReaderError, .unreadable)
        }
    }

    func testSnapshotRefusesFIFOWithoutBlocking() throws {
        let fifo = root.appendingPathComponent("selected.zip")
        XCTAssertEqual(Darwin.mkfifo(fifo.path, mode_t(S_IRUSR | S_IWUSR)), 0)
        let finished = expectation(description: "FIFO snapshot returned")
        let result = AsyncErrorBox()

        DispatchQueue.global(qos: .userInitiated).async {
            do {
                _ = try ZipArchiveReader.Snapshot(opening: fifo)
                result.store(nil)
            } catch {
                result.store(error)
            }
            finished.fulfill()
        }

        let waitResult = XCTWaiter.wait(for: [finished], timeout: 0.5)
        if waitResult != .completed {
            // Rescue a regressed blocking reader so the test process remains
            // bounded and can report the failure.
            let writer = Darwin.open(fifo.path, O_WRONLY | O_NONBLOCK | O_CLOEXEC)
            if writer >= 0 { Darwin.close(writer) }
        }
        XCTAssertEqual(waitResult, .completed)
        XCTAssertEqual(result.value as? ZipArchiveReader.ReaderError, .unreadable)
    }

    func testSnapshotCancellationBeforeLocalHeaderValidationCreatesNoTemporaryName() throws {
        let archive = try ZipFixtureBuilder.build(
            at: root.appendingPathComponent("copy-cancel.zip"),
            entries: [.file(path: "large.bin", contents: Data(count: 3 * 1024 * 1024))]
        )
        let before = try archiveSnapshotTemporaryNames()
        let probe = CancellationProbe(cancelOnCall: 3)

        XCTAssertThrowsError(
            try ZipArchiveReader.Snapshot(
                opening: archive,
                shouldCancel: probe.shouldCancel
            )
        ) { error in
            XCTAssertTrue(error is CancellationError, "unexpected error: \(error)")
        }
        XCTAssertEqual(probe.callCount, 3)
        XCTAssertEqual(try archiveSnapshotTemporaryNames(), before)
    }

    func testSnapshotCancellationDuringCentralDirectoryParsingLeavesNoTemporaryName() throws {
        let archive = try ZipFixtureBuilder.build(
            at: root.appendingPathComponent("parse-cancel.zip"),
            entries: [
                .file(path: "a.txt", contents: Data("a".utf8)),
                .file(path: "b.txt", contents: Data("b".utf8)),
            ]
        )
        let before = try archiveSnapshotTemporaryNames()
        // The second central-directory entry follows the pre-open check and
        // the first entry.
        let probe = CancellationProbe(cancelOnCall: 3)

        XCTAssertThrowsError(
            try ZipArchiveReader.Snapshot(
                opening: archive,
                shouldCancel: probe.shouldCancel
            )
        ) { error in
            XCTAssertTrue(error is CancellationError, "unexpected error: \(error)")
        }
        XCTAssertEqual(probe.callCount, 3)
        XCTAssertEqual(try archiveSnapshotTemporaryNames(), before)
    }

    func testBoundedEntryNamesReadsHeadersWithoutPayloadSizedCopying() throws {
        let archive = try ZipFixtureBuilder.build(
            at: root.appendingPathComponent("sniff-only.zip"),
            entries: [.file(path: "dataset/transforms.json", contents: Data(count: 5 * 1024 * 1024))]
        )
        let probe = CancellationProbe(cancelOnCall: .max)

        let names = try ZipArchiveReader.boundedEntryNames(
            inArchiveAt: archive,
            shouldCancel: probe.shouldCancel
        )

        XCTAssertEqual(names, ["dataset/transforms.json"])
        XCTAssertEqual(
            probe.callCount,
            4,
            "listing work must be proportional to headers and entries, not payload bytes"
        )
    }

    func testBoundedEntryNamesRejectsMutationBeforeFinalIdentityCheck() throws {
        let archive = try ZipFixtureBuilder.build(
            at: root.appendingPathComponent("sniff-mutation.zip"),
            entries: [.file(path: "a.txt", contents: Data("payload".utf8))]
        )
        let mutator = Darwin.open(archive.path, O_RDWR | O_CLOEXEC)
        XCTAssertGreaterThanOrEqual(mutator, 0)
        defer { Darwin.close(mutator) }

        XCTAssertThrowsError(
            try ZipArchiveReader.boundedEntryNames(
                inArchiveAt: archive,
                beforeFinalIdentityCheck: { _ in
                    var byte = UInt8(ascii: "x")
                    XCTAssertEqual(Darwin.pwrite(mutator, &byte, 1, 0), 1)
                    XCTAssertEqual(Darwin.fsync(mutator), 0)
                }
            )
        ) { error in
            XCTAssertEqual(error as? ZipArchiveReader.ReaderError, .archiveChanged)
        }
    }

    func testBoundedEntryNamesEnforcesEntryLimit() throws {
        let archive = try ZipFixtureBuilder.build(
            at: root.appendingPathComponent("sniff-limit.zip"),
            entries: [
                .file(path: "a.txt", contents: Data()),
                .file(path: "b.txt", contents: Data()),
            ]
        )

        XCTAssertThrowsError(
            try ZipArchiveReader.boundedEntryNames(
                inArchiveAt: archive,
                maximumEntryCount: 1
            )
        ) { error in
            XCTAssertEqual(
                error as? ZipArchiveReader.ReaderError,
                .entryCountExceeded(1)
            )
        }
    }

    func testBoundedEntryNamesEnforcesListingByteLimit() throws {
        let archive = try ZipFixtureBuilder.build(
            at: root.appendingPathComponent("sniff-byte-limit.zip"),
            entries: [.file(path: "a-name-that-does-not-fit.txt", contents: Data())]
        )

        XCTAssertThrowsError(
            try ZipArchiveReader.boundedEntryNames(
                inArchiveAt: archive,
                maximumListingBytes: 32
            )
        ) { error in
            XCTAssertEqual(error as? ZipArchiveReader.ReaderError, .listingTooLarge)
        }
    }

    func testBoundedEntryNamesAccepts64ComponentsAndRejects65BeforeRetention() throws {
        let acceptedPath = ((0..<63).map { "d\($0)" } + ["frame.jpg"])
            .joined(separator: "/")
        let rejectedPath = ((0..<64).map { "d\($0)" } + ["frame.jpg"])
            .joined(separator: "/")
        let accepted = try ZipFixtureBuilder.build(
            at: root.appendingPathComponent("sniff-depth-64.zip"),
            entries: [.file(path: acceptedPath, contents: Data())]
        )
        let rejected = try ZipFixtureBuilder.build(
            at: root.appendingPathComponent("sniff-depth-65.zip"),
            entries: [.file(path: rejectedPath, contents: Data())]
        )

        XCTAssertEqual(
            try ZipArchiveReader.boundedEntryNames(inArchiveAt: accepted),
            [acceptedPath]
        )
        XCTAssertThrowsError(
            try ZipArchiveReader.boundedEntryNames(inArchiveAt: rejected)
        ) { error in
            guard case ZipArchiveReader.ReaderError.malformed = error else {
                return XCTFail("expected malformed, got \(error)")
            }
        }
    }

    func testSnapshotRejectsInPlaceMutationOfItsOpenedSource() throws {
        let archive = try ZipFixtureBuilder.build(
            at: root.appendingPathComponent("mutable.zip"),
            entries: [.file(path: "a.txt", contents: Data("AAAAAAA".utf8))]
        )
        let replacement = try ZipFixtureBuilder.build(
            at: root.appendingPathComponent("replacement.zip"),
            entries: [.file(path: "a.txt", contents: Data("BBBBBBB".utf8))]
        )
        let replacementBytes = try Data(contentsOf: replacement)
        let sourceDescriptor = Darwin.open(archive.path, O_RDWR | O_CLOEXEC)
        XCTAssertGreaterThanOrEqual(sourceDescriptor, 0)
        defer { Darwin.close(sourceDescriptor) }

        let snapshot = try ZipArchiveReader.Snapshot(opening: archive)
        let entry = try XCTUnwrap(snapshot.entries.first)
        XCTAssertEqual(Darwin.rename(replacement.path, archive.path), 0)
        let written = replacementBytes.withUnsafeBytes { bytes in
            Darwin.pwrite(sourceDescriptor, bytes.baseAddress, bytes.count, 0)
        }
        XCTAssertEqual(written, replacementBytes.count)
        XCTAssertEqual(Darwin.fsync(sourceDescriptor), 0)

        let destination = root.appendingPathComponent("mutation-out", isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let destinationDescriptor = Darwin.open(
            destination.path,
            O_RDONLY | O_DIRECTORY | O_CLOEXEC
        )
        XCTAssertGreaterThanOrEqual(destinationDescriptor, 0)
        defer { Darwin.close(destinationDescriptor) }

        XCTAssertThrowsError(
            try snapshot.extract(
                entry: entry,
                into: destinationDescriptor,
                leafName: "a.txt",
                maximumOutputBytes: 1 << 20,
                shouldCancel: { false }
            )
        ) { error in
            XCTAssertEqual(error as? ZipArchiveReader.ReaderError, .archiveChanged)
        }
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: destination.appendingPathComponent("a.txt").path
            )
        )
    }

    func testSnapshotRejectsOneRemovedLinkWhileSourceRemainsPathnameReachable() throws {
        let archive = try ZipFixtureBuilder.build(
            at: root.appendingPathComponent("linked-source.zip"),
            entries: [.file(path: "a.txt", contents: Data("payload".utf8))]
        )
        let secondLink = root.appendingPathComponent("linked-source-copy.zip")
        XCTAssertEqual(Darwin.link(archive.path, secondLink.path), 0)
        let snapshot = try ZipArchiveReader.Snapshot(opening: archive)
        let entry = try XCTUnwrap(snapshot.entries.first)
        XCTAssertEqual(Darwin.unlink(secondLink.path), 0)

        let destination = root.appendingPathComponent("linked-source-out", isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let destinationDescriptor = Darwin.open(
            destination.path,
            O_RDONLY | O_DIRECTORY | O_CLOEXEC
        )
        XCTAssertGreaterThanOrEqual(destinationDescriptor, 0)
        defer { Darwin.close(destinationDescriptor) }

        XCTAssertThrowsError(
            try snapshot.extract(
                entry: entry,
                into: destinationDescriptor,
                leafName: "a.txt",
                maximumOutputBytes: 1 << 20,
                shouldCancel: { false }
            )
        ) { error in
            XCTAssertEqual(error as? ZipArchiveReader.ReaderError, .archiveChanged)
        }
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: destination.appendingPathComponent("a.txt").path
            )
        )
    }

    func testSnapshotRejectsEntryOwnedByAnotherSnapshot() throws {
        let archive = try ZipFixtureBuilder.build(
            at: root.appendingPathComponent("snapshot-bound.zip"),
            entries: [.file(path: "a.txt", contents: Data("payload".utf8))]
        )
        let first = try ZipArchiveReader.Snapshot(opening: archive)
        let second = try ZipArchiveReader.Snapshot(opening: archive)
        let foreignEntry = try XCTUnwrap(second.entries.first)
        let destination = root.appendingPathComponent("snapshot-bound-out", isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let descriptor = Darwin.open(destination.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        XCTAssertGreaterThanOrEqual(descriptor, 0)
        defer { Darwin.close(descriptor) }

        XCTAssertThrowsError(
            try first.extract(
                entry: foreignEntry,
                into: descriptor,
                leafName: "a.txt",
                maximumOutputBytes: 1 << 20,
                shouldCancel: { false }
            )
        )
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: destination.appendingPathComponent("a.txt").path)
        )
    }

    func testFailedPrivatePublicationNeverMovesOrAltersExistingDestination() throws {
        let archive = try ZipFixtureBuilder.build(
            at: root.appendingPathComponent("existing-destination.zip"),
            entries: [.file(path: "victim.txt", contents: Data("archive".utf8))]
        )
        let snapshot = try ZipArchiveReader.Snapshot(opening: archive)
        let directory = root.appendingPathComponent("existing-destination", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let victim = directory.appendingPathComponent("victim.txt")
        try Data("foreign".utf8).write(to: victim)
        let descriptor = Darwin.open(
            directory.path,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        XCTAssertGreaterThanOrEqual(descriptor, 0)
        defer { Darwin.close(descriptor) }
        XCTAssertThrowsError(
            try snapshot.extract(
                entry: XCTUnwrap(snapshot.entries.first),
                into: descriptor,
                leafName: "victim.txt",
                maximumOutputBytes: 1 << 20,
                shouldCancel: { false }
            )
        )
        XCTAssertEqual(try Data(contentsOf: victim), Data("foreign".utf8))
    }

    func testCancellationNeverTruncatesAHardlinkToPrivateOutput() throws {
        let payload = Data(repeating: UInt8(ascii: "p"), count: 1024 * 1024)
        let archive = try ZipFixtureBuilder.build(
            at: root.appendingPathComponent("hardlink-cancel.zip"),
            entries: [.file(path: "victim.bin", contents: payload)]
        )
        let snapshot = try ZipArchiveReader.Snapshot(opening: archive)
        let directory = root.appendingPathComponent("hardlink-cancel", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let descriptor = Darwin.open(
            directory.path,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        XCTAssertGreaterThanOrEqual(descriptor, 0)
        defer { Darwin.close(descriptor) }
        let outside = root.appendingPathComponent("outside-hardlink.bin")
        let probe = PrivateOutputHardlinkProbe(outside: outside)

        XCTAssertThrowsError(
            try snapshot.extract(
                entry: XCTUnwrap(snapshot.entries.first),
                into: descriptor,
                leafName: "victim.bin",
                maximumOutputBytes: 2 << 20,
                shouldCancel: probe.shouldCancel,
                privateOutputCreated: probe.record
            )
        ) { error in
            XCTAssertTrue(error is CancellationError, "unexpected error: \(error)")
        }
        XCTAssertTrue(probe.didLink)
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: directory.appendingPathComponent("victim.bin").path
            )
        )
        XCTAssertGreaterThan(try Data(contentsOf: outside).count, 0)
    }

    func testRejectsMaskedHeaderEncryptionFlag() throws {
        let archive = try ZipFixtureBuilder.build(
            at: root.appendingPathComponent("masked.zip"),
            entries: [.file(path: "a.txt", contents: Data("payload".utf8))]
        )
        var bytes = try Data(contentsOf: archive)
        let local = try XCTUnwrap(bytes.firstRange(of: Data([0x50, 0x4B, 0x03, 0x04])))
        let central = try XCTUnwrap(bytes.firstRange(of: Data([0x50, 0x4B, 0x01, 0x02])))
        bytes[local.lowerBound + 7] |= 0x20
        bytes[central.lowerBound + 9] |= 0x20
        try bytes.write(to: archive)

        XCTAssertThrowsError(try ZipArchiveReader.Snapshot(opening: archive)) { error in
            guard case ZipArchiveReader.ReaderError.encrypted = error else {
                return XCTFail("expected encrypted, got \(error)")
            }
        }
    }

    func testRejectsLocalAndCentralDataDescriptorFlagMismatch() throws {
        let archive = try ZipFixtureBuilder.build(
            at: root.appendingPathComponent("flag-mismatch.zip"),
            entries: [.file(path: "a.txt", contents: Data("payload".utf8))]
        )
        var bytes = try Data(contentsOf: archive)
        let local = try XCTUnwrap(bytes.firstRange(of: Data([0x50, 0x4B, 0x03, 0x04])))
        bytes[local.lowerBound + 6] |= 0x08
        try bytes.write(to: archive)

        XCTAssertThrowsError(try ZipArchiveReader.Snapshot(opening: archive)) { error in
            guard case ZipArchiveReader.ReaderError.malformed = error else {
                return XCTFail("expected malformed, got \(error)")
            }
        }
    }

    func testRejectsEveryGeneralPurposeFlagDisagreement() throws {
        let base = try ZipFixtureBuilder.build(
            at: root.appendingPathComponent("flag-disagreement-base.zip"),
            entries: [.file(path: "a.txt", contents: Data("payload".utf8))]
        )
        let original = try Data(contentsOf: base)
        let cases: [(String, UInt16)] = [
            ("traditional encryption", 0x0001),
            ("deflate option one", 0x0002),
            ("deflate option two", 0x0004),
            ("data descriptor", 0x0008),
            ("enhanced deflate", 0x0010),
            ("patched data", 0x0020),
            ("strong encryption", 0x0040),
            ("reserved 7", 0x0080),
            ("reserved 8", 0x0100),
            ("reserved 9", 0x0200),
            ("reserved 10", 0x0400),
            ("UTF-8", 0x0800),
            ("reserved 12", 0x1000),
            ("masked header", 0x2000),
            ("reserved 14", 0x4000),
            ("reserved 15", 0x8000),
        ]

        for (name, bit) in cases {
            var bytes = original
            let local = try XCTUnwrap(bytes.firstRange(of: Data([0x50, 0x4B, 0x03, 0x04])))
            writeUInt16(bit, to: &bytes, at: local.lowerBound + 6)
            let archive = root.appendingPathComponent("mismatch-\(bit).zip")
            try bytes.write(to: archive)

            XCTAssertThrowsError(
                try ZipArchiveReader.Snapshot(opening: archive),
                "local/central \(name) disagreement must be rejected"
            )
        }
    }

    func testRejectsEveryUnsupportedGeneralPurposeFlagWhenHeadersAgree() throws {
        let base = try ZipFixtureBuilder.build(
            at: root.appendingPathComponent("unsupported-flags-base.zip"),
            entries: [.file(path: "a.txt", contents: Data("payload".utf8))]
        )
        let original = try Data(contentsOf: base)
        let unsupported: [(String, UInt16)] = [
            ("traditional encryption", 0x0001),
            ("enhanced deflate", 0x0010),
            ("patched data", 0x0020),
            ("strong encryption", 0x0040),
            ("reserved 7", 0x0080),
            ("reserved 8", 0x0100),
            ("reserved 9", 0x0200),
            ("reserved 10", 0x0400),
            ("reserved 12", 0x1000),
            ("masked header", 0x2000),
            ("reserved 14", 0x4000),
            ("reserved 15", 0x8000),
        ]

        for (name, bit) in unsupported {
            var bytes = original
            let local = try XCTUnwrap(bytes.firstRange(of: Data([0x50, 0x4B, 0x03, 0x04])))
            let central = try XCTUnwrap(bytes.firstRange(of: Data([0x50, 0x4B, 0x01, 0x02])))
            writeUInt16(bit, to: &bytes, at: local.lowerBound + 6)
            writeUInt16(bit, to: &bytes, at: central.lowerBound + 8)
            let archive = root.appendingPathComponent("unsupported-\(bit).zip")
            try bytes.write(to: archive)

            XCTAssertThrowsError(
                try ZipArchiveReader.Snapshot(opening: archive),
                "agreed \(name) flag must still be rejected"
            )
        }
    }

    func testAcceptsSupportedGeneralPurposeFlagsWhenHeadersAgree() throws {
        let payload = try makePayload([
            "a.txt": Data(String(repeating: "compress me ", count: 1024).utf8),
        ])
        let archive = root.appendingPathComponent("supported-flags.zip")
        XCTAssertEqual(try runZip(["-q", "-r", archive.path, "."], in: payload), 0)
        var bytes = try Data(contentsOf: archive)
        let local = try XCTUnwrap(bytes.firstRange(of: Data([0x50, 0x4B, 0x03, 0x04])))
        let central = try XCTUnwrap(bytes.firstRange(of: Data([0x50, 0x4B, 0x01, 0x02])))
        let supported: UInt16 = 0x0006 | 0x0800
        writeUInt16(supported, to: &bytes, at: local.lowerBound + 6)
        writeUInt16(supported, to: &bytes, at: central.lowerBound + 8)
        try bytes.write(to: archive)

        let snapshot = try ZipArchiveReader.Snapshot(opening: archive)
        XCTAssertEqual(snapshot.entries.first?.generalPurposeFlags, supported)
    }

    func testAcceptsSignedAndUnsignedStandardDataDescriptors() throws {
        let payload = Data("descriptor payload".utf8)
        for signed in [true, false] {
            let archive = try makeDataDescriptorArchive(
                name: "standard-\(signed).zip",
                payload: payload,
                signed: signed,
                zip64: false
            )
            let snapshot = try ZipArchiveReader.Snapshot(opening: archive)
            XCTAssertEqual(snapshot.entries.map(\.path), ["payload.bin"])
            try assertExtracts(snapshot: snapshot, expected: payload)
        }
    }

    func testAcceptsSignedAndUnsignedZip64DataDescriptors() throws {
        let payload = Data("zip64 descriptor payload".utf8)
        for signed in [true, false] {
            let archive = try makeDataDescriptorArchive(
                name: "zip64-\(signed).zip",
                payload: payload,
                signed: signed,
                zip64: true
            )
            let snapshot = try ZipArchiveReader.Snapshot(opening: archive)
            XCTAssertEqual(snapshot.entries.map(\.path), ["payload.bin"])
            try assertExtracts(snapshot: snapshot, expected: payload)
        }
    }

    func testRejectsMissingTruncatedAndMismatchedDataDescriptors() throws {
        for zip64 in [false, true] {
            for damage in DataDescriptorDamage.allCases {
                let archive = try makeDataDescriptorArchive(
                    name: "damaged-\(zip64)-\(damage).zip",
                    payload: Data("payload".utf8),
                    signed: true,
                    zip64: zip64,
                    damage: damage
                )
                XCTAssertThrowsError(
                    try ZipArchiveReader.Snapshot(opening: archive),
                    "\(damage) \(zip64 ? "ZIP64" : "standard") descriptor must fail"
                ) { error in
                    guard case ZipArchiveReader.ReaderError.malformed = error else {
                        return XCTFail("expected malformed, got \(error)")
                    }
                }
            }
        }
    }

    private func archiveSnapshotTemporaryNames() throws -> Set<String> {
        Set(try FileManager.default.contentsOfDirectory(
            atPath: FileManager.default.temporaryDirectory.path
        ).filter { $0.hasPrefix(".easysplat-archive-snapshot.") })
    }

    private enum DataDescriptorDamage: String, CaseIterable {
        case missing
        case truncated
        case wrongCRC
        case wrongCompressedSize
        case wrongUncompressedSize
    }

    private func makeDataDescriptorArchive(
        name archiveName: String,
        payload: Data,
        signed: Bool,
        zip64: Bool,
        damage: DataDescriptorDamage? = nil
    ) throws -> URL {
        let entryName = Data("payload.bin".utf8)
        let crc = ZipArchiveReader.crc32(payload)
        var zip64Extra = Data()
        if zip64 {
            append(UInt16(0x0001), to: &zip64Extra)
            append(UInt16(16), to: &zip64Extra)
            append(UInt64(payload.count), to: &zip64Extra)
            append(UInt64(payload.count), to: &zip64Extra)
        }

        var archive = Data()
        append(UInt32(0x0403_4B50), to: &archive)
        append(UInt16(zip64 ? 45 : 20), to: &archive)
        append(UInt16(0x0008), to: &archive)
        append(UInt16(0), to: &archive)
        append(UInt16(0), to: &archive)
        append(UInt16(0), to: &archive)
        append(UInt32(0), to: &archive)
        append(UInt32(0), to: &archive)
        append(UInt32(0), to: &archive)
        append(UInt16(entryName.count), to: &archive)
        append(UInt16(zip64Extra.count), to: &archive)
        archive.append(entryName)
        archive.append(zip64Extra)
        archive.append(payload)

        var descriptor = Data()
        if signed {
            append(UInt32(0x0807_4B50), to: &descriptor)
        }
        append(
            damage == .wrongCRC ? crc ^ 0xFFFF_FFFF : crc,
            to: &descriptor
        )
        if zip64 {
            append(
                UInt64(payload.count + (damage == .wrongCompressedSize ? 1 : 0)),
                to: &descriptor
            )
            append(
                UInt64(payload.count + (damage == .wrongUncompressedSize ? 1 : 0)),
                to: &descriptor
            )
        } else {
            append(
                UInt32(payload.count + (damage == .wrongCompressedSize ? 1 : 0)),
                to: &descriptor
            )
            append(
                UInt32(payload.count + (damage == .wrongUncompressedSize ? 1 : 0)),
                to: &descriptor
            )
        }
        switch damage {
        case .missing:
            descriptor.removeAll()
        case .truncated:
            descriptor.removeLast()
        case .none, .wrongCRC, .wrongCompressedSize, .wrongUncompressedSize:
            break
        }
        archive.append(descriptor)

        let centralOffset = archive.count
        var central = Data()
        append(UInt32(0x0201_4B50), to: &central)
        append(UInt16(0x031E), to: &central)
        append(UInt16(zip64 ? 45 : 20), to: &central)
        append(UInt16(0x0008), to: &central)
        append(UInt16(0), to: &central)
        append(UInt16(0), to: &central)
        append(UInt16(0), to: &central)
        append(crc, to: &central)
        append(zip64 ? UInt32.max : UInt32(payload.count), to: &central)
        append(zip64 ? UInt32.max : UInt32(payload.count), to: &central)
        append(UInt16(entryName.count), to: &central)
        append(UInt16(zip64Extra.count), to: &central)
        append(UInt16(0), to: &central)
        append(UInt16(0), to: &central)
        append(UInt16(0), to: &central)
        append(UInt32(S_IFREG | 0o600) << 16, to: &central)
        append(UInt32(0), to: &central)
        central.append(entryName)
        central.append(zip64Extra)
        archive.append(central)

        append(UInt32(0x0605_4B50), to: &archive)
        append(UInt16(0), to: &archive)
        append(UInt16(0), to: &archive)
        append(UInt16(1), to: &archive)
        append(UInt16(1), to: &archive)
        append(UInt32(central.count), to: &archive)
        append(UInt32(centralOffset), to: &archive)
        append(UInt16(0), to: &archive)

        let url = root.appendingPathComponent(archiveName)
        try archive.write(to: url)
        return url
    }

    private func assertExtracts(
        snapshot: ZipArchiveReader.Snapshot,
        expected: Data
    ) throws {
        let destination = root.appendingPathComponent(
            "descriptor-out-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let descriptor = Darwin.open(
            destination.path,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        XCTAssertGreaterThanOrEqual(descriptor, 0)
        defer { Darwin.close(descriptor) }
        _ = try snapshot.extract(
            entry: XCTUnwrap(snapshot.entries.first),
            into: descriptor,
            leafName: "payload.bin",
            maximumOutputBytes: 1 << 20,
            shouldCancel: { false }
        )
        XCTAssertEqual(
            try Data(contentsOf: destination.appendingPathComponent("payload.bin")),
            expected
        )
    }
}

private final class CancellationProbe: @unchecked Sendable {
    private let lock = NSLock()
    private let cancelOnCall: Int
    private var calls = 0

    init(cancelOnCall: Int) {
        self.cancelOnCall = cancelOnCall
    }

    var callCount: Int {
        lock.withLock { calls }
    }

    func shouldCancel() -> Bool {
        lock.withLock {
            calls += 1
            return calls >= cancelOnCall
        }
    }
}

private final class PrivateOutputHardlinkProbe: @unchecked Sendable {
    private let lock = NSLock()
    private let outside: URL
    private var directoryDescriptor: Int32?
    private var privateLeaf: String?
    private var linked = false

    init(outside: URL) {
        self.outside = outside
    }

    var didLink: Bool {
        lock.withLock { linked }
    }

    func record(_ directoryDescriptor: Int32, _ privateLeaf: String) {
        lock.withLock {
            self.directoryDescriptor = directoryDescriptor
            self.privateLeaf = privateLeaf
        }
    }

    func shouldCancel() -> Bool {
        lock.withLock {
            guard !linked,
                  let directoryDescriptor,
                  let privateLeaf else {
                return linked
            }
            var status = stat()
            guard privateLeaf.withCString({
                Darwin.fstatat(
                    directoryDescriptor,
                    $0,
                    &status,
                    AT_SYMLINK_NOFOLLOW
                )
            }) == 0,
                  status.st_size > 0 else {
                return false
            }
            let result = privateLeaf.withCString { source in
                outside.path.withCString { destination in
                    Darwin.linkat(
                        directoryDescriptor,
                        source,
                        AT_FDCWD,
                        destination,
                        0
                    )
                }
            }
            linked = result == 0
            return true
        }
    }
}

private final class AsyncErrorBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Error?

    var value: Error? {
        lock.withLock { stored }
    }

    func store(_ value: Error?) {
        lock.withLock { stored = value }
    }
}

extension ZipArchiveReaderTests {
    /// A declared size or offset above `Int.max` must be rejected, not converted.
    /// Narrowing it first traps, and a trap cannot be caught by the `try?` these
    /// calls sit behind.
    func testRejectsDeclaredValuesTooLargeToAddress() throws {
        let archive = try ZipFixtureBuilder.build(
            at: root.appendingPathComponent("huge.zip"),
            entries: [.file(path: "a.txt", contents: Data("payload".utf8))]
        )
        var bytes = try Data(contentsOf: archive)

        // Central directory: compressed and uncompressed size both sit at a fixed
        // offset from the header signature.
        let signature: [UInt8] = [0x50, 0x4B, 0x01, 0x02]
        let header = try XCTUnwrap(bytes.firstRange(of: Data(signature)))
        for field in [20, 24] {
            let start = header.lowerBound + field
            for offset in 0..<4 {
                bytes[start + offset] = 0xFF
            }
        }
        try bytes.write(to: archive)

        // Reading must fail cleanly; the process must still be here to observe it.
        XCTAssertThrowsError(try ZipArchiveReader.Snapshot(opening: archive))
    }

    func testRejectsOverflowingZip64EndRecordSizeWithoutTrapping() throws {
        var bytes = Data()
        append(UInt32(0x0606_4B50), to: &bytes)
        append(UInt64.max, to: &bytes)
        bytes.append(Data(count: 44))

        append(UInt32(0x0706_4B50), to: &bytes)
        append(UInt32.zero, to: &bytes)
        append(UInt64.zero, to: &bytes)
        append(UInt32(1), to: &bytes)

        append(UInt32(0x0605_4B50), to: &bytes)
        append(UInt16.zero, to: &bytes)
        append(UInt16.zero, to: &bytes)
        append(UInt16.max, to: &bytes)
        append(UInt16.max, to: &bytes)
        append(UInt32.max, to: &bytes)
        append(UInt32.max, to: &bytes)
        append(UInt16.zero, to: &bytes)

        let archive = root.appendingPathComponent("overflowing-zip64.zip")
        try bytes.write(to: archive)

        XCTAssertThrowsError(try ZipArchiveReader.Snapshot(opening: archive)) { error in
            guard case ZipArchiveReader.ReaderError.malformed = error else {
                return XCTFail("expected malformed, got \(error)")
            }
        }
    }

    private func append<T: FixedWidthInteger>(_ value: T, to data: inout Data) {
        for byte in 0..<MemoryLayout<T>.size {
            data.append(UInt8(truncatingIfNeeded: value >> (byte * 8)))
        }
    }

    private func writeUInt16(_ value: UInt16, to data: inout Data, at offset: Int) {
        data[offset] = UInt8(truncatingIfNeeded: value)
        data[offset + 1] = UInt8(truncatingIfNeeded: value >> 8)
    }
}
