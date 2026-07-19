#if canImport(XCTest)
import Foundation
import SQLite3
import XCTest
@testable import EasySplatCore

final class ColmapFeatureDatabaseIdentityVerifierTests: XCTestCase {
    func testAcceptsLexicalImageFrameAndOptionalPosePriorIdentities() throws {
        let fixture = try makeFixture(
            rows: [
                (3, "zulu.jpg"),
                (1, "alpha.jpg"),
                (2, "middle.jpg"),
            ],
            posePriorImageIDs: [2]
        )
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        XCTAssertNoThrow(try ColmapFeatureDatabaseIdentityVerifier.verify(
            databaseURL: fixture.database,
            expectedImageNames: ["middle.jpg", "zulu.jpg", "alpha.jpg"]
        ))
    }

    func testRejectsCompletionOrderImageIDs() throws {
        let fixture = try makeFixture(rows: [(1, "zulu.jpg"), (2, "alpha.jpg")])
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        XCTAssertThrowsError(try ColmapFeatureDatabaseIdentityVerifier.verify(
            databaseURL: fixture.database,
            expectedImageNames: ["alpha.jpg", "zulu.jpg"]
        )) { error in
            XCTAssertEqual(
                error as? ColmapFeatureDatabaseIdentityError,
                .unstableImageID(imageName: "alpha.jpg", expected: 1, actual: 2)
            )
        }
    }

    func testRejectsFrameIDThatDoesNotMatchStableImageID() throws {
        let fixture = try makeFixture(rows: [(1, "alpha.jpg"), (2, "bravo.jpg")])
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try execute(
            "UPDATE frame_data SET frame_id = 9 WHERE data_id = 2; "
                + "UPDATE frames SET frame_id = 9 WHERE frame_id = 2;",
            at: fixture.database
        )

        XCTAssertThrowsError(try ColmapFeatureDatabaseIdentityVerifier.verify(
            databaseURL: fixture.database,
            expectedImageNames: ["alpha.jpg", "bravo.jpg"]
        )) { error in
            XCTAssertEqual(
                error as? ColmapFeatureDatabaseIdentityError,
                .unstableFrameID(imageName: "bravo.jpg", expected: 2)
            )
        }
    }

    func testRejectsPosePriorIDThatDoesNotMatchStableImageID() throws {
        let fixture = try makeFixture(
            rows: [(1, "alpha.jpg"), (2, "bravo.jpg")],
            posePriorImageIDs: [2]
        )
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try execute(
            "UPDATE pose_priors SET pose_prior_id = 9 WHERE corr_data_id = 2;",
            at: fixture.database
        )

        XCTAssertThrowsError(try ColmapFeatureDatabaseIdentityVerifier.verify(
            databaseURL: fixture.database,
            expectedImageNames: ["alpha.jpg", "bravo.jpg"]
        )) { error in
            XCTAssertEqual(
                error as? ColmapFeatureDatabaseIdentityError,
                .unstablePosePriorID(imageName: "bravo.jpg", expected: 2)
            )
        }
    }

    func testRejectsUnexpectedImageSetAndUnsafeDatabaseAliases() throws {
        let fixture = try makeFixture(rows: [(1, "alpha.jpg"), (2, "bravo.jpg")])
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        XCTAssertThrowsError(try ColmapFeatureDatabaseIdentityVerifier.verify(
            databaseURL: fixture.database,
            expectedImageNames: ["alpha.jpg", "charlie.jpg"]
        )) { error in
            XCTAssertEqual(
                error as? ColmapFeatureDatabaseIdentityError,
                .imageSetMismatch(
                    expected: ["alpha.jpg", "charlie.jpg"],
                    actual: ["alpha.jpg", "bravo.jpg"]
                )
            )
        }

        let alias = fixture.root.appendingPathComponent("alias.db")
        try FileManager.default.createSymbolicLink(
            at: alias,
            withDestinationURL: fixture.database
        )
        XCTAssertThrowsError(try ColmapFeatureDatabaseIdentityVerifier.verify(
            databaseURL: alias,
            expectedImageNames: ["alpha.jpg", "bravo.jpg"]
        )) { error in
            XCTAssertEqual(error as? ColmapFeatureDatabaseIdentityError, .unsafeDatabase)
        }
    }

    private func makeFixture(
        rows: [(Int64, String)],
        posePriorImageIDs: Set<Int64> = []
    ) throws -> (root: URL, database: URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let databaseURL = root.appendingPathComponent("database.db")
        var database: OpaquePointer?
        guard sqlite3_open(databaseURL.path, &database) == SQLITE_OK,
              let database else {
            throw NSError(domain: "ColmapFeatureDatabaseIdentityVerifierTests", code: 1)
        }
        defer { sqlite3_close(database) }
        try execute(
            """
            CREATE TABLE images(
                image_id INTEGER PRIMARY KEY,
                name TEXT NOT NULL UNIQUE,
                camera_id INTEGER NOT NULL
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
            """,
            in: database
        )
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        var imageStatement: OpaquePointer?
        guard sqlite3_prepare_v2(
            database,
            "INSERT INTO images(image_id, name, camera_id) VALUES (?, ?, ?);",
            -1,
            &imageStatement,
            nil
        ) == SQLITE_OK,
        let imageStatement else {
            throw sqliteError(database)
        }
        defer { sqlite3_finalize(imageStatement) }
        for (imageID, name) in rows {
            guard sqlite3_bind_int64(imageStatement, 1, imageID) == SQLITE_OK,
                  name.withCString({
                      sqlite3_bind_text(imageStatement, 2, $0, -1, transient)
                  }) == SQLITE_OK,
                  sqlite3_bind_int64(imageStatement, 3, imageID) == SQLITE_OK,
                  sqlite3_step(imageStatement) == SQLITE_DONE else {
                throw sqliteError(database)
            }
            sqlite3_reset(imageStatement)
            sqlite3_clear_bindings(imageStatement)
            try execute(
                "INSERT INTO frames(frame_id, rig_id) VALUES (\(imageID), \(imageID)); "
                    + "INSERT INTO frame_data(frame_id, data_id, sensor_id, sensor_type) "
                    + "VALUES (\(imageID), \(imageID), \(imageID), 0);",
                in: database
            )
            if posePriorImageIDs.contains(imageID) {
                try execute(
                    "INSERT INTO pose_priors(pose_prior_id, corr_data_id, corr_sensor_id, "
                        + "corr_sensor_type, coordinate_system) "
                        + "VALUES (\(imageID), \(imageID), \(imageID), 0, 0);",
                    in: database
                )
            }
        }
        return (root, databaseURL)
    }

    private func execute(_ sql: String, at databaseURL: URL) throws {
        var database: OpaquePointer?
        guard sqlite3_open(databaseURL.path, &database) == SQLITE_OK,
              let database else {
            throw NSError(domain: "ColmapFeatureDatabaseIdentityVerifierTests", code: 2)
        }
        defer { sqlite3_close(database) }
        try execute(sql, in: database)
    }

    private func execute(_ sql: String, in database: OpaquePointer) throws {
        var message: UnsafeMutablePointer<CChar>?
        let result = sqlite3_exec(database, sql, nil, nil, &message)
        defer { sqlite3_free(message) }
        guard result == SQLITE_OK else {
            throw NSError(
                domain: "ColmapFeatureDatabaseIdentityVerifierTests",
                code: Int(result),
                userInfo: [
                    NSLocalizedDescriptionKey: message.map { String(cString: $0) }
                        ?? String(cString: sqlite3_errmsg(database))
                ]
            )
        }
    }

    private func sqliteError(_ database: OpaquePointer) -> NSError {
        NSError(
            domain: "ColmapFeatureDatabaseIdentityVerifierTests",
            code: Int(sqlite3_errcode(database)),
            userInfo: [NSLocalizedDescriptionKey: String(cString: sqlite3_errmsg(database))]
        )
    }
}
#endif
