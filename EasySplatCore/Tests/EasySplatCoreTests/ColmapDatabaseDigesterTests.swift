#if canImport(XCTest)
import Foundation
import SQLite3
import XCTest
@testable import EasySplatCore

final class ColmapDatabaseDigesterTests: XCTestCase {
    func testDigestRejectsHardLinkedDatabase() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let externalDatabase = root.appendingPathComponent("external.db")
        let databaseURL = root.appendingPathComponent("database.db")
        try makeDatabase(at: externalDatabase)
        try FileManager.default.linkItem(at: externalDatabase, to: databaseURL)

        XCTAssertThrowsError(try ColmapDatabaseDigester.digests(at: databaseURL)) { error in
            XCTAssertEqual(error as? ColmapDatabaseDigesterError, .unsafeDatabase)
        }
    }

    func testDigestRejectsSymlinkDatabase() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let externalDatabase = root.appendingPathComponent("external.db")
        let databaseURL = root.appendingPathComponent("database.db")
        try makeDatabase(at: externalDatabase)
        try FileManager.default.createSymbolicLink(
            at: databaseURL,
            withDestinationURL: externalDatabase
        )

        XCTAssertThrowsError(try ColmapDatabaseDigester.digests(at: databaseURL)) { error in
            XCTAssertEqual(error as? ColmapDatabaseDigesterError, .unsafeDatabase)
        }
    }

    func testLogicalDigestsBindFeatureAndCorrespondencePayloadsIndependently() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let databaseURL = root.appendingPathComponent("database.db")
        try makeDatabase(at: databaseURL)

        let initial = try ColmapDatabaseDigester.digests(at: databaseURL)
        XCTAssertEqual(initial.feature.count, 64)
        XCTAssertEqual(initial.matching.count, 64)

        try execute(
            "UPDATE matches SET data = X'09080706' WHERE pair_id = 2147483649;",
            at: databaseURL
        )
        let changedMatchPayload = try ColmapDatabaseDigester.digests(at: databaseURL)
        XCTAssertEqual(changedMatchPayload.feature, initial.feature)
        XCTAssertNotEqual(changedMatchPayload.matching, initial.matching)

        try execute(
            "UPDATE two_view_geometries SET config = 7 WHERE pair_id = 2147483649;",
            at: databaseURL
        )
        let changedGeometry = try ColmapDatabaseDigester.digests(at: databaseURL)
        XCTAssertNotEqual(changedGeometry.matching, changedMatchPayload.matching)

        try execute(
            "UPDATE descriptors SET data = X'04030201' WHERE image_id = 1;",
            at: databaseURL
        )
        let changedFeature = try ColmapDatabaseDigester.digests(at: databaseURL)
        XCTAssertNotEqual(changedFeature.feature, initial.feature)
        XCTAssertEqual(changedFeature.matching, changedGeometry.matching)
    }

    func testDigestRejectsDatabaseWithoutRequiredTables() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let databaseURL = root.appendingPathComponent("database.db")
        try execute("CREATE TABLE images(image_id INTEGER PRIMARY KEY, name TEXT);", at: databaseURL)

        XCTAssertThrowsError(try ColmapDatabaseDigester.digests(at: databaseURL))
    }

    private func makeDatabase(at url: URL) throws {
        try execute(
            """
            CREATE TABLE cameras(
                camera_id INTEGER PRIMARY KEY,
                model INTEGER NOT NULL,
                width INTEGER NOT NULL,
                height INTEGER NOT NULL,
                params BLOB,
                prior_focal_length INTEGER NOT NULL
            );
            CREATE TABLE images(
                image_id INTEGER PRIMARY KEY,
                name TEXT NOT NULL,
                camera_id INTEGER NOT NULL
            );
            CREATE TABLE keypoints(
                image_id INTEGER PRIMARY KEY,
                rows INTEGER NOT NULL,
                cols INTEGER NOT NULL,
                data BLOB
            );
            CREATE TABLE descriptors(
                image_id INTEGER PRIMARY KEY,
                rows INTEGER NOT NULL,
                cols INTEGER NOT NULL,
                data BLOB,
                type INTEGER NOT NULL DEFAULT 0
            );
            CREATE TABLE matches(
                pair_id INTEGER PRIMARY KEY,
                rows INTEGER NOT NULL,
                cols INTEGER NOT NULL,
                data BLOB
            );
            CREATE TABLE two_view_geometries(
                pair_id INTEGER PRIMARY KEY,
                rows INTEGER NOT NULL,
                cols INTEGER NOT NULL,
                data BLOB,
                config INTEGER NOT NULL,
                F BLOB,
                E BLOB,
                H BLOB,
                qvec BLOB,
                tvec BLOB
            );
            INSERT INTO cameras VALUES (1, 0, 640, 480, X'01020304', 0);
            INSERT INTO images VALUES (1, 'a.jpg', 1), (2, 'b.jpg', 1);
            INSERT INTO keypoints VALUES
                (1, 1, 4, X'01020304'),
                (2, 1, 4, X'05060708');
            INSERT INTO descriptors VALUES
                (1, 1, 128, X'01020304', 0),
                (2, 1, 128, X'05060708', 0);
            INSERT INTO matches VALUES (2147483649, 1, 2, X'01020304');
            INSERT INTO two_view_geometries VALUES
                (2147483649, 1, 2, X'01020304', 2, X'01', X'02', X'03', X'04', X'05');
            """,
            at: url
        )
    }

    private func execute(_ sql: String, at url: URL) throws {
        var database: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &database), SQLITE_OK)
        guard let database else { throw NSError(domain: "SQLite", code: 1) }
        defer { sqlite3_close(database) }
        var message: UnsafeMutablePointer<CChar>?
        let result = sqlite3_exec(database, sql, nil, nil, &message)
        let detail = message.map { String(cString: $0) }
        sqlite3_free(message)
        guard result == SQLITE_OK else {
            throw NSError(
                domain: "SQLite",
                code: Int(result),
                userInfo: [NSLocalizedDescriptionKey: detail ?? "SQLite failure"]
            )
        }
    }
}
#endif
