import Foundation
import SQLite3

enum ColmapDatabaseMatchStoreError: LocalizedError, Equatable {
    case unsafeDatabaseFile
    case openFailed(code: Int32, message: String)
    case operationFailed(operation: String, code: Int32, message: String)

    var errorDescription: String? {
        switch self {
        case .unsafeDatabaseFile:
            return "The COLMAP database must be a plain regular file."
        case let .openFailed(code, message):
            return "Could not open the COLMAP database (SQLite \(code)): \(message)"
        case let .operationFailed(operation, code, message):
            return "Could not \(operation) in the COLMAP database (SQLite \(code)): \(message)"
        }
    }
}

enum ColmapDatabaseMatchStore {
    static func clearMatchingResults(at databaseURL: URL) throws {
        let handle = try openDatabase(at: databaseURL)
        let database = handle.database

        sqlite3_extended_result_codes(database, 1)
        sqlite3_busy_timeout(database, 5_000)

        try execute("BEGIN IMMEDIATE TRANSACTION;", operation: "begin the match reset", in: database)
        do {
            try verifyUnchanged(handle)
            try execute("DELETE FROM matches;", operation: "clear raw matches", in: database)
            try execute(
                "DELETE FROM two_view_geometries;",
                operation: "clear verified matches",
                in: database
            )
            try verifyUnchanged(handle)
            try execute("COMMIT;", operation: "commit the match reset", in: database)
            try verifyUnchanged(handle)
        } catch {
            try? execute("ROLLBACK;", operation: "roll back the match reset", in: database)
            throw error
        }
    }

    private static func openDatabase(at databaseURL: URL) throws -> ColmapSQLiteDatabaseHandle {
        do {
            return try ColmapSQLiteDatabaseHandle.open(
                at: databaseURL,
                flags: SQLITE_OPEN_READWRITE
            )
        } catch {
            throw mapped(error)
        }
    }

    private static func verifyUnchanged(_ handle: ColmapSQLiteDatabaseHandle) throws {
        do {
            try handle.verifyUnchanged()
        } catch {
            throw mapped(error)
        }
    }

    private static func mapped(_ error: Error) -> ColmapDatabaseMatchStoreError {
        switch error as? ColmapSQLiteDatabaseHandleError {
        case .unsafeDatabaseFile:
            return .unsafeDatabaseFile
        case let .openFailed(code, message):
            return .openFailed(code: code, message: message)
        case let .verificationFailed(code, message):
            return .openFailed(
                code: code,
                message: "File identity verification failed: \(message)"
            )
        case nil:
            return .openFailed(code: SQLITE_ERROR, message: error.localizedDescription)
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
