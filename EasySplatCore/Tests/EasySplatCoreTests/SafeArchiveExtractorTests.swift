import Darwin
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

    private func expandDeclaredCompressedPayload(in archive: URL, to byteCount: UInt32) throws {
        var bytes = try Data(contentsOf: archive)
        let local = try XCTUnwrap(bytes.firstRange(of: Data([0x50, 0x4B, 0x03, 0x04])))
        let central = try XCTUnwrap(bytes.firstRange(of: Data([0x50, 0x4B, 0x01, 0x02])))
        let original = readUInt32(bytes, at: local.lowerBound + 18)
        XCTAssertGreaterThan(byteCount, original)
        let added = Int(byteCount - original)
        bytes.insert(contentsOf: repeatElement(UInt8.zero, count: added), at: central.lowerBound)

        writeUInt32(byteCount, to: &bytes, at: local.lowerBound + 18)
        let shiftedCentral = central.lowerBound + added
        writeUInt32(byteCount, to: &bytes, at: shiftedCentral + 20)
        let end = try XCTUnwrap(bytes.firstRange(of: Data([0x50, 0x4B, 0x05, 0x06])))
        writeUInt32(UInt32(shiftedCentral), to: &bytes, at: end.lowerBound + 16)
        try bytes.write(to: archive)
    }

    private func readUInt32(_ data: Data, at offset: Int) -> UInt32 {
        (0..<4).reduce(UInt32.zero) { value, byte in
            value | (UInt32(data[offset + byte]) << UInt32(byte * 8))
        }
    }

    private func writeUInt32(_ value: UInt32, to data: inout Data, at offset: Int) {
        for byte in 0..<4 {
            data[offset + byte] = UInt8(truncatingIfNeeded: value >> UInt32(byte * 8))
        }
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

        let destinationURL = destination()
        let inventory = try SafeArchiveExtractor.extract(zipURL: zip, to: destinationURL)

        XCTAssertEqual(inventory.entries, [
            .init(relativePath: "images/0.jpg", byteCount: 12),
            .init(relativePath: "images/1.jpg", byteCount: 8),
            .init(relativePath: "transforms.json", byteCount: 20),
        ])
        XCTAssertEqual(inventory.totalBytes, 40)

        XCTAssertEqual(try permissions(of: destinationURL), 0o700)
        let directoryMode = try XCTUnwrap(
            FileManager.default.attributesOfItem(
                atPath: destinationURL.appendingPathComponent("images").path
            )[.posixPermissions] as? NSNumber
        )
        let fileMode = try XCTUnwrap(
            FileManager.default.attributesOfItem(
                atPath: destinationURL.appendingPathComponent("images/0.jpg").path
            )[.posixPermissions] as? NSNumber
        )
        XCTAssertEqual(directoryMode.intValue & 0o777, 0o700)
        XCTAssertEqual(fileMode.intValue & 0o777, 0o600)
    }

    func testReleaseReliabilityExtractsTenThousandEntryArchiveWithLargePayload() throws {
        let fixture = try ReleaseReliabilityFixtureSupport.load(
            workload: "zip-extraction-10000"
        )
        XCTAssertEqual(fixture.manifest.entryCount, 10_000)
        XCTAssertEqual(fixture.manifest.zip.entryCount, 10_000)
        let zip = fixture.fixtureRoot.appendingPathComponent("archive.zip")
        let destinationURL = fixture.outputRoot.appendingPathComponent(
            "extracted",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: destinationURL) }

        let clock = ContinuousClock()
        let started = clock.now
        let inventory = try SafeArchiveExtractor.extract(zipURL: zip, to: destinationURL)
        let elapsed = started.duration(to: clock.now)

        XCTAssertEqual(inventory.entries.count, 10_000)
        XCTAssertEqual(inventory.totalBytes, fixture.manifest.zip.uncompressedByteCount)
        XCTAssertEqual(inventory.entries.first?.relativePath, "capture/frame-00000.jpg")
        XCTAssertEqual(
            inventory.entries.last?.relativePath,
            fixture.manifest.zip.largeEntryPath
        )
        let largeOutput = destinationURL.appendingPathComponent(
            fixture.manifest.zip.largeEntryPath
        )
        let largeSize = try XCTUnwrap(
            FileManager.default.attributesOfItem(atPath: largeOutput.path)[.size] as? NSNumber
        )
        XCTAssertEqual(largeSize.uint64Value, fixture.manifest.ply.byteCount)
        try fixture.recordSuccess(elapsed: elapsed)
    }

    func testExtractsARealPathWithExactly64Components() throws {
        let directories = (0..<63).map { "d\($0)" }
        let path = (directories + ["frame.jpg"]).joined(separator: "/")
        XCTAssertEqual(path.split(separator: "/").count, 64)
        let zip = try archive("depth-64.zip", [
            .file(path: path, contents: Data("frame".utf8)),
        ])
        let target = destination()

        let inventory = try SafeArchiveExtractor.extract(zipURL: zip, to: target)

        XCTAssertEqual(inventory.entries, [
            .init(relativePath: path, byteCount: 5),
        ])
        XCTAssertEqual(
            try Data(contentsOf: target.appendingPathComponent(path)),
            Data("frame".utf8)
        )
    }

    func testRejectsPathWith65ComponentsBeforeCreatingDestination() throws {
        let path = ((0..<64).map { "d\($0)" } + ["frame.jpg"])
            .joined(separator: "/")
        XCTAssertEqual(path.split(separator: "/").count, 65)
        let zip = try archive("depth-65.zip", [
            .file(path: path, contents: Data("frame".utf8)),
        ])
        let target = destination()

        XCTAssertThrowsError(try SafeArchiveExtractor.extract(zipURL: zip, to: target))
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
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

    func testRejectsCaseInsensitiveCollisionAtDirectoryPrefix() throws {
        let zip = try archive("prefix-collision.zip", [
            .file(path: "Foo/a.txt", contents: Data("a".utf8)),
            .file(path: "foo/b.txt", contents: Data("b".utf8)),
        ])
        let target = destination()

        XCTAssertThrowsError(try SafeArchiveExtractor.extract(zipURL: zip, to: target)) { error in
            guard case SafeArchiveExtractor.ExtractionError.caseInsensitiveCollision = error else {
                return XCTFail("expected a prefix case collision, got \(error)")
            }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
    }

    func testCollisionValidationVisitsEachComponentOnceForNearMaximumName() throws {
        let components = (0..<10_000).map { String(format: "c%04x", $0) }
        let path = components.joined(separator: "/")
        XCTAssertGreaterThan(path.utf8.count, 55_000)
        XCTAssertLessThan(path.utf8.count, 65_535)

        let visits = try SafeArchiveExtractor.collisionValidationComponentCount([
            (path: path, isDirectory: false),
        ])

        XCTAssertEqual(visits, components.count)
    }

    func testRejectsFileDirectoryCollisionBeforeCreatingDestination() throws {
        let zip = try archive("type-collision.zip", [
            .file(path: "images", contents: Data("not a directory".utf8)),
            .file(path: "images/a.txt", contents: Data("a".utf8)),
        ])
        let target = destination()

        XCTAssertThrowsError(try SafeArchiveExtractor.extract(zipURL: zip, to: target))
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
    }

    func testRejectsExistingIntermediateDestinationSymlinkWithoutWritingOutside() throws {
        let zip = try archive("intermediate-link.zip", [
            .file(path: "images/escape.txt", contents: Data("escaped".utf8)),
        ])
        let target = destination()
        let outside = root.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: target.appendingPathComponent("images"),
            withDestinationURL: outside
        )

        XCTAssertThrowsError(try SafeArchiveExtractor.extract(zipURL: zip, to: target))
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: outside.appendingPathComponent("escape.txt").path
            )
        )
    }

    func testRejectsSymlinkInDestinationParentPathWithoutCreatingOutside() throws {
        let zip = try archive("destination-parent-link.zip", [
            .file(path: "inside.txt", contents: Data("inside".utf8)),
        ])
        let outside = root.appendingPathComponent("outside-parent", isDirectory: true)
        let linked = root.appendingPathComponent("linked-parent", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: linked, withDestinationURL: outside)
        let target = linked
            .appendingPathComponent("nested", isDirectory: true)
            .appendingPathComponent("extract", isDirectory: true)

        assertThrows(.extractionRootUnavailable) {
            _ = try SafeArchiveExtractor.extract(zipURL: zip, to: target)
        }
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: outside.appendingPathComponent("nested").path
            )
        )
    }

    func testRejectsRootOwnedFirstComponentSymlinkOutsideTrustedAliases() throws {
        var status = stat()
        XCTAssertEqual(Darwin.lstat("/etc", &status), 0)
        try XCTSkipUnless(
            (status.st_mode & S_IFMT) == S_IFLNK && status.st_uid == 0,
            "this regression exercises the standard macOS root-owned /etc alias"
        )
        let zip = try archive("root-owned-parent-link.zip", [
            .file(path: "inside.txt", contents: Data("inside".utf8)),
        ])
        let target = URL(fileURLWithPath: "/etc")
            .appendingPathComponent("easysplat-\(UUID().uuidString)", isDirectory: true)

        XCTAssertEqual(
            try SafeArchiveExtractor.destinationPathForBinding(target).path,
            target.standardizedFileURL.path,
            "an arbitrary root-owned alias must remain visible to strict no-follow traversal"
        )
        assertThrows(.extractionRootUnavailable) {
            _ = try SafeArchiveExtractor.extract(zipURL: zip, to: target)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
    }

    func testCanonicalSystemTemporaryAliasStillExtractsWithStrictNoFollow() throws {
        try XCTSkipUnless(
            root.path.hasPrefix("/var/"),
            "this regression exercises the standard macOS /var alias"
        )
        let target = root.appendingPathComponent("alias-out", isDirectory: true)
        let zip = try archive("canonical-alias.zip", [
            .file(path: "inside.txt", contents: Data("inside".utf8)),
        ])

        XCTAssertTrue(
            try SafeArchiveExtractor.destinationPathForBinding(target).path
                .hasPrefix("/private/var/"),
            "the fixed system alias must be canonicalized before no-follow traversal"
        )
        let inventory = try SafeArchiveExtractor.extract(zipURL: zip, to: target)

        XCTAssertEqual(inventory.entries.map(\.relativePath), ["inside.txt"])
        XCTAssertTrue(
            try SafeArchiveExtractor.destinationPathForBinding(target).path
                .hasPrefix("/private/var/"),
            "an existing destination must not be re-aliased after canonicalization"
        )
        XCTAssertEqual(
            try Data(contentsOf: target.appendingPathComponent("inside.txt")),
            Data("inside".utf8)
        )
    }

    func testMalformedCentralDirectoryCreatesNoDestination() throws {
        let zip = try archive("malformed-central.zip", [
            .file(path: "a.txt", contents: Data("a".utf8)),
        ])
        var bytes = try Data(contentsOf: zip)
        let central = try XCTUnwrap(
            bytes.firstRange(of: Data([0x50, 0x4B, 0x01, 0x02]))
        )
        bytes[central.lowerBound] = 0
        try bytes.write(to: zip)
        let target = destination()

        assertThrows(.listingFailed) {
            _ = try SafeArchiveExtractor.extract(zipURL: zip, to: target)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
    }

    func testOpenedSnapshotSurvivesAtomicArchivePathReplacement() throws {
        let archivePath = try archive("selected.zip", [
            .file(path: "inside.txt", contents: Data("selected bytes".utf8)),
        ])
        let replacement = try archive("replacement.zip", [
            .file(path: "../outside.txt", contents: Data("replacement bytes".utf8)),
        ])
        let snapshot = try ZipArchiveReader.Snapshot(opening: archivePath)
        XCTAssertEqual(Darwin.rename(replacement.path, archivePath.path), 0)
        let target = destination()

        let inventory = try SafeArchiveExtractor.extract(
            snapshot: snapshot,
            to: target,
            limits: .default,
            shouldCancel: { false }
        )

        XCTAssertEqual(inventory.entries.map(\.relativePath), ["inside.txt"])
        XCTAssertEqual(
            try Data(contentsOf: target.appendingPathComponent("inside.txt")),
            Data("selected bytes".utf8)
        )
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: root.appendingPathComponent("outside.txt").path)
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

    func testRejectsLargeCompressedPayloadBeforeTinyOutputExtraction() throws {
        let zip = try archive("compressed-entry-budget.zip", [
            .file(path: "tiny.txt", contents: Data("x".utf8)),
        ])
        try expandDeclaredCompressedPayload(in: zip, to: 4096)
        let limits = SafeArchiveExtractor.ExtractionLimits(
            maxEntryCount: 64,
            maxEntryUncompressedBytes: 1 << 20,
            maxTotalUncompressedBytes: 1 << 20,
            maxEntryCompressedBytes: 1024,
            maxTotalCompressedBytes: 1 << 20
        )
        let target = destination()

        assertThrows(.compressedEntryTooLarge(path: "tiny.txt", bytes: 4096, limit: 1024)) {
            _ = try SafeArchiveExtractor.extract(zipURL: zip, to: target, limits: limits)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
    }

    func testRejectsCumulativeCompressedPayloadBudget() throws {
        let zip = try archive("compressed-total-budget.zip", (0..<3).map {
            .file(path: "f\($0).bin", contents: Data(count: 512))
        })
        let limits = SafeArchiveExtractor.ExtractionLimits(
            maxEntryCount: 64,
            maxEntryUncompressedBytes: 1 << 20,
            maxTotalUncompressedBytes: 1 << 20,
            maxEntryCompressedBytes: 1024,
            maxTotalCompressedBytes: 1024
        )
        let target = destination()

        assertThrows(.compressedTotalSizeExceeded(bytes: 1536, limit: 1024)) {
            _ = try SafeArchiveExtractor.extract(zipURL: zip, to: target, limits: limits)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
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

    func testChecksumFailureNeverPublishesPartialExtraction() throws {
        let good = Data(repeating: UInt8(ascii: "g"), count: 256)
        let bad = Data(repeating: UInt8(ascii: "b"), count: 256)
        let zip = try archive("bad-crc.zip", [
            .file(path: "a-good.bin", contents: good),
            .file(path: "z-bad.bin", contents: bad),
        ])
        var bytes = try Data(contentsOf: zip)
        let payload = try XCTUnwrap(
            bytes.firstRange(of: Data(repeating: UInt8(ascii: "b"), count: 64))
        )
        bytes[payload.lowerBound] = UInt8(ascii: "x")
        try bytes.write(to: zip)
        let target = destination()

        assertThrows(.extractionFailed) {
            _ = try SafeArchiveExtractor.extract(zipURL: zip, to: target)
        }
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: target.path),
            "a failed extraction must remove files written before the failure"
        )
    }

    func testCancelledTaskCreatesNoDestination() async throws {
        let zip = try archive("cancelled.zip", [
            .file(path: "large.bin", contents: Data(count: 1024 * 1024)),
        ])
        let target = destination()
        let enteredTask = expectation(description: "task entered")
        let releaseTask = AsyncTestGate()
        let task = Task {
            enteredTask.fulfill()
            await releaseTask.wait()
            return try SafeArchiveExtractor.extract(zipURL: zip, to: target)
        }
        await fulfillment(of: [enteredTask], timeout: 2)
        task.cancel()
        await releaseTask.release()

        do {
            _ = try await task.value
            XCTFail("expected cancellation")
        } catch is CancellationError {
            // Expected.
        } catch {
            XCTFail("expected CancellationError, got \(error)")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
    }

    func testCancellationAfterOutputCreationNeverPublishesDestination() throws {
        let zip = try archive("cancel-during-write.zip", [
            .file(path: "large.bin", contents: Data(count: 1024 * 1024)),
        ])
        let snapshot = try ZipArchiveReader.Snapshot(opening: zip)
        let target = destination()
        let probe = PrivateExtractionPresenceProbe(
            parent: root,
            relativePath: "large.bin"
        )

        XCTAssertThrowsError(
            try SafeArchiveExtractor.extract(
                snapshot: snapshot,
                to: target,
                limits: .default,
                shouldCancel: probe.shouldCancel
            )
        ) { error in
            XCTAssertTrue(error is CancellationError, "unexpected error: \(error)")
        }
        XCTAssertTrue(probe.didObserveOutput)
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
    }

    func testFailurePreservesForeignDirectorySwappedOverCreatedPath() throws {
        let zip = try archive("cleanup-swap.zip", [
            .file(path: "owned/keep.txt", contents: Data("owned".utf8)),
            .file(path: "z-trigger.txt", contents: Data("trigger".utf8)),
        ])
        let snapshot = try ZipArchiveReader.Snapshot(opening: zip)
        let target = destination()
        let probe = CleanupSwapProbe(root: target)

        XCTAssertThrowsError(
            try SafeArchiveExtractor.extract(
                snapshot: snapshot,
                to: target,
                limits: .default,
                shouldCancel: probe.shouldCancel
            )
        ) { error in
            XCTAssertTrue(error is CancellationError, "unexpected error: \(error)")
        }
        XCTAssertTrue(probe.didSwap)
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
        let privateRoot = try XCTUnwrap(privateExtractionRoots().first)
        XCTAssertEqual(
            try Data(contentsOf: privateRoot.appendingPathComponent("owned/keep.txt")),
            Data("foreign".utf8),
            "cleanup must preserve a foreign directory that replaced one it created"
        )
    }

    func testDestinationRootPublicationPreservesCompetingDirectory() throws {
        let zip = try archive("root-publication-race.zip", [
            .file(path: "inside.txt", contents: Data("archive".utf8)),
        ])
        let snapshot = try ZipArchiveReader.Snapshot(opening: zip)
        let target = destination()
        let probe = DirectoryPublicationProbe(
            targetName: target.lastPathComponent,
            phase: .beforePublish,
            swapPublishedDirectory: false
        )

        XCTAssertThrowsError(
            try SafeArchiveExtractor.extract(
                snapshot: snapshot,
                to: target,
                limits: .default,
                shouldCancel: { false },
                directoryPublicationObserver: probe.observe
            )
        )

        XCTAssertTrue(probe.didAct)
        XCTAssertEqual(
            try Data(contentsOf: target.appendingPathComponent("foreign.txt")),
            Data("foreign".utf8)
        )
        XCTAssertEqual(try permissions(of: target), 0o755)
        XCTAssertFalse(
            try FileManager.default.contentsOfDirectory(atPath: root.path)
                .contains(where: { $0.hasPrefix(".easysplat-create-") })
        )
    }

    func testDestinationRootFailureNeverMovesAReplacementAtItsPrivateName() throws {
        let zip = try archive("private-root-replacement.zip", [
            .file(path: "inside.txt", contents: Data("archive".utf8)),
        ])
        let snapshot = try ZipArchiveReader.Snapshot(opening: zip)
        let target = destination()
        let probe = PrivateRootReplacementProbe(targetName: target.lastPathComponent)

        XCTAssertThrowsError(
            try SafeArchiveExtractor.extract(
                snapshot: snapshot,
                to: target,
                limits: .default,
                shouldCancel: { false },
                directoryPublicationObserver: probe.observe
            )
        )

        XCTAssertTrue(probe.didAct)
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
        let privateRoot = try XCTUnwrap(privateExtractionRoots().first)
        XCTAssertEqual(
            try Data(contentsOf: privateRoot.appendingPathComponent("foreign.txt")),
            Data("foreign".utf8)
        )
    }

    func testDestinationRootRejectsPermissionMutationBeforePublication() throws {
        let zip = try archive("private-root-mode.zip", [
            .file(path: "inside.txt", contents: Data("archive".utf8)),
        ])
        let snapshot = try ZipArchiveReader.Snapshot(opening: zip)
        let target = destination()
        let probe = PrivateRootPermissionProbe(targetName: target.lastPathComponent)

        XCTAssertThrowsError(
            try SafeArchiveExtractor.extract(
                snapshot: snapshot,
                to: target,
                limits: .default,
                shouldCancel: { false },
                directoryPublicationObserver: probe.observe
            )
        )
        XCTAssertTrue(probe.didAct)
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
    }

    func testMissingDestinationParentPublicationPreservesCompetingDirectory() throws {
        let zip = try archive("parent-publication-race.zip", [
            .file(path: "inside.txt", contents: Data("archive".utf8)),
        ])
        let snapshot = try ZipArchiveReader.Snapshot(opening: zip)
        let missingParent = root.appendingPathComponent("missing-parent", isDirectory: true)
        let target = missingParent.appendingPathComponent("out", isDirectory: true)
        let probe = DirectoryPublicationProbe(
            targetName: missingParent.lastPathComponent,
            phase: .beforePublish,
            swapPublishedDirectory: false
        )

        XCTAssertThrowsError(
            try SafeArchiveExtractor.extract(
                snapshot: snapshot,
                to: target,
                limits: .default,
                shouldCancel: { false },
                directoryPublicationObserver: probe.observe
            )
        )

        XCTAssertTrue(probe.didAct)
        XCTAssertEqual(
            try Data(contentsOf: missingParent.appendingPathComponent("foreign.txt")),
            Data("foreign".utf8)
        )
        XCTAssertEqual(try permissions(of: missingParent), 0o755)
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
    }

    func testIntermediateDirectorySwapAfterPublicationIsNeverModifiedOrRemoved() throws {
        let zip = try archive("intermediate-publication-race.zip", [
            .file(path: "nested/inside.txt", contents: Data("archive".utf8)),
        ])
        let snapshot = try ZipArchiveReader.Snapshot(opening: zip)
        let target = destination()
        let probe = DirectoryPublicationProbe(
            targetName: "nested",
            phase: .afterPublish,
            swapPublishedDirectory: true
        )

        XCTAssertThrowsError(
            try SafeArchiveExtractor.extract(
                snapshot: snapshot,
                to: target,
                limits: .default,
                shouldCancel: { false },
                directoryPublicationObserver: probe.observe
            )
        )

        XCTAssertTrue(probe.didAct)
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
        let privateRoot = try XCTUnwrap(privateExtractionRoots().first)
        let foreign = privateRoot.appendingPathComponent("nested/foreign.txt")
        XCTAssertEqual(try Data(contentsOf: foreign), Data("foreign".utf8))
        XCTAssertEqual(try permissions(of: foreign.deletingLastPathComponent()), 0o755)
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: target.appendingPathComponent("nested/inside.txt").path
            )
        )
    }

    func testPostExtractionVerificationStaysOnBoundRootDuringRenameDecoyRace() throws {
        let original = Data("ORIGINAL".utf8)
        let zip = try archive("bound-inventory-race.zip", [
            .file(path: "inside.txt", contents: original),
        ])
        let snapshot = try ZipArchiveReader.Snapshot(opening: zip)
        let target = destination()
        let probe = BoundInventorySwapProbe(
            root: target,
            original: original,
            mutation: Data("MUTATED!".utf8)
        )
        defer { probe.restoreIfNeeded() }

        XCTAssertThrowsError(
            try SafeArchiveExtractor.extract(
                snapshot: snapshot,
                to: target,
                limits: .default,
                shouldCancel: { false },
                verificationObserver: probe.observe
            )
        )
        probe.restoreIfNeeded()

        XCTAssertTrue(probe.didSwap)
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
        XCTAssertFalse(
            probe.didReachAfterInventory,
            "descriptor-bound verification must reject mutated A before a decoy can restore the path"
        )
        XCTAssertTrue(
            probe.decoyWasPreserved,
            "failure cleanup must not remove the foreign decoy bound to the destination name"
        )
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

    private func permissions(of url: URL) throws -> Int {
        var status = stat()
        guard Darwin.lstat(url.path, &status) == 0 else {
            throw CocoaError(.fileReadNoSuchFile)
        }
        return Int(status.st_mode & 0o777)
    }

    private func privateExtractionRoots() throws -> [URL] {
        try FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: nil
        ).filter { $0.lastPathComponent.hasPrefix(".easysplat-extract-") }
    }
}

private actor AsyncTestGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var released = false

    func wait() async {
        if released { return }
        await withCheckedContinuation { continuation = $0 }
    }

    func release() {
        released = true
        continuation?.resume()
        continuation = nil
    }
}

private final class CleanupSwapProbe: @unchecked Sendable {
    private let lock = NSLock()
    private let target: URL
    private(set) var didSwap = false

    init(root: URL) {
        target = root
    }

    func shouldCancel() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !didSwap else { return true }

        guard let privateRoot = try? FileManager.default.contentsOfDirectory(
            at: target.deletingLastPathComponent(),
            includingPropertiesForKeys: nil
        ).first(where: { $0.lastPathComponent.hasPrefix(".easysplat-extract-") }) else {
            return false
        }
        let owned = privateRoot.appendingPathComponent("owned", isDirectory: true)
        let leaf = owned.appendingPathComponent("keep.txt")
        guard FileManager.default.fileExists(atPath: leaf.path) else { return false }

        let displaced = privateRoot.appendingPathComponent("displaced", isDirectory: true)
        guard Darwin.rename(owned.path, displaced.path) == 0 else { return true }
        do {
            try FileManager.default.createDirectory(at: owned, withIntermediateDirectories: false)
            try Data("foreign".utf8).write(to: leaf)
            didSwap = true
        } catch {
            return true
        }
        return true
    }
}

private final class BoundInventorySwapProbe: @unchecked Sendable {
    private let lock = NSLock()
    private let target: URL
    private let displaced: URL
    private let original: Data
    private let mutation: Data
    private(set) var didSwap = false
    private(set) var didReachAfterInventory = false
    private(set) var decoyWasPreserved = false
    private var privateRoot: URL?

    init(root: URL, original: Data, mutation: Data) {
        target = root
        displaced = root.deletingLastPathComponent()
            .appendingPathComponent("displaced-\(UUID().uuidString)", isDirectory: true)
        self.original = original
        self.mutation = mutation
    }

    func observe(_ event: SafeArchiveExtractor.VerificationEvent) {
        lock.lock()
        defer { lock.unlock() }
        switch event {
        case .beforeInventory:
            guard !didSwap else { return }
            guard let privateRoot = try? FileManager.default.contentsOfDirectory(
                at: target.deletingLastPathComponent(),
                includingPropertiesForKeys: nil
            ).first(where: { $0.lastPathComponent.hasPrefix(".easysplat-extract-") }) else {
                return
            }
            self.privateRoot = privateRoot
            guard Darwin.rename(privateRoot.path, displaced.path) == 0 else { return }
            do {
                try FileManager.default.createDirectory(
                    at: privateRoot,
                    withIntermediateDirectories: false
                )
                try original.write(to: privateRoot.appendingPathComponent("inside.txt"))
                try mutation.write(to: displaced.appendingPathComponent("inside.txt"))
                didSwap = true
            } catch {
                return
            }
        case .afterInventory:
            didReachAfterInventory = true
            restoreLocked()
        }
    }

    func restoreIfNeeded() {
        lock.lock()
        defer { lock.unlock() }
        restoreLocked()
    }

    private func restoreLocked() {
        guard didSwap,
              let privateRoot,
              FileManager.default.fileExists(atPath: privateRoot.path),
              FileManager.default.fileExists(atPath: displaced.path) else { return }
        decoyWasPreserved = (
            try? Data(contentsOf: privateRoot.appendingPathComponent("inside.txt"))
        )
            == original
        try? FileManager.default.removeItem(at: privateRoot)
        _ = Darwin.rename(displaced.path, privateRoot.path)
    }
}

private final class PrivateExtractionPresenceProbe: @unchecked Sendable {
    private let lock = NSLock()
    private let parent: URL
    private let relativePath: String
    private(set) var didObserveOutput = false

    init(parent: URL, relativePath: String) {
        self.parent = parent
        self.relativePath = relativePath
    }

    func shouldCancel() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !didObserveOutput else { return true }
        let roots = try? FileManager.default.contentsOfDirectory(
            at: parent,
            includingPropertiesForKeys: nil
        )
        didObserveOutput = roots?.contains(where: {
            $0.lastPathComponent.hasPrefix(".easysplat-extract-")
                && FileManager.default.fileExists(
                    atPath: $0.appendingPathComponent(relativePath).path
                )
        }) == true
        return didObserveOutput
    }
}

private final class PrivateRootReplacementProbe: @unchecked Sendable {
    private let lock = NSLock()
    private let targetName: String
    private(set) var didAct = false

    init(targetName: String) {
        self.targetName = targetName
    }

    func observe(_ event: SafeArchiveExtractor.DirectoryPublicationEvent) {
        lock.lock()
        defer { lock.unlock() }
        guard !didAct,
              case .beforePublish = event.phase,
              event.intendedName == targetName else { return }
        let displaced = ".easysplat-displaced-\(UUID().uuidString)"
        let renamed = event.privateName.withCString { source in
            displaced.withCString { destination in
                Darwin.renameatx_np(
                    event.parentDescriptor,
                    source,
                    event.parentDescriptor,
                    destination,
                    UInt32(RENAME_EXCL | RENAME_NOFOLLOW_ANY)
                )
            }
        }
        guard renamed == 0 else { return }
        guard event.privateName.withCString({
            Darwin.mkdirat(event.parentDescriptor, $0, mode_t(S_IRWXU))
        }) == 0 else { return }
        let directory = event.privateName.withCString {
            Darwin.openat(
                event.parentDescriptor,
                $0,
                O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
            )
        }
        guard directory >= 0 else { return }
        defer { Darwin.close(directory) }
        let file = Darwin.openat(
            directory,
            "foreign.txt",
            O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
            mode_t(S_IRUSR | S_IWUSR)
        )
        guard file >= 0 else { return }
        defer { Darwin.close(file) }
        let bytes = Array("foreign".utf8)
        didAct = bytes.withUnsafeBytes {
            Darwin.write(file, $0.baseAddress, $0.count)
        } == bytes.count
    }
}

private final class PrivateRootPermissionProbe: @unchecked Sendable {
    private let lock = NSLock()
    private let targetName: String
    private(set) var didAct = false

    init(targetName: String) {
        self.targetName = targetName
    }

    func observe(_ event: SafeArchiveExtractor.DirectoryPublicationEvent) {
        lock.lock()
        defer { lock.unlock() }
        guard !didAct,
              case .beforePublish = event.phase,
              event.intendedName == targetName else { return }
        let descriptor = event.privateName.withCString {
            Darwin.openat(
                event.parentDescriptor,
                $0,
                O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
            )
        }
        guard descriptor >= 0 else { return }
        defer { Darwin.close(descriptor) }
        didAct = Darwin.fchmod(descriptor, mode_t(0o755)) == 0
    }
}

private final class DirectoryPublicationProbe: @unchecked Sendable {
    private let lock = NSLock()
    private let targetName: String
    private let phase: SafeArchiveExtractor.DirectoryPublicationPhase
    private let swapPublishedDirectory: Bool
    private(set) var didAct = false

    init(
        targetName: String,
        phase: SafeArchiveExtractor.DirectoryPublicationPhase,
        swapPublishedDirectory: Bool
    ) {
        self.targetName = targetName
        self.phase = phase
        self.swapPublishedDirectory = swapPublishedDirectory
    }

    func observe(_ event: SafeArchiveExtractor.DirectoryPublicationEvent) {
        lock.lock()
        defer { lock.unlock() }
        guard !didAct,
              event.intendedName == targetName,
              matches(event.phase) else { return }

        if swapPublishedDirectory {
            let displaced = ".easysplat-displaced-\(UUID().uuidString)"
            let renamed = event.intendedName.withCString { source in
                displaced.withCString { destination in
                    Darwin.renameatx_np(
                        event.parentDescriptor,
                        source,
                        event.parentDescriptor,
                        destination,
                        UInt32(RENAME_EXCL | RENAME_NOFOLLOW_ANY)
                    )
                }
            }
            guard renamed == 0 else { return }
        }

        let made = event.intendedName.withCString {
            Darwin.mkdirat(event.parentDescriptor, $0, mode_t(0o755))
        }
        guard made == 0 else { return }
        let directory = event.intendedName.withCString {
            Darwin.openat(
                event.parentDescriptor,
                $0,
                O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
            )
        }
        guard directory >= 0 else { return }
        defer { Darwin.close(directory) }
        guard Darwin.fchmod(directory, mode_t(0o755)) == 0 else { return }
        let file = Darwin.openat(
            directory,
            "foreign.txt",
            O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
            mode_t(S_IRUSR | S_IWUSR)
        )
        guard file >= 0 else { return }
        defer { Darwin.close(file) }
        let payload = Array("foreign".utf8)
        let written = payload.withUnsafeBytes {
            Darwin.write(file, $0.baseAddress, $0.count)
        }
        didAct = written == payload.count
    }

    private func matches(
        _ candidate: SafeArchiveExtractor.DirectoryPublicationPhase
    ) -> Bool {
        switch (phase, candidate) {
        case (.beforePublish, .beforePublish), (.afterPublish, .afterPublish):
            return true
        default:
            return false
        }
    }
}
