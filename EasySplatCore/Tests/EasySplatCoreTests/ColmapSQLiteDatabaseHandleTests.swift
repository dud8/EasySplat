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
}
#endif
