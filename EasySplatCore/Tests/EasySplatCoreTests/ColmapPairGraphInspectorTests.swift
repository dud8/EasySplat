#if canImport(XCTest)
import SQLite3
import XCTest
@testable import EasySplatCore

final class ColmapPairGraphInspectorTests: XCTestCase {
    func testRejectsSymlinkDatabaseWithoutReadingItsTarget() throws {
        let externalDatabase = try makeDatabase(
            imageIDs: [1, 2],
            matches: [(pairID(1, 2), 5)],
            verified: [(pairID(1, 2), 3)]
        )
        let databaseURL = externalDatabase
            .deletingLastPathComponent()
            .appendingPathComponent("linked.db")
        try FileManager.default.createSymbolicLink(
            at: databaseURL,
            withDestinationURL: externalDatabase
        )

        XCTAssertThrowsError(
            try ColmapPairGraphInspector(databaseURL: databaseURL).inspect(
                schedule: makeSchedule(imageIDs: [1, 2], pairs: [(1, 2, .local)]),
                completion: .succeeded
            )
        ) { error in
            XCTAssertEqual(error as? ColmapPairGraphInspectorError, .unsafeDatabaseFile)
        }
    }

    func testRejectsHardLinkedDatabaseWithoutReadingItsTarget() throws {
        let externalDatabase = try makeDatabase(
            imageIDs: [1, 2],
            matches: [(pairID(1, 2), 5)],
            verified: [(pairID(1, 2), 3)]
        )
        let databaseURL = externalDatabase
            .deletingLastPathComponent()
            .appendingPathComponent("linked.db")
        try FileManager.default.linkItem(at: externalDatabase, to: databaseURL)

        XCTAssertThrowsError(
            try ColmapPairGraphInspector(databaseURL: databaseURL).inspect(
                schedule: makeSchedule(imageIDs: [1, 2], pairs: [(1, 2, .local)]),
                completion: .succeeded
            )
        ) { error in
            XCTAssertEqual(error as? ColmapPairGraphInspectorError, .unsafeDatabaseFile)
        }
    }

    func testRejectsDatabaseReachedThroughSymlinkedImmediateParent() throws {
        let externalDatabase = try makeDatabase(
            imageIDs: [1, 2],
            matches: [(pairID(1, 2), 5)],
            verified: [(pairID(1, 2), 3)]
        )
        let directory = externalDatabase.deletingLastPathComponent()
        let linkedParent = directory.appendingPathComponent("linked-parent", isDirectory: true)
        try FileManager.default.createSymbolicLink(
            at: linkedParent,
            withDestinationURL: directory
        )
        let databaseURL = linkedParent.appendingPathComponent(externalDatabase.lastPathComponent)

        XCTAssertThrowsError(
            try ColmapPairGraphInspector(databaseURL: databaseURL).inspect(
                schedule: makeSchedule(imageIDs: [1, 2], pairs: [(1, 2, .local)]),
                completion: .succeeded
            )
        ) { error in
            XCTAssertEqual(error as? ColmapPairGraphInspectorError, .unsafeDatabaseFile)
        }
    }

    func testInspectsCompleteSuccessfulAttemptAndBindsDatabasePayloads() throws {
        let databaseURL = try makeDatabase(
            imageIDs: [2, 7, 11, 20],
            matches: [
                (pairID(2, 7), 12),
                (pairID(7, 11), 18),
                (pairID(11, 20), 0),
                (pairID(2, 20), 9),
            ],
            verified: [
                (pairID(2, 7), 8),
                (pairID(7, 11), 10),
                (pairID(11, 20), 0),
                (pairID(2, 20), 0),
            ]
        )
        let schedule = makeSchedule(
            imageIDs: [2, 7, 11, 20],
            pairs: [
                (2, 7, .local),
                (7, 11, .retrieval),
                (11, 20, .loopRevisit),
                (2, 20, .retrieval),
            ]
        )

        let result = try ColmapPairGraphInspector(databaseURL: databaseURL).inspect(
            schedule: schedule,
            completion: .succeeded
        )

        XCTAssertEqual(result.scheduledPairCount, 4)
        XCTAssertEqual(result.attemptedPairCount, 4)
        XCTAssertEqual(result.rawMatchedPairCount, 3)
        XCTAssertEqual(result.spatiallyVerifiedPairCount, 2)
        XCTAssertEqual(result.localPairCount, 1)
        XCTAssertEqual(result.retrievalPairCount, 2)
        XCTAssertEqual(result.loopRevisitPairCount, 1)
        XCTAssertEqual(result.connectedComponentCount, 2)
        XCTAssertEqual(result.isolatedViewCount, 1)
        XCTAssertEqual(result.degreeP10, 0)
        XCTAssertEqual(result.degreeMedian, 1)
        XCTAssertEqual(result.degreeP90, 2)
        XCTAssertEqual(result.featureDatabaseDigest.count, 64)
        XCTAssertEqual(result.matchingDatabaseDigest.count, 64)
    }

    func testZeroRowPairsAreAttemptedButNotMatchedOrVerified() throws {
        let databaseURL = try makeDatabase(
            imageIDs: [3, 9],
            matches: [(pairID(3, 9), 0)],
            verified: [(pairID(3, 9), 0)]
        )
        let schedule = makeSchedule(imageIDs: [3, 9], pairs: [(3, 9, .local)])

        let result = try ColmapPairGraphInspector(databaseURL: databaseURL).inspect(
            schedule: schedule,
            completion: .succeeded
        )

        XCTAssertEqual(result.attemptedPairCount, 1)
        XCTAssertEqual(result.rawMatchedPairCount, 0)
        XCTAssertEqual(result.spatiallyVerifiedPairCount, 0)
        XCTAssertEqual(result.connectedComponentCount, 2)
        XCTAssertEqual(result.isolatedViewCount, 2)
        XCTAssertEqual(result.degreeP10, 0)
        XCTAssertEqual(result.degreeMedian, 0)
        XCTAssertEqual(result.degreeP90, 0)
    }

    func testNoncontiguousPositiveImageIDsAreSupported() throws {
        let databaseURL = try makeDatabase(
            imageIDs: [1, 41, 10_003],
            matches: [(pairID(1, 10_003), 6)],
            verified: [(pairID(1, 10_003), 4)]
        )
        let schedule = makeSchedule(
            imageIDs: [1, 41, 10_003],
            pairs: [(10_003, 1, .retrieval)]
        )

        let result = try ColmapPairGraphInspector(databaseURL: databaseURL).inspect(
            schedule: schedule,
            completion: .succeeded
        )

        XCTAssertEqual(result.connectedComponentCount, 2)
        XCTAssertEqual(result.isolatedViewCount, 1)
    }

    func testSupportsZeroAndNoncontiguousImageIDs() throws {
        let databaseURL = try makeDatabase(
            imageIDs: [0, 5, 91],
            matches: [(pairID(0, 5), 7)],
            verified: [(pairID(0, 5), 5)]
        )
        let schedule = makeSchedule(imageIDs: [0, 5], pairs: [(0, 5, .local)])
        let completeSchedule = ColmapPairSchedule(
            imageNames: [imageName(0), imageName(5), imageName(91)],
            pairs: schedule.pairs
        )

        let result = try ColmapPairGraphInspector(databaseURL: databaseURL).inspect(
            schedule: completeSchedule,
            completion: .failed
        )

        XCTAssertEqual(result.spatiallyVerifiedPairCount, 1)
        XCTAssertEqual(result.isolatedViewCount, 1)
    }

    func testSuccessfulAttemptRequiresEveryScheduledPairInBothTables() throws {
        let databaseURL = try makeDatabase(
            imageIDs: [1, 2, 3],
            matches: [(pairID(1, 2), 5)],
            verified: [(pairID(1, 2), 3)]
        )
        let schedule = makeSchedule(
            imageIDs: [1, 2, 3],
            pairs: [(1, 2, .local), (2, 3, .local)]
        )

        XCTAssertThrowsError(
            try ColmapPairGraphInspector(databaseURL: databaseURL).inspect(
                schedule: schedule,
                completion: .succeeded
            )
        ) { error in
            XCTAssertEqual(
                error as? ColmapPairGraphInspectorError,
                .incompleteSuccessfulAttempt(
                    table: "matches",
                    missingPairIDs: [pairID(2, 3)]
                )
            )
        }
    }

    func testFailedAttemptAcceptsAValidPartialSchedule() throws {
        let databaseURL = try makeDatabase(
            imageIDs: [1, 2, 3],
            matches: [(pairID(1, 2), 5)],
            verified: [(pairID(1, 2), 3)]
        )
        let schedule = makeSchedule(
            imageIDs: [1, 2, 3],
            pairs: [(1, 2, .local), (2, 3, .local)]
        )

        let result = try ColmapPairGraphInspector(databaseURL: databaseURL).inspect(
            schedule: schedule,
            completion: .failed
        )

        XCTAssertEqual(result.scheduledPairCount, 2)
        XCTAssertEqual(result.attemptedPairCount, 1)
        XCTAssertEqual(result.rawMatchedPairCount, 1)
        XCTAssertEqual(result.spatiallyVerifiedPairCount, 1)
        XCTAssertEqual(result.connectedComponentCount, 2)
        XCTAssertEqual(result.isolatedViewCount, 1)
    }

    func testFailedAttemptCountsTheUnionOfBothResultTables() throws {
        let databaseURL = try makeDatabase(
            imageIDs: [1, 2, 3],
            matches: [(pairID(1, 2), 5)],
            verified: [(pairID(2, 3), 0)]
        )
        let schedule = makeSchedule(
            imageIDs: [1, 2, 3],
            pairs: [(1, 2, .local), (2, 3, .local)]
        )

        let result = try ColmapPairGraphInspector(databaseURL: databaseURL).inspect(
            schedule: schedule,
            completion: .failed
        )

        XCTAssertEqual(result.attemptedPairCount, 2)
        XCTAssertEqual(result.rawMatchedPairCount, 1)
        XCTAssertEqual(result.spatiallyVerifiedPairCount, 0)
    }

    func testSuccessfulAttemptAlsoRequiresCompleteVerifiedTable() throws {
        let databaseURL = try makeDatabase(
            imageIDs: [1, 2, 3],
            matches: [(pairID(1, 2), 5), (pairID(2, 3), 0)],
            verified: [(pairID(1, 2), 3)]
        )
        let schedule = makeSchedule(
            imageIDs: [1, 2, 3],
            pairs: [(1, 2, .local), (2, 3, .local)]
        )

        XCTAssertThrowsError(
            try ColmapPairGraphInspector(databaseURL: databaseURL).inspect(
                schedule: schedule,
                completion: .succeeded
            )
        ) { error in
            XCTAssertEqual(
                error as? ColmapPairGraphInspectorError,
                .incompleteSuccessfulAttempt(
                    table: "two_view_geometries",
                    missingPairIDs: [pairID(2, 3)]
                )
            )
        }
    }

    func testRejectsDatabaseImageSetMismatch() throws {
        let databaseURL = try makeDatabase(imageIDs: [1, 2, 4], matches: [], verified: [])
        let schedule = makeSchedule(imageIDs: [1, 2, 3], pairs: [])

        XCTAssertThrowsError(
            try ColmapPairGraphInspector(databaseURL: databaseURL).inspect(
                schedule: schedule,
                completion: .failed
            )
        ) { error in
            XCTAssertEqual(
                error as? ColmapPairGraphInspectorError,
                .imageSetMismatch(
                    expected: [imageName(1), imageName(2), imageName(3)],
                    actual: [imageName(1), imageName(2), imageName(4)]
                )
            )
        }
    }

    func testRejectsDuplicateDatabaseImageIDWithoutTrapping() throws {
        let databaseURL = try makeDuplicateImageIDDatabase()
        let schedule = ColmapPairSchedule(
            imageNames: ["a.jpg", "b.jpg"],
            pairs: []
        )

        XCTAssertThrowsError(
            try ColmapPairGraphInspector(databaseURL: databaseURL).inspect(
                schedule: schedule,
                completion: .failed
            )
        ) { error in
            XCTAssertEqual(
                error as? ColmapPairGraphInspectorError,
                .duplicateDatabaseImageID(1)
            )
        }
    }

    func testRejectsPairOutsideSchedule() throws {
        let databaseURL = try makeDatabase(
            imageIDs: [1, 2, 3],
            matches: [(pairID(1, 3), 4)],
            verified: []
        )
        let schedule = makeSchedule(imageIDs: [1, 2, 3], pairs: [(1, 2, .local)])

        XCTAssertThrowsError(
            try ColmapPairGraphInspector(databaseURL: databaseURL).inspect(
                schedule: schedule,
                completion: .failed
            )
        ) { error in
            XCTAssertEqual(
                error as? ColmapPairGraphInspectorError,
                .pairOutsideSchedule(table: "matches", pairID: pairID(1, 3))
            )
        }
    }

    func testRejectsPairContainingUnknownImage() throws {
        let databaseURL = try makeDatabase(
            imageIDs: [1, 2],
            matches: [(pairID(1, 99), 4)],
            verified: []
        )
        let schedule = makeSchedule(imageIDs: [1, 2], pairs: [(1, 2, .local)])

        XCTAssertThrowsError(
            try ColmapPairGraphInspector(databaseURL: databaseURL).inspect(
                schedule: schedule,
                completion: .failed
            )
        ) { error in
            XCTAssertEqual(
                error as? ColmapPairGraphInspectorError,
                .unknownImageID(table: "matches", pairID: pairID(1, 99), imageID: 99)
            )
        }
    }

    func testRejectsInvalidEncodedPairID() throws {
        let databaseURL = try makeDatabase(
            imageIDs: [1, 2],
            matches: [(0, 4)],
            verified: []
        )
        let schedule = makeSchedule(imageIDs: [1, 2], pairs: [(1, 2, .local)])

        XCTAssertThrowsError(
            try ColmapPairGraphInspector(databaseURL: databaseURL).inspect(
                schedule: schedule,
                completion: .failed
            )
        ) { error in
            XCTAssertEqual(
                error as? ColmapPairGraphInspectorError,
                .invalidPairID(table: "matches", pairID: 0)
            )
        }
    }

    func testRejectsNegativeRowCount() throws {
        let databaseURL = try makeDatabase(
            imageIDs: [1, 2],
            matches: [(pairID(1, 2), -1)],
            verified: []
        )
        let schedule = makeSchedule(imageIDs: [1, 2], pairs: [(1, 2, .local)])

        XCTAssertThrowsError(
            try ColmapPairGraphInspector(databaseURL: databaseURL).inspect(
                schedule: schedule,
                completion: .failed
            )
        ) { error in
            XCTAssertEqual(
                error as? ColmapPairGraphInspectorError,
                .negativeRows(table: "matches", pairID: pairID(1, 2), rows: -1)
            )
        }
    }

    func testRejectsVerifiedRowsGreaterThanRawRows() throws {
        let databaseURL = try makeDatabase(
            imageIDs: [1, 2],
            matches: [(pairID(1, 2), 3)],
            verified: [(pairID(1, 2), 4)]
        )
        let schedule = makeSchedule(imageIDs: [1, 2], pairs: [(1, 2, .local)])

        XCTAssertThrowsError(
            try ColmapPairGraphInspector(databaseURL: databaseURL).inspect(
                schedule: schedule,
                completion: .succeeded
            )
        ) { error in
            XCTAssertEqual(
                error as? ColmapPairGraphInspectorError,
                .verifiedRowsExceedRaw(pairID: pairID(1, 2), verifiedRows: 4, rawRows: 3)
            )
        }
    }

    func testRejectsMalformedMatchSchema() throws {
        let databaseURL = try makeDatabase(
            imageIDs: [1, 2],
            matches: [],
            verified: [],
            matchesHasRowsColumn: false
        )
        let schedule = makeSchedule(imageIDs: [1, 2], pairs: [(1, 2, .local)])

        XCTAssertThrowsError(
            try ColmapPairGraphInspector(databaseURL: databaseURL).inspect(
                schedule: schedule,
                completion: .failed
            )
        ) { error in
            guard case .malformedSchema(let table, _) = error as? ColmapPairGraphInspectorError else {
                return XCTFail("Expected malformed schema, got \(error)")
            }
            XCTAssertEqual(table, "matches")
        }
    }

    func testRejectsDuplicateScheduledPair() throws {
        let databaseURL = try makeDatabase(imageIDs: [1, 2], matches: [], verified: [])
        let schedule = makeSchedule(
            imageIDs: [1, 2],
            pairs: [(1, 2, .local), (2, 1, .retrieval)]
        )

        XCTAssertThrowsError(
            try ColmapPairGraphInspector(databaseURL: databaseURL).inspect(
                schedule: schedule,
                completion: .failed
            )
        ) { error in
            XCTAssertEqual(
                error as? ColmapPairGraphInspectorError,
                .duplicateScheduledPair(imageName(1), imageName(2))
            )
        }
    }

    func testCancellationIsCheckedBeforeDatabaseInspection() async throws {
        let databaseURL = try makeDatabase(imageIDs: [1, 2], matches: [], verified: [])
        let schedule = makeSchedule(imageIDs: [1, 2], pairs: [(1, 2, .local)])
        let task = Task.detached {
            withUnsafeCurrentTask { $0?.cancel() }
            return try ColmapPairGraphInspector(databaseURL: databaseURL).inspect(
                schedule: schedule,
                completion: .failed
            )
        }

        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {
        } catch {
            XCTFail("Expected CancellationError, got \(error)")
        }
    }

    private func pairID(_ first: Int, _ second: Int) -> Int64 {
        let low = Int64(min(first, second))
        let high = Int64(max(first, second))
        return low * ColmapPairGraphInspector.pairIDDivisor + high
    }

    private func imageName(_ imageID: Int) -> String {
        "image-\(imageID).jpg"
    }

    private func makeSchedule(
        imageIDs: [Int],
        pairs: [(Int, Int, ColmapPairRole)]
    ) -> ColmapPairSchedule {
        ColmapPairSchedule(
            imageNames: imageIDs.map(imageName),
            pairs: pairs.map { first, second, role in
                ColmapScheduledPair(imageName(first), imageName(second), role: role)
            }
        )
    }

    private func makeDatabase(
        imageIDs: [Int],
        matches: [(Int64, Int64)],
        verified: [(Int64, Int64)],
        matchesHasRowsColumn: Bool = true
    ) throws -> URL {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: directory)
        }
        let databaseURL = directory.appendingPathComponent("database.db")

        var database: OpaquePointer?
        XCTAssertEqual(sqlite3_open(databaseURL.path, &database), SQLITE_OK)
        guard let database else {
            throw NSError(domain: "ColmapPairGraphInspectorTests", code: 1)
        }
        defer { sqlite3_close(database) }

        try execute(database, "CREATE TABLE cameras(camera_id INTEGER PRIMARY KEY);")
        try execute(
            database,
            "CREATE TABLE images(image_id INTEGER PRIMARY KEY, name TEXT, camera_id INTEGER);"
        )
        try execute(
            database,
            "CREATE TABLE keypoints(image_id INTEGER PRIMARY KEY, rows INTEGER, cols INTEGER, data BLOB);"
        )
        try execute(
            database,
            "CREATE TABLE descriptors(image_id INTEGER PRIMARY KEY, rows INTEGER, cols INTEGER, data BLOB);"
        )
        if matchesHasRowsColumn {
            try execute(
                database,
                "CREATE TABLE matches(pair_id INTEGER PRIMARY KEY, rows INTEGER, cols INTEGER, data BLOB);"
            )
        } else {
            try execute(database, "CREATE TABLE matches(pair_id INTEGER PRIMARY KEY, data BLOB);")
        }
        try execute(
            database,
            "CREATE TABLE two_view_geometries(pair_id INTEGER PRIMARY KEY, rows INTEGER, cols INTEGER, data BLOB);"
        )

        try execute(database, "INSERT INTO cameras(camera_id) VALUES (1);")
        for imageID in imageIDs {
            try execute(
                database,
                "INSERT INTO images(image_id, name, camera_id) VALUES (\(imageID), '\(imageName(imageID))', 1);"
            )
            try execute(
                database,
                "INSERT INTO keypoints(image_id, rows, cols, data) VALUES (\(imageID), 1, 4, X'00');"
            )
            try execute(
                database,
                "INSERT INTO descriptors(image_id, rows, cols, data) VALUES (\(imageID), 1, 128, X'00');"
            )
        }
        guard matchesHasRowsColumn else { return databaseURL }

        for (encodedPair, rows) in matches {
            try execute(
                database,
                "INSERT INTO matches(pair_id, rows, cols, data) VALUES (\(encodedPair), \(rows), 2, X'00');"
            )
        }
        for (encodedPair, rows) in verified {
            try execute(
                database,
                "INSERT INTO two_view_geometries(pair_id, rows, cols, data) VALUES (\(encodedPair), \(rows), 2, X'00');"
            )
        }
        return databaseURL
    }

    private func makeDuplicateImageIDDatabase() throws -> URL {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let databaseURL = directory.appendingPathComponent("database.db")

        var database: OpaquePointer?
        XCTAssertEqual(sqlite3_open(databaseURL.path, &database), SQLITE_OK)
        guard let database else {
            throw NSError(domain: "ColmapPairGraphInspectorTests", code: 1)
        }
        defer { sqlite3_close(database) }
        try execute(database, "CREATE TABLE images(image_id INTEGER, name TEXT);")
        try execute(database, "CREATE TABLE matches(pair_id INTEGER, rows INTEGER);")
        try execute(database, "CREATE TABLE two_view_geometries(pair_id INTEGER, rows INTEGER);")
        try execute(database, "INSERT INTO images(image_id, name) VALUES (1, 'a.jpg');")
        try execute(database, "INSERT INTO images(image_id, name) VALUES (1, 'b.jpg');")
        return databaseURL
    }

    private func execute(_ database: OpaquePointer, _ sql: String) throws {
        var message: UnsafeMutablePointer<CChar>?
        let result = sqlite3_exec(database, sql, nil, nil, &message)
        defer { sqlite3_free(message) }
        guard result == SQLITE_OK else {
            let detail =
                message.map { String(cString: $0) }
                ?? String(cString: sqlite3_errmsg(database))
            throw NSError(
                domain: "ColmapPairGraphInspectorTests",
                code: Int(result),
                userInfo: [NSLocalizedDescriptionKey: detail]
            )
        }
    }
}
#endif
