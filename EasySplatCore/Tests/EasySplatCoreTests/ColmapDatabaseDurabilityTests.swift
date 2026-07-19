#if canImport(XCTest)
import Foundation
import SQLite3
import XCTest
@testable import EasySplatCore

final class ColmapDatabaseDurabilityTests: XCTestCase {
    func testSealCheckpointsPersistentWALAndPreservesCommittedRows() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let databaseURL = root.appendingPathComponent("database.db")

        var database: OpaquePointer?
        XCTAssertEqual(sqlite3_open(databaseURL.path, &database), SQLITE_OK)
        let openedDatabase = try XCTUnwrap(database)
        XCTAssertEqual(
            sqlite3_exec(
                openedDatabase,
                "PRAGMA journal_mode = WAL; PRAGMA wal_autocheckpoint = 0;"
                    + " CREATE TABLE marker(value INTEGER);"
                    + " INSERT INTO marker VALUES (1), (2), (3);",
                nil,
                nil,
                nil
            ),
            SQLITE_OK
        )
        var persistWAL: Int32 = 1
        XCTAssertEqual(
            sqlite3_file_control(
                openedDatabase,
                "main",
                SQLITE_FCNTL_PERSIST_WAL,
                &persistWAL
            ),
            SQLITE_OK
        )
        XCTAssertEqual(
            sqlite3_exec(openedDatabase, "PRAGMA wal_checkpoint(TRUNCATE);", nil, nil, nil),
            SQLITE_OK
        )
        XCTAssertEqual(sqlite3_close(openedDatabase), SQLITE_OK)

        XCTAssertTrue(FileManager.default.fileExists(atPath: databaseURL.path + "-wal"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: databaseURL.path + "-shm"))
        XCTAssertEqual(try fileSize(atPath: databaseURL.path + "-wal"), 0)
        XCTAssertEqual(try fileSize(atPath: databaseURL.path + "-shm"), 32_768)

        try ColmapDatabaseDurability.seal(at: databaseURL)

        XCTAssertFalse(FileManager.default.fileExists(atPath: databaseURL.path + "-wal"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: databaseURL.path + "-shm"))
        XCTAssertEqual(try markerCount(at: databaseURL), 3)
        let header = try Data(contentsOf: databaseURL, options: .mappedIfSafe)
        XCTAssertGreaterThanOrEqual(header.count, 20)
        XCTAssertEqual(header[18], 1)
        XCTAssertEqual(header[19], 1)

        try ColmapDatabaseDurability.seal(at: databaseURL)
        XCTAssertEqual(try markerCount(at: databaseURL), 3)
    }

    func testSealPreservesCOLMAPLogicalDigests() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let databaseURL = root.appendingPathComponent("database.db")
        var database: OpaquePointer?
        XCTAssertEqual(sqlite3_open(databaseURL.path, &database), SQLITE_OK)
        let openedDatabase = try XCTUnwrap(database)
        XCTAssertEqual(
            sqlite3_exec(
                openedDatabase,
                "PRAGMA journal_mode = WAL; PRAGMA wal_autocheckpoint = 0;"
                    + " CREATE TABLE cameras(camera_id INTEGER, payload BLOB);"
                    + " CREATE TABLE rigs(rig_id INTEGER PRIMARY KEY);"
                    + " CREATE TABLE rig_sensors("
                    + "rig_id INTEGER, sensor_id INTEGER, sensor_type INTEGER);"
                    + " CREATE TABLE frames(frame_id INTEGER PRIMARY KEY);"
                    + " CREATE TABLE frame_data("
                    + "frame_id INTEGER, data_id INTEGER, sensor_id INTEGER, sensor_type INTEGER);"
                    + " CREATE TABLE images(image_id INTEGER, name TEXT);"
                    + " CREATE TABLE pose_priors(pose_prior_id INTEGER PRIMARY KEY);"
                    + " CREATE TABLE keypoints(image_id INTEGER, payload BLOB);"
                    + " CREATE TABLE descriptors(image_id INTEGER, payload BLOB);"
                    + " CREATE TABLE matches(pair_id INTEGER, payload BLOB);"
                    + " CREATE TABLE two_view_geometries(pair_id INTEGER, payload BLOB);"
                    + " INSERT INTO cameras VALUES (1, X'0102');"
                    + " INSERT INTO images VALUES (1, 'frame.jpg');"
                    + " INSERT INTO keypoints VALUES (1, X'0304');"
                    + " INSERT INTO descriptors VALUES (1, X'0506');"
                    + " INSERT INTO matches VALUES (2147483649, X'0708');"
                    + " INSERT INTO two_view_geometries VALUES (2147483649, X'090A');",
                nil,
                nil,
                nil
            ),
            SQLITE_OK
        )
        var persistWAL: Int32 = 1
        XCTAssertEqual(
            sqlite3_file_control(openedDatabase, "main", SQLITE_FCNTL_PERSIST_WAL, &persistWAL),
            SQLITE_OK
        )
        XCTAssertEqual(sqlite3_close(openedDatabase), SQLITE_OK)
        let before = try ColmapDatabaseDigester.digests(at: databaseURL)

        try ColmapDatabaseDurability.seal(at: databaseURL)

        XCTAssertEqual(try ColmapDatabaseDigester.digests(at: databaseURL), before)
    }

    func testSealRefusesBusyWALWithoutRemovingOrLosingCommittedData() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let databaseURL = root.appendingPathComponent("database.db")
        var writer: OpaquePointer?
        XCTAssertEqual(sqlite3_open(databaseURL.path, &writer), SQLITE_OK)
        let openedWriter = try XCTUnwrap(writer)
        XCTAssertEqual(
            sqlite3_exec(
                openedWriter,
                "PRAGMA journal_mode = WAL; PRAGMA wal_autocheckpoint = 0;"
                    + " CREATE TABLE marker(value INTEGER); INSERT INTO marker VALUES (1);",
                nil,
                nil,
                nil
            ),
            SQLITE_OK
        )

        var reader: OpaquePointer?
        XCTAssertEqual(
            sqlite3_open_v2(databaseURL.path, &reader, SQLITE_OPEN_READONLY, nil),
            SQLITE_OK
        )
        let openedReader = try XCTUnwrap(reader)
        XCTAssertEqual(sqlite3_exec(openedReader, "BEGIN;", nil, nil, nil), SQLITE_OK)
        var statement: OpaquePointer?
        XCTAssertEqual(
            sqlite3_prepare_v2(openedReader, "SELECT COUNT(*) FROM marker;", -1, &statement, nil),
            SQLITE_OK
        )
        let openedStatement = try XCTUnwrap(statement)
        XCTAssertEqual(sqlite3_step(openedStatement), SQLITE_ROW)
        XCTAssertEqual(sqlite3_column_int64(openedStatement, 0), 1)
        XCTAssertEqual(sqlite3_finalize(openedStatement), SQLITE_OK)
        XCTAssertEqual(
            sqlite3_exec(openedWriter, "INSERT INTO marker VALUES (2);", nil, nil, nil),
            SQLITE_OK
        )
        XCTAssertEqual(sqlite3_close(openedWriter), SQLITE_OK)

        XCTAssertThrowsError(try ColmapDatabaseDurability.seal(at: databaseURL)) { error in
            guard case .checkpointBusy = error as? ColmapDatabaseDurabilityError else {
                return XCTFail("Expected a busy checkpoint, got \(error)")
            }
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: databaseURL.path + "-wal"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: databaseURL.path + "-shm"))
        XCTAssertEqual(sqlite3_exec(openedReader, "ROLLBACK;", nil, nil, nil), SQLITE_OK)
        XCTAssertEqual(sqlite3_close(openedReader), SQLITE_OK)
        XCTAssertEqual(try markerCount(at: databaseURL), 2)
    }

    func testSealRejectsSymlinkedRollbackJournal() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let databaseURL = root.appendingPathComponent("database.db")
        let externalURL = root.appendingPathComponent("external")
        try createDatabase(at: databaseURL)
        try Data("do not touch".utf8).write(to: externalURL)
        try FileManager.default.createSymbolicLink(
            atPath: databaseURL.path + "-journal",
            withDestinationPath: externalURL.path
        )

        XCTAssertThrowsError(try ColmapDatabaseDurability.seal(at: databaseURL)) { error in
            XCTAssertEqual(error as? ColmapDatabaseDurabilityError, .unsafeDatabase)
        }
        XCTAssertEqual(try Data(contentsOf: externalURL), Data("do not touch".utf8))
    }

    func testSealRejectsUnknownCompanionWithoutRemovingIt() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let databaseURL = root.appendingPathComponent("database.db")
        try createDatabase(at: databaseURL)
        let companionURL = URL(fileURLWithPath: databaseURL.path + "-future")
        try Data("owned evidence".utf8).write(to: companionURL)

        XCTAssertThrowsError(try ColmapDatabaseDurability.seal(at: databaseURL)) { error in
            XCTAssertEqual(
                error as? ColmapDatabaseDurabilityError,
                .companionRemains("database.db-future")
            )
        }
        XCTAssertEqual(try Data(contentsOf: companionURL), Data("owned evidence".utf8))
    }

    private func createDatabase(at url: URL) throws {
        var database: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &database), SQLITE_OK)
        let openedDatabase = try XCTUnwrap(database)
        defer { sqlite3_close(openedDatabase) }
        XCTAssertEqual(
            sqlite3_exec(
                openedDatabase,
                "CREATE TABLE marker(value INTEGER); INSERT INTO marker VALUES (1);",
                nil,
                nil,
                nil
            ),
            SQLITE_OK
        )
    }

    private func markerCount(at url: URL) throws -> Int {
        var database: OpaquePointer?
        XCTAssertEqual(
            sqlite3_open_v2(url.path, &database, SQLITE_OPEN_READONLY, nil),
            SQLITE_OK
        )
        let openedDatabase = try XCTUnwrap(database)
        defer { sqlite3_close(openedDatabase) }
        var statement: OpaquePointer?
        XCTAssertEqual(
            sqlite3_prepare_v2(openedDatabase, "SELECT COUNT(*) FROM marker;", -1, &statement, nil),
            SQLITE_OK
        )
        let openedStatement = try XCTUnwrap(statement)
        defer { sqlite3_finalize(openedStatement) }
        XCTAssertEqual(sqlite3_step(openedStatement), SQLITE_ROW)
        return Int(sqlite3_column_int64(openedStatement, 0))
    }

    private func fileSize(atPath path: String) throws -> Int64 {
        let attributes = try FileManager.default.attributesOfItem(atPath: path)
        return try XCTUnwrap(attributes[.size] as? NSNumber).int64Value
    }
}
#endif
