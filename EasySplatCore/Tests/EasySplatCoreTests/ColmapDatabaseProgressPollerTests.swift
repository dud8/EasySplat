#if canImport(XCTest)
import SQLite3
import XCTest
@testable import EasySplatCore

final class ColmapDatabaseProgressPollerTests: XCTestCase {
    func testReadsTwoViewGeometriesCount() throws {
        let dbURL = try makeTempDatabaseURL()
        try createDatabase(at: dbURL) { db in
            try exec(db: db, sql: "CREATE TABLE two_view_geometries(pair_id INTEGER PRIMARY KEY);")
            try exec(db: db, sql: "INSERT INTO two_view_geometries(pair_id) VALUES (1), (2), (3);")
        }

        let poller = ColmapDatabaseProgressPoller(databasePath: dbURL)
        XCTAssertEqual(try poller.readProcessedPairCount(), 3)
    }

    func testFallsBackToMatchesTable() throws {
        let dbURL = try makeTempDatabaseURL()
        try createDatabase(at: dbURL) { db in
            try exec(db: db, sql: "CREATE TABLE matches(pair_id INTEGER PRIMARY KEY);")
            try exec(db: db, sql: "INSERT INTO matches(pair_id) VALUES (10), (11);")
        }

        let poller = ColmapDatabaseProgressPoller(databasePath: dbURL)
        XCTAssertEqual(try poller.readProcessedPairCount(), 2)
    }

    func testReturnsZeroWhenTablesMissing() throws {
        let dbURL = try makeTempDatabaseURL()
        try createDatabase(at: dbURL) { _ in
            // Intentionally empty schema.
        }

        let poller = ColmapDatabaseProgressPoller(databasePath: dbURL)
        XCTAssertEqual(try poller.readProcessedPairCount(), 0)
    }

    private func createColmapSchema(_ db: OpaquePointer) throws {
        try exec(db: db, sql: "CREATE TABLE images(image_id INTEGER PRIMARY KEY);")
        try exec(db: db, sql: "CREATE TABLE keypoints(image_id INTEGER PRIMARY KEY, rows INTEGER);")
    }

    func testReadKeypointStatsAggregatesTotalsAndMinimum() throws {
        let dbURL = try makeTempDatabaseURL()
        try createDatabase(at: dbURL) { db in
            try createColmapSchema(db)
            try exec(db: db, sql: "INSERT INTO images(image_id) VALUES (1), (2), (3);")
            try exec(db: db, sql: "INSERT INTO keypoints(image_id, rows) VALUES (1, 5000), (2, 8000), (3, 200);")
        }

        let stats = try XCTUnwrap(ColmapDatabaseProgressPoller(databasePath: dbURL).readKeypointStats())
        XCTAssertEqual(stats.imageCount, 3)
        XCTAssertEqual(stats.totalKeypoints, 13_200)
        XCTAssertEqual(stats.minKeypoints, 200)
        XCTAssertEqual(stats.averageKeypoints, 4_400)
    }

    func testReadKeypointStatsCountsImagesWithNoKeypointRowAsZero() throws {
        // Image 3 extracted nothing and has no keypoints row: it must still count as a
        // 0-keypoint frame in the minimum and the per-image average.
        let dbURL = try makeTempDatabaseURL()
        try createDatabase(at: dbURL) { db in
            try createColmapSchema(db)
            try exec(db: db, sql: "INSERT INTO images(image_id) VALUES (1), (2), (3);")
            try exec(db: db, sql: "INSERT INTO keypoints(image_id, rows) VALUES (1, 5000), (2, 8000);")
        }

        let stats = try XCTUnwrap(ColmapDatabaseProgressPoller(databasePath: dbURL).readKeypointStats())
        XCTAssertEqual(stats.imageCount, 3)
        XCTAssertEqual(stats.totalKeypoints, 13_000)
        XCTAssertEqual(stats.minKeypoints, 0, "The image with no keypoints row must count as zero.")
        XCTAssertEqual(stats.averageKeypoints, 13_000 / 3)
    }

    func testReadKeypointStatsReturnsNilForEmptyImages() throws {
        let dbURL = try makeTempDatabaseURL()
        try createDatabase(at: dbURL) { db in
            try createColmapSchema(db)
        }

        XCTAssertNil(ColmapDatabaseProgressPoller(databasePath: dbURL).readKeypointStats())
    }

    func testReadKeypointStatsReturnsNilWhenKeypointsTableAbsent() throws {
        // images present but no keypoints table yet: report nothing rather than fake zeros.
        let dbURL = try makeTempDatabaseURL()
        try createDatabase(at: dbURL) { db in
            try exec(db: db, sql: "CREATE TABLE images(image_id INTEGER PRIMARY KEY);")
            try exec(db: db, sql: "INSERT INTO images(image_id) VALUES (1), (2);")
        }

        XCTAssertNil(ColmapDatabaseProgressPoller(databasePath: dbURL).readKeypointStats(),
                     "A missing keypoints table must not report fake zero-keypoint stats.")
    }

    func testReadKeypointStatsReturnsNilForMissingDatabase() {
        let url = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("\(UUID().uuidString).sqlite")
        XCTAssertNil(ColmapDatabaseProgressPoller(databasePath: url).readKeypointStats())
    }

    private func makeTempDatabaseURL() throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("colmap.sqlite")
    }

    private func createDatabase(at url: URL, configure: (OpaquePointer) throws -> Void) throws {
        var db: OpaquePointer?
        defer { sqlite3_close(db) }

        let rc = sqlite3_open(url.path, &db)
        XCTAssertEqual(rc, SQLITE_OK)
        guard let db else {
            XCTFail("Database handle was nil")
            return
        }

        try configure(db)
    }

    private func exec(db: OpaquePointer, sql: String) throws {
        var errMsg: UnsafeMutablePointer<CChar>?
        let rc = sqlite3_exec(db, sql, nil, nil, &errMsg)
        if rc != SQLITE_OK {
            let message = errMsg.map { String(cString: $0) } ?? "unknown error"
            sqlite3_free(errMsg)
            throw NSError(domain: "ColmapDatabaseProgressPollerTests", code: Int(rc), userInfo: [
                NSLocalizedDescriptionKey: message
            ])
        }
    }
}
#endif

