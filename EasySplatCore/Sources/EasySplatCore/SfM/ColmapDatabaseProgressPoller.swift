import Foundation
import SQLite3

/// Reads incremental progress from COLMAP's SQLite database while a matcher is running.
///
/// We intentionally keep this lightweight and tolerant of partially-initialized DBs so the UI can
/// show that work is happening even when COLMAP only logs coarse-grained "block" updates.
struct ColmapDatabaseProgressPoller: Sendable {
    private let databasePath: URL

    init(databasePath: URL) {
        self.databasePath = databasePath
    }

    /// Returns the number of processed image pairs currently present in the database.
    ///
    /// COLMAP schema varies by command/path; we try multiple tables and return the first count
    /// we can read. If the DB exists but tables aren't created yet, returns 0.
    func readProcessedPairCount() throws -> Int {
        var db: OpaquePointer?
        defer { sqlite3_close(db) }

        let rc = sqlite3_open_v2(databasePath.path, &db, SQLITE_OPEN_READONLY, nil)
        guard rc == SQLITE_OK, let db else {
            throw NSError(domain: "ColmapDatabaseProgressPoller", code: Int(rc), userInfo: [
                NSLocalizedDescriptionKey: "Failed to open COLMAP database at \(databasePath.path)"
            ])
        }
        sqlite3_busy_timeout(db, 250)

        if let count = queryCount(db: db, sql: "SELECT COUNT(*) FROM two_view_geometries;") {
            return count
        }
        if let count = queryCount(db: db, sql: "SELECT COUNT(*) FROM matches;") {
            return count
        }
        return 0
    }

    private func queryCount(db: OpaquePointer, sql: String) -> Int? {
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }

        let rc = sqlite3_prepare_v2(db, sql, -1, &statement, nil)
        guard rc == SQLITE_OK, let statement else {
            return nil
        }

        guard sqlite3_step(statement) == SQLITE_ROW else {
            return nil
        }

        let value = sqlite3_column_int64(statement, 0)
        return Int(value)
    }
}
