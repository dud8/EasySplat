#if canImport(XCTest)
import Foundation
import SQLite3
import XCTest
@testable import EasySplatCore

final class ColmapDatabaseMatchStoreTests: XCTestCase {
    func testRequireMatchingResultsEmptyAcceptsEmptyTables() throws {
        let fixture = try makeMatchingDatabase(rawRows: 0, verifiedRows: 0)
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        XCTAssertNoThrow(
            try ColmapDatabaseMatchStore.requireMatchingResultsEmpty(
                at: fixture.database
            )
        )
    }

    func testRequireMatchingResultsEmptyRejectsRawRows() throws {
        let fixture = try makeMatchingDatabase(rawRows: 2, verifiedRows: 0)
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        XCTAssertThrowsError(
            try ColmapDatabaseMatchStore.requireMatchingResultsEmpty(
                at: fixture.database
            )
        ) { error in
            XCTAssertEqual(
                error as? ColmapDatabaseMatchStoreError,
                .matchingResultsNotEmpty(rawMatchCount: 2, verifiedMatchCount: 0)
            )
        }
    }

    func testRequireMatchingResultsEmptyRejectsVerifiedRows() throws {
        let fixture = try makeMatchingDatabase(rawRows: 0, verifiedRows: 3)
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        XCTAssertThrowsError(
            try ColmapDatabaseMatchStore.requireMatchingResultsEmpty(
                at: fixture.database
            )
        ) { error in
            XCTAssertEqual(
                error as? ColmapDatabaseMatchStoreError,
                .matchingResultsNotEmpty(rawMatchCount: 0, verifiedMatchCount: 3)
            )
        }
    }

    func testRequireMatchingResultsEmptyRejectsBothKindsOfRows() throws {
        let fixture = try makeMatchingDatabase(rawRows: 4, verifiedRows: 5)
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        XCTAssertThrowsError(
            try ColmapDatabaseMatchStore.requireMatchingResultsEmpty(
                at: fixture.database
            )
        ) { error in
            XCTAssertEqual(
                error as? ColmapDatabaseMatchStoreError,
                .matchingResultsNotEmpty(rawMatchCount: 4, verifiedMatchCount: 5)
            )
        }
    }

    func testRequireMatchingResultsEmptyRejectsHardLink() throws {
        let fixture = try makeMatchingDatabase(rawRows: 0, verifiedRows: 0)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let hardLink = fixture.root.appendingPathComponent("linked.db")
        try FileManager.default.linkItem(at: fixture.database, to: hardLink)

        XCTAssertThrowsError(
            try ColmapDatabaseMatchStore.requireMatchingResultsEmpty(at: hardLink)
        ) { error in
            XCTAssertEqual(error as? ColmapDatabaseMatchStoreError, .unsafeDatabaseFile)
        }
    }

    func testClearMatchingResultsRejectsHardLinkWithoutTouchingExternalDatabase() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let projectDirectory = directory.appendingPathComponent("Project", isDirectory: true)
        let externalDatabase = directory.appendingPathComponent("external.db")
        let projectDatabase = projectDirectory.appendingPathComponent("database.db")
        try FileManager.default.createDirectory(
            at: projectDirectory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }

        do {
            var handle: OpaquePointer?
            XCTAssertEqual(sqlite3_open(externalDatabase.path, &handle), SQLITE_OK)
            guard let handle else {
                XCTFail("Could not create external fixture database")
                return
            }
            defer { sqlite3_close(handle) }
            try execute(
                """
                CREATE TABLE matches(pair_id INTEGER PRIMARY KEY, rows INTEGER);
                CREATE TABLE two_view_geometries(pair_id INTEGER PRIMARY KEY, rows INTEGER);
                INSERT INTO matches VALUES (2147483649, 80);
                INSERT INTO two_view_geometries VALUES (2147483649, 64);
                """,
                in: handle
            )
        }
        try FileManager.default.linkItem(at: externalDatabase, to: projectDatabase)

        XCTAssertThrowsError(
            try ColmapDatabaseMatchStore.clearMatchingResults(at: projectDatabase)
        ) { error in
            XCTAssertEqual(
                error as? ColmapDatabaseMatchStoreError,
                .unsafeDatabaseFile
            )
        }
        var verificationHandle: OpaquePointer?
        XCTAssertEqual(
            sqlite3_open_v2(externalDatabase.path, &verificationHandle, SQLITE_OPEN_READONLY, nil),
            SQLITE_OK
        )
        guard let verificationHandle else {
            XCTFail("Could not reopen external fixture database")
            return
        }
        defer { sqlite3_close(verificationHandle) }
        XCTAssertEqual(try count("matches", in: verificationHandle), 1)
        XCTAssertEqual(try count("two_view_geometries", in: verificationHandle), 1)
    }

    func testClearMatchingResultsRejectsSymlinkWithoutTouchingExternalDatabase() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let projectDirectory = directory.appendingPathComponent("Project", isDirectory: true)
        let externalDatabase = directory.appendingPathComponent("external.db")
        let projectDatabase = projectDirectory.appendingPathComponent("database.db")
        try FileManager.default.createDirectory(
            at: projectDirectory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }

        var handle: OpaquePointer?
        XCTAssertEqual(sqlite3_open(externalDatabase.path, &handle), SQLITE_OK)
        guard let handle else {
            XCTFail("Could not create external fixture database")
            return
        }
        defer { sqlite3_close(handle) }
        try execute(
            """
            CREATE TABLE matches(pair_id INTEGER PRIMARY KEY, rows INTEGER);
            CREATE TABLE two_view_geometries(pair_id INTEGER PRIMARY KEY, rows INTEGER);
            INSERT INTO matches VALUES (2147483649, 80);
            INSERT INTO two_view_geometries VALUES (2147483649, 64);
            """,
            in: handle
        )
        try FileManager.default.createSymbolicLink(
            at: projectDatabase,
            withDestinationURL: externalDatabase
        )

        XCTAssertThrowsError(
            try ColmapDatabaseMatchStore.clearMatchingResults(at: projectDatabase)
        ) { error in
            XCTAssertEqual(
                error as? ColmapDatabaseMatchStoreError,
                .unsafeDatabaseFile
            )
        }
        XCTAssertEqual(try count("matches", in: handle), 1)
        XCTAssertEqual(try count("two_view_geometries", in: handle), 1)
    }

    func testClearMatchingResultsRejectsDirectory() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        XCTAssertThrowsError(
            try ColmapDatabaseMatchStore.clearMatchingResults(at: directory)
        ) { error in
            XCTAssertEqual(
                error as? ColmapDatabaseMatchStoreError,
                .unsafeDatabaseFile
            )
        }
    }

    func testClearMatchingResultsPreservesFeaturesAndCameras() throws {
        let database = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("db")
        defer { try? FileManager.default.removeItem(at: database) }

        var handle: OpaquePointer?
        XCTAssertEqual(sqlite3_open(database.path, &handle), SQLITE_OK)
        guard let handle else {
            XCTFail("Could not create fixture database")
            return
        }
        defer { sqlite3_close(handle) }

        try execute(
            """
            CREATE TABLE cameras(camera_id INTEGER PRIMARY KEY, model INTEGER);
            CREATE TABLE images(image_id INTEGER PRIMARY KEY, camera_id INTEGER);
            CREATE TABLE keypoints(image_id INTEGER PRIMARY KEY, rows INTEGER);
            CREATE TABLE descriptors(image_id INTEGER PRIMARY KEY, rows INTEGER);
            CREATE TABLE matches(pair_id INTEGER PRIMARY KEY, rows INTEGER);
            CREATE TABLE two_view_geometries(pair_id INTEGER PRIMARY KEY, rows INTEGER);
            INSERT INTO cameras VALUES (1, 1);
            INSERT INTO images VALUES (1, 1), (2, 1);
            INSERT INTO keypoints VALUES (1, 100), (2, 120);
            INSERT INTO descriptors VALUES (1, 100), (2, 120);
            INSERT INTO matches VALUES (2147483649, 80);
            INSERT INTO two_view_geometries VALUES (2147483649, 64);
            """,
            in: handle
        )

        try ColmapDatabaseMatchStore.clearMatchingResults(at: database)

        XCTAssertEqual(try count("cameras", in: handle), 1)
        XCTAssertEqual(try count("images", in: handle), 2)
        XCTAssertEqual(try count("keypoints", in: handle), 2)
        XCTAssertEqual(try count("descriptors", in: handle), 2)
        XCTAssertEqual(try count("matches", in: handle), 0)
        XCTAssertEqual(try count("two_view_geometries", in: handle), 0)
    }

    func testClearMatchingResultsRollsBackWhenSchemaIsIncomplete() throws {
        let database = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("db")
        defer { try? FileManager.default.removeItem(at: database) }

        var handle: OpaquePointer?
        XCTAssertEqual(sqlite3_open(database.path, &handle), SQLITE_OK)
        guard let handle else {
            XCTFail("Could not create fixture database")
            return
        }
        defer { sqlite3_close(handle) }

        try execute(
            """
            CREATE TABLE matches(pair_id INTEGER PRIMARY KEY, rows INTEGER);
            INSERT INTO matches VALUES (2147483649, 80);
            """,
            in: handle
        )

        XCTAssertThrowsError(
            try ColmapDatabaseMatchStore.clearMatchingResults(at: database)
        ) { error in
            guard case let .operationFailed(operation, _, _) = error as? ColmapDatabaseMatchStoreError else {
                return XCTFail("Expected the verified-match delete to fail")
            }
            XCTAssertEqual(operation, "clear verified matches")
        }
        XCTAssertEqual(try count("matches", in: handle), 1)
    }

    private func execute(_ sql: String, in database: OpaquePointer) throws {
        var message: UnsafeMutablePointer<CChar>?
        let result = sqlite3_exec(database, sql, nil, nil, &message)
        defer { sqlite3_free(message) }
        guard result == SQLITE_OK else {
            throw NSError(
                domain: "ColmapDatabaseMatchStoreTests",
                code: Int(result),
                userInfo: [
                    NSLocalizedDescriptionKey: message.map { String(cString: $0) } ?? "SQLite error"
                ]
            )
        }
    }

    private func makeMatchingDatabase(
        rawRows: Int,
        verifiedRows: Int
    ) throws -> (root: URL, database: URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let databaseURL = root.appendingPathComponent("database.db")
        var database: OpaquePointer?
        guard sqlite3_open(databaseURL.path, &database) == SQLITE_OK,
              let database else {
            throw NSError(domain: "ColmapDatabaseMatchStoreTests", code: 3)
        }
        defer { sqlite3_close(database) }
        try execute(
            "CREATE TABLE matches(pair_id INTEGER PRIMARY KEY);"
                + " CREATE TABLE two_view_geometries(pair_id INTEGER PRIMARY KEY);",
            in: database
        )
        for pairIndex in 0..<rawRows {
            try execute("INSERT INTO matches VALUES (\(pairIndex + 1));", in: database)
        }
        for pairIndex in 0..<verifiedRows {
            try execute(
                "INSERT INTO two_view_geometries VALUES (\(pairIndex + 1));",
                in: database
            )
        }
        return (root, databaseURL)
    }

    private func count(_ table: String, in database: OpaquePointer) throws -> Int {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "SELECT COUNT(*) FROM \(table);", -1, &statement, nil) == SQLITE_OK,
              let statement else {
            throw NSError(domain: "ColmapDatabaseMatchStoreTests", code: 1)
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else {
            throw NSError(domain: "ColmapDatabaseMatchStoreTests", code: 2)
        }
        return Int(sqlite3_column_int64(statement, 0))
    }
}
#endif
