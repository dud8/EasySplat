import Darwin
import Foundation
import XCTest
@testable import EasySplatCore

final class PhotoStagingCleanupTests: XCTestCase {
    private let staleDate = Date(timeIntervalSince1970: 1_700_000_000)
    private let cleanupDate = Date(timeIntervalSince1970: 1_700_000_000 + 25 * 60 * 60)

    func testCleanupRemovesOnlyStaleRunsWithExactPhotoStagingGrammar() throws {
        let fixture = try makeContainer()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let stale = try makeRun(in: fixture.container, uuid: "AAAAAAAA-BBBB-4CCC-8DDD-EEEEEEEEEEEE")
        try makePrivateFile(named: "photo-0000.jpg", in: stale)
        try makePrivateFile(named: "photo-9999.png", in: stale)
        try makePrivateFile(named: "photo-0042.heic", in: stale)
        try makePrivateFile(named: "photo-0100.heif", in: stale)
        try makePrivateFile(
            named: ".raw-analysis-11111111-2222-4333-8444-555555555555",
            in: stale
        )
        try makePrivateFile(
            named: ".raw-development-66666666-7777-4888-8999-aaaaaaaaaaaa",
            in: stale
        )
        try markStale(stale)

        let recent = try makeRun(in: fixture.container, uuid: "BBBBBBBB-CCCC-4DDD-8EEE-FFFFFFFFFFFF")
        try makePrivateFile(named: "photo-0000.jpg", in: recent)

        try PhotoStagingCleanup.cleanupStaleRuns(in: fixture.container, now: cleanupDate)

        XCTAssertFalse(FileManager.default.fileExists(atPath: stale.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: recent.path))
    }

    func testCleanupRemovesAtMostFourRunsPerInvocationAndIsIdempotent() throws {
        let fixture = try makeContainer()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let uuids = [
            "00000000-0000-4000-8000-000000000001",
            "00000000-0000-4000-8000-000000000002",
            "00000000-0000-4000-8000-000000000003",
            "00000000-0000-4000-8000-000000000004",
            "00000000-0000-4000-8000-000000000005",
        ]
        for uuid in uuids {
            let run = try makeRun(in: fixture.container, uuid: uuid)
            try makePrivateFile(named: "photo-0000.jpg", in: run)
            try markStale(run)
        }

        try PhotoStagingCleanup.cleanupStaleRuns(in: fixture.container, now: cleanupDate)
        XCTAssertEqual(try controlledRunLeaves(in: fixture.container).count, 1)

        try PhotoStagingCleanup.cleanupStaleRuns(in: fixture.container, now: cleanupDate)
        XCTAssertEqual(try controlledRunLeaves(in: fixture.container), [])

        try PhotoStagingCleanup.cleanupStaleRuns(in: fixture.container, now: cleanupDate)
        XCTAssertEqual(try controlledRunLeaves(in: fixture.container), [])
    }

    func testCleanupPreservesNoncanonicalNamesUnknownLeavesAndUnsafeObjects() throws {
        let fixture = try makeContainer()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let cases: [(String, (URL) throws -> Void)] = [
            ("run-aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee", { run in
                try self.makePrivateFile(named: "photo-0000.jpg", in: run)
            }),
            ("run-AAAAAAAA-BBBB-4CCC-8DDD-EEEEEEEEEEEZ", { run in
                try self.makePrivateFile(named: "photo-0000.jpg", in: run)
            }),
            ("run-99999999-AAAA-4BBB-8CCC-DDDDDDDDDDDD", { run in
                try self.makePrivateFile(named: "photo-0000.jpeg", in: run)
            }),
            ("run-BBBBBBBB-CCCC-4DDD-8EEE-FFFFFFFFFFFF", { run in
                try self.makePrivateFile(
                    named: "photo-\u{FF11}\u{FF12}\u{FF13}\u{FF14}.png",
                    in: run
                )
            }),
            ("run-CCCCCCCC-DDDD-4EEE-8FFF-AAAAAAAAAAAA", { run in
                try self.makePrivateFile(
                    named: ".raw-analysis-11111111-2222-4333-8444-AAAAAAAAAAAA",
                    in: run
                )
            }),
            ("run-DDDDDDDD-EEEE-4FFF-8AAA-BBBBBBBBBBBB", { run in
                let outside = fixture.root.appendingPathComponent("outside-symlink-target")
                try Data("outside".utf8).write(to: outside)
                try FileManager.default.createSymbolicLink(
                    at: run.appendingPathComponent("photo-0000.jpg"),
                    withDestinationURL: outside
                )
            }),
            ("run-EEEEEEEE-FFFF-4AAA-8BBB-CCCCCCCCCCCC", { run in
                let outside = fixture.root.appendingPathComponent("outside-hardlink-target")
                try Data("outside".utf8).write(to: outside)
                XCTAssertEqual(chmod(outside.path, 0o600), 0)
                XCTAssertEqual(link(outside.path, run.appendingPathComponent("photo-0000.jpg").path), 0)
            }),
            ("run-FFFFFFFF-AAAA-4BBB-8CCC-DDDDDDDDDDDD", { run in
                XCTAssertEqual(
                    mkfifo(run.appendingPathComponent("photo-0000.jpg").path, 0o600),
                    0
                )
            }),
            ("run-11111111-2222-4333-8444-555555555555", { run in
                try self.makePrivateFile(named: "photo-0000.jpg", in: run)
                XCTAssertEqual(chmod(run.appendingPathComponent("photo-0000.jpg").path, 0o644), 0)
            }),
        ]

        var protected: [URL] = []
        for (leaf, populate) in cases {
            let run = fixture.container.appendingPathComponent(leaf, isDirectory: true)
            try FileManager.default.createDirectory(
                at: run,
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700]
            )
            try populate(run)
            try markStale(run)
            protected.append(run)
        }
        let looseRoot = try makeRun(
            in: fixture.container,
            uuid: "22222222-3333-4444-8555-666666666666"
        )
        try makePrivateFile(named: "photo-0000.jpg", in: looseRoot)
        XCTAssertEqual(chmod(looseRoot.path, 0o755), 0)
        try markStale(looseRoot)
        protected.append(looseRoot)

        try PhotoStagingCleanup.cleanupStaleRuns(in: fixture.container, now: cleanupDate)

        for run in protected {
            XCTAssertTrue(FileManager.default.fileExists(atPath: run.path), run.lastPathComponent)
        }
    }

    func testCleanupPreservesARecentlyModifiedCompanionInsideAnOldRun() throws {
        let fixture = try makeContainer()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let run = try makeRun(in: fixture.container, uuid: "33333333-4444-4555-8666-777777777777")
        let photo = try makePrivateFile(named: "photo-0000.jpg", in: run)
        try markStale(run)
        try FileManager.default.setAttributes(
            [.modificationDate: cleanupDate.addingTimeInterval(-60)],
            ofItemAtPath: photo.path
        )

        try PhotoStagingCleanup.cleanupStaleRuns(in: fixture.container, now: cleanupDate)

        XCTAssertTrue(FileManager.default.fileExists(atPath: run.path))
    }

    func testCleanupRejectsAnUnsafeContainerWithoutTouchingItsRun() throws {
        let fixture = try makeContainer()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let run = try makeRun(in: fixture.container, uuid: "55555555-6666-4777-8888-999999999999")
        try makePrivateFile(named: "photo-0000.jpg", in: run)
        try markStale(run)
        XCTAssertEqual(chmod(fixture.container.path, 0o755), 0)

        XCTAssertThrowsError(
            try PhotoStagingCleanup.cleanupStaleRuns(in: fixture.container, now: cleanupDate)
        )

        XCTAssertTrue(FileManager.default.fileExists(atPath: run.path))
    }

    func testCleanupDoesNotDeleteARunReplacement() throws {
        let fixture = try makeContainer()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let candidate = try makeRun(
            in: fixture.container,
            uuid: "44444444-5555-4666-8777-888888888888"
        )
        try makePrivateFile(named: "photo-0000.jpg", in: candidate, contents: "genuine")
        try markStale(candidate)
        let replacement = fixture.container.appendingPathComponent("replacement", isDirectory: true)
        try FileManager.default.createDirectory(
            at: replacement,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        try makePrivateFile(named: "photo-0000.jpg", in: replacement, contents: "replacement")
        try markStale(replacement)
        let held = fixture.container.appendingPathComponent("held", isDirectory: true)
        var didReplace = false

        try PhotoStagingCleanup.cleanupStaleRuns(
            in: fixture.container,
            now: cleanupDate,
            beforeQuarantine: { run in
                guard !didReplace, run.lastPathComponent == candidate.lastPathComponent else { return }
                didReplace = true
                try FileManager.default.moveItem(at: run, to: held)
                try FileManager.default.moveItem(at: replacement, to: run)
            }
        )

        XCTAssertTrue(didReplace)
        XCTAssertEqual(
            try Data(contentsOf: candidate.appendingPathComponent("photo-0000.jpg")),
            Data("replacement".utf8)
        )
        XCTAssertEqual(
            try Data(contentsOf: held.appendingPathComponent("photo-0000.jpg")),
            Data("genuine".utf8)
        )
    }

    private func makeContainer() throws -> (root: URL, container: URL) {
        let root = try TestFileBuilder.makeTempDir()
        let container = root.appendingPathComponent(".easysplat-photo-input-staging", isDirectory: true)
        try FileManager.default.createDirectory(
            at: container,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        return (root, container)
    }

    private func makeRun(in container: URL, uuid: String) throws -> URL {
        let run = container.appendingPathComponent("run-\(uuid)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: run,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        return run
    }

    @discardableResult
    private func makePrivateFile(
        named leaf: String,
        in run: URL,
        contents: String = "stale"
    ) throws -> URL {
        let url = run.appendingPathComponent(leaf)
        try Data(contents.utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        try FileManager.default.setAttributes([.modificationDate: staleDate], ofItemAtPath: url.path)
        return url
    }

    private func markStale(_ run: URL) throws {
        try FileManager.default.setAttributes([.modificationDate: staleDate], ofItemAtPath: run.path)
    }

    private func controlledRunLeaves(in container: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: container.path)
            .filter { $0.hasPrefix("run-") }
            .sorted()
    }
}
