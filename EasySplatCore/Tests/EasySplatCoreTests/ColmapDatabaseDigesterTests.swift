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

    func testFeatureDigestBindsEveryMapperMetadataTableWithoutChangingMatchingDigest() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let databaseURL = root.appendingPathComponent("database.db")
        try makeDatabase(at: databaseURL)

        let mutations = [
            "UPDATE rigs SET ref_sensor_id = 12 WHERE rig_id = 1;",
            "UPDATE rig_sensors SET sensor_from_rig = X'09' WHERE rig_id = 1;",
            "UPDATE frames SET rig_id = 2 WHERE frame_id = 1;",
            "UPDATE frame_data SET sensor_id = 13 WHERE frame_id = 1;",
            "UPDATE pose_priors SET gravity = X'0807' WHERE pose_prior_id = 1;",
        ]

        var previous = try ColmapDatabaseDigester.digests(at: databaseURL)
        for mutation in mutations {
            try execute(mutation, at: databaseURL)
            let changed = try ColmapDatabaseDigester.digests(at: databaseURL)
            XCTAssertNotEqual(changed.feature, previous.feature, mutation)
            XCTAssertEqual(changed.matching, previous.matching, mutation)
            previous = changed
        }
    }

    func testFeatureDigestDoesNotDependOnMapperMetadataInsertionOrder() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let forwardURL = root.appendingPathComponent("forward.db")
        let reverseURL = root.appendingPathComponent("reverse.db")
        try makeDatabase(at: forwardURL, reverseMapperMetadataInsertion: false)
        try makeDatabase(at: reverseURL, reverseMapperMetadataInsertion: true)

        XCTAssertEqual(
            try ColmapDatabaseDigester.digests(at: forwardURL),
            try ColmapDatabaseDigester.digests(at: reverseURL)
        )
    }

    func testDigestRejectsMissingMapperMetadataTable() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let databaseURL = root.appendingPathComponent("database.db")
        try makeDatabase(at: databaseURL)
        try execute("DROP TABLE frame_data;", at: databaseURL)

        XCTAssertThrowsError(try ColmapDatabaseDigester.digests(at: databaseURL)) { error in
            XCTAssertEqual(error as? ColmapDatabaseDigesterError, .invalidTable("frame_data"))
        }
    }

    func testDigestRejectsMapperMetadataTableWithoutEveryOrderingColumn() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let databaseURL = root.appendingPathComponent("database.db")
        try makeDatabase(at: databaseURL)
        try execute(
            """
            DROP TABLE rig_sensors;
            CREATE TABLE rig_sensors(
                rig_id INTEGER NOT NULL,
                sensor_id INTEGER NOT NULL,
                sensor_from_rig BLOB
            );
            """,
            at: databaseURL
        )

        XCTAssertThrowsError(try ColmapDatabaseDigester.digests(at: databaseURL)) { error in
            XCTAssertEqual(error as? ColmapDatabaseDigesterError, .invalidTable("rig_sensors"))
        }
    }

    func testDigestRejectsDatabaseWithoutRequiredTables() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let databaseURL = root.appendingPathComponent("database.db")
        try execute("CREATE TABLE images(image_id INTEGER PRIMARY KEY, name TEXT);", at: databaseURL)

        XCTAssertThrowsError(try ColmapDatabaseDigester.digests(at: databaseURL))
    }

    func testDigestReadsCheckpointedWALDatabaseWithoutSidecars() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let databaseURL = root.appendingPathComponent("database.db")
        try makeDatabase(at: databaseURL)
        try execute("PRAGMA journal_mode = WAL;", at: databaseURL)

        let header = try Data(contentsOf: databaseURL, options: .mappedIfSafe)
        XCTAssertGreaterThanOrEqual(header.count, 20)
        XCTAssertEqual(Array(header[18...19]), [2, 2])
        XCTAssertFalse(FileManager.default.fileExists(atPath: databaseURL.path + "-wal"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: databaseURL.path + "-shm"))

        let digests = try ColmapDatabaseDigester.digests(at: databaseURL)
        XCTAssertEqual(digests.feature.count, 64)
        XCTAssertEqual(digests.matching.count, 64)
    }

    private func makeDatabase(
        at url: URL,
        reverseMapperMetadataInsertion: Bool = false
    ) throws {
        let mapperMetadataRows = reverseMapperMetadataInsertion
            ? """
              INSERT INTO rigs VALUES (2, 20, 0), (1, 10, 0);
              INSERT INTO rig_sensors VALUES (2, 20, 0, X'0202'), (1, 10, 0, X'0101');
              INSERT INTO frames VALUES (2, 2), (1, 1);
              INSERT INTO frame_data VALUES (2, 2, 20, 0), (1, 1, 10, 0);
              INSERT INTO pose_priors VALUES
                  (2, 2, 20, 0, X'0202', X'0203', X'0204', 1),
                  (1, 1, 10, 0, X'0102', X'0103', X'0104', 1);
              """
            : """
              INSERT INTO rigs VALUES (1, 10, 0), (2, 20, 0);
              INSERT INTO rig_sensors VALUES (1, 10, 0, X'0101'), (2, 20, 0, X'0202');
              INSERT INTO frames VALUES (1, 1), (2, 2);
              INSERT INTO frame_data VALUES (1, 1, 10, 0), (2, 2, 20, 0);
              INSERT INTO pose_priors VALUES
                  (1, 1, 10, 0, X'0102', X'0103', X'0104', 1),
                  (2, 2, 20, 0, X'0202', X'0203', X'0204', 1);
              """
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
            CREATE TABLE rigs(
                rig_id INTEGER PRIMARY KEY,
                ref_sensor_id INTEGER NOT NULL,
                ref_sensor_type INTEGER NOT NULL
            );
            CREATE TABLE rig_sensors(
                rig_id INTEGER NOT NULL,
                sensor_id INTEGER NOT NULL,
                sensor_type INTEGER NOT NULL,
                sensor_from_rig BLOB
            );
            CREATE TABLE frames(
                frame_id INTEGER PRIMARY KEY,
                rig_id INTEGER NOT NULL
            );
            CREATE TABLE frame_data(
                frame_id INTEGER NOT NULL,
                data_id INTEGER NOT NULL,
                sensor_id INTEGER NOT NULL,
                sensor_type INTEGER NOT NULL
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
            CREATE TABLE pose_priors(
                pose_prior_id INTEGER PRIMARY KEY,
                corr_data_id INTEGER NOT NULL,
                corr_sensor_id INTEGER NOT NULL,
                corr_sensor_type INTEGER NOT NULL,
                position BLOB,
                position_covariance BLOB,
                gravity BLOB,
                coordinate_system INTEGER NOT NULL
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
            \(mapperMetadataRows)
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
