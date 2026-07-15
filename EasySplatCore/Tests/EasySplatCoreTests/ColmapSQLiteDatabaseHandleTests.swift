#if canImport(XCTest)
import Foundation
import SQLite3
import XCTest
@testable import EasySplatCore

final class ColmapSQLiteDatabaseHandleTests: XCTestCase {
    func testVerificationRejectsDatabaseReplacementAfterOpen() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let databaseURL = root.appendingPathComponent("database.db")
        let originalURL = root.appendingPathComponent("original.db")
        try createDatabase(at: databaseURL)
        let handle = try ColmapSQLiteDatabaseHandle.open(
            at: databaseURL,
            flags: SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX
        )

        try FileManager.default.moveItem(at: databaseURL, to: originalURL)
        try createDatabase(at: databaseURL)

        XCTAssertThrowsError(try handle.verifyUnchanged()) { error in
            XCTAssertEqual(error as? ColmapSQLiteDatabaseHandleError, .unsafeDatabaseFile)
        }
    }

    func testVerificationRejectsHardLinkAddedAfterOpen() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let databaseURL = root.appendingPathComponent("database.db")
        let linkedURL = root.appendingPathComponent("linked.db")
        try createDatabase(at: databaseURL)
        let handle = try ColmapSQLiteDatabaseHandle.open(
            at: databaseURL,
            flags: SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX
        )

        try FileManager.default.linkItem(at: databaseURL, to: linkedURL)

        XCTAssertThrowsError(try handle.verifyUnchanged()) { error in
            XCTAssertEqual(error as? ColmapSQLiteDatabaseHandleError, .unsafeDatabaseFile)
        }
    }

    func testReadOnlySnapshotRejectsInPlaceDatabaseMutation() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let databaseURL = root.appendingPathComponent("database.db")
        try createDatabase(at: databaseURL)
        let handle = try ColmapSQLiteDatabaseHandle.open(
            at: databaseURL,
            flags: SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX
        )

        var writer: OpaquePointer?
        XCTAssertEqual(sqlite3_open(databaseURL.path, &writer), SQLITE_OK)
        let openedWriter = try XCTUnwrap(writer)
        XCTAssertEqual(
            sqlite3_exec(openedWriter, "INSERT INTO marker VALUES (2);", nil, nil, nil),
            SQLITE_OK
        )
        XCTAssertEqual(sqlite3_close(openedWriter), SQLITE_OK)

        XCTAssertThrowsError(try handle.verifyUnchanged()) { error in
            XCTAssertEqual(error as? ColmapSQLiteDatabaseHandleError, .unsafeDatabaseFile)
        }
    }

    func testReadOnlyOpenRejectsSymlinkedWALSidecar() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let databaseURL = root.appendingPathComponent("database.db")
        let externalWAL = root.appendingPathComponent("external-wal")
        try createDatabase(at: databaseURL)
        try Data("not a WAL".utf8).write(to: externalWAL)
        try FileManager.default.createSymbolicLink(
            atPath: databaseURL.path + "-wal",
            withDestinationPath: externalWAL.path
        )

        XCTAssertThrowsError(
            try ColmapSQLiteDatabaseHandle.open(
                at: databaseURL,
                flags: SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX
            )
        ) { error in
            XCTAssertEqual(error as? ColmapSQLiteDatabaseHandleError, .unsafeDatabaseFile)
        }
    }

    func testImmutableSnapshotRejectsWALCreatedAfterOpen() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let databaseURL = root.appendingPathComponent("database.db")
        try createDatabase(at: databaseURL)
        try execute("PRAGMA journal_mode = WAL;", at: databaseURL)
        XCTAssertFalse(FileManager.default.fileExists(atPath: databaseURL.path + "-wal"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: databaseURL.path + "-shm"))

        let handle = try ColmapSQLiteDatabaseHandle.open(
            at: databaseURL,
            flags: SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX
        )

        var writer: OpaquePointer?
        XCTAssertEqual(sqlite3_open(databaseURL.path, &writer), SQLITE_OK)
        let openedWriter = try XCTUnwrap(writer)
        defer { sqlite3_close(openedWriter) }
        XCTAssertEqual(sqlite3_exec(openedWriter, "PRAGMA wal_autocheckpoint = 0;", nil, nil, nil), SQLITE_OK)
        XCTAssertEqual(
            sqlite3_exec(openedWriter, "INSERT INTO marker VALUES (2);", nil, nil, nil),
            SQLITE_OK
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: databaseURL.path + "-wal"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: databaseURL.path + "-shm"))

        XCTAssertThrowsError(try handle.verifyUnchanged()) { error in
            XCTAssertEqual(error as? ColmapSQLiteDatabaseHandleError, .unsafeDatabaseFile)
        }
    }

    private func createDatabase(at url: URL) throws {
        var database: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &database), SQLITE_OK)
        guard let database else {
            throw NSError(domain: "ColmapSQLiteDatabaseHandleTests", code: 1)
        }
        defer { sqlite3_close(database) }
        XCTAssertEqual(
            sqlite3_exec(
                database,
                "CREATE TABLE marker(value INTEGER); INSERT INTO marker VALUES (1);",
                nil,
                nil,
                nil
            ),
            SQLITE_OK
        )
    }

    private func execute(_ sql: String, at url: URL) throws {
        var database: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &database), SQLITE_OK)
        let openedDatabase = try XCTUnwrap(database)
        defer { sqlite3_close(openedDatabase) }
        XCTAssertEqual(sqlite3_exec(openedDatabase, sql, nil, nil, nil), SQLITE_OK)
    }
}
#endif
