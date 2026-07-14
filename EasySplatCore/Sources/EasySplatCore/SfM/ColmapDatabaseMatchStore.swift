import Foundation
import SQLite3

enum ColmapDatabaseMatchStoreError: LocalizedError, Equatable {
    case openFailed(code: Int32, message: String)
    case operationFailed(operation: String, code: Int32, message: String)

    var errorDescription: String? {
        switch self {
        case let .openFailed(code, message):
            return "Could not open the COLMAP database (SQLite \(code)): \(message)"
        case let .operationFailed(operation, code, message):
            return "Could not \(operation) in the COLMAP database (SQLite \(code)): \(message)"
        }
    }
}

enum ColmapDatabaseMatchStore {
    static func clearMatchingResults(at databaseURL: URL) throws {
        var database: OpaquePointer?
        let openResult = sqlite3_open_v2(
            databaseURL.path,
            &database,
            SQLITE_OPEN_READWRITE,
            nil
        )
        guard openResult == SQLITE_OK, let database else {
            let message = database.map { String(cString: sqlite3_errmsg($0)) }
                ?? "unknown SQLite error"
            if let database {
                sqlite3_close(database)
            }
            throw ColmapDatabaseMatchStoreError.openFailed(
                code: openResult,
                message: message
            )
        }
        defer { sqlite3_close(database) }

        sqlite3_extended_result_codes(database, 1)
        sqlite3_busy_timeout(database, 5_000)

        try execute("BEGIN IMMEDIATE TRANSACTION;", operation: "begin the match reset", in: database)
        do {
            try execute("DELETE FROM matches;", operation: "clear raw matches", in: database)
            try execute(
                "DELETE FROM two_view_geometries;",
                operation: "clear verified matches",
                in: database
            )
            try execute("COMMIT;", operation: "commit the match reset", in: database)
        } catch {
            try? execute("ROLLBACK;", operation: "roll back the match reset", in: database)
            throw error
        }
    }

    private static func execute(
        _ sql: String,
        operation: String,
        in database: OpaquePointer
    ) throws {
        var errorMessage: UnsafeMutablePointer<CChar>?
        let result = sqlite3_exec(database, sql, nil, nil, &errorMessage)
        defer { sqlite3_free(errorMessage) }
        guard result == SQLITE_OK else {
            let message = errorMessage.map { String(cString: $0) }
                ?? String(cString: sqlite3_errmsg(database))
            throw ColmapDatabaseMatchStoreError.operationFailed(
                operation: operation,
                code: result,
                message: message
            )
        }
    }
}
