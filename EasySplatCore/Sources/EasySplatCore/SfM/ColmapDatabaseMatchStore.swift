import Foundation
import SQLite3

enum ColmapDatabaseMatchStoreError: LocalizedError, Equatable {
    case unsafeDatabaseFile
    case openFailed(code: Int32, message: String)
    case operationFailed(operation: String, code: Int32, message: String)
    case matchingResultsNotEmpty(rawMatchCount: Int64, verifiedMatchCount: Int64)

    var errorDescription: String? {
        switch self {
        case .unsafeDatabaseFile:
            return "The COLMAP database must be a plain regular file."
        case let .openFailed(code, message):
            return "Could not open the COLMAP database (SQLite \(code)): \(message)"
        case let .operationFailed(operation, code, message):
            return "Could not \(operation) in the COLMAP database (SQLite \(code)): \(message)"
        case let .matchingResultsNotEmpty(rawMatchCount, verifiedMatchCount):
            return "COLMAP matching requires an empty result database, but found \(rawMatchCount) raw and \(verifiedMatchCount) verified match rows."
        }
    }
}

enum ColmapDatabaseMatchStore {
    static func requireMatchingResultsEmpty(at databaseURL: URL) throws {
        let handle = try openDatabase(
            at: databaseURL,
            flags: SQLITE_OPEN_READONLY
        )
        try verifyUnchanged(handle)
        try requireMatchingResultsEmpty(in: handle.database)
        try verifyUnchanged(handle)
    }

    static func clearMatchingResults(at databaseURL: URL) throws {
        let handle = try openDatabase(
            at: databaseURL,
            flags: SQLITE_OPEN_READWRITE
        )
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
            try requireMatchingResultsEmpty(in: database)
            try verifyUnchanged(handle)
            try execute("COMMIT;", operation: "commit the match reset", in: database)
        } catch {
            try? execute("ROLLBACK;", operation: "roll back the match reset", in: database)
            throw error
        }
        try verifyUnchanged(handle)
        try requireMatchingResultsEmpty(in: database)
        try verifyUnchanged(handle)
    }

    private static func openDatabase(
        at databaseURL: URL,
        flags: Int32
    ) throws -> ColmapSQLiteDatabaseHandle {
        do {
            return try ColmapSQLiteDatabaseHandle.open(
                at: databaseURL,
                flags: flags
            )
        } catch {
            throw mapped(error)
        }
    }

    private static func requireMatchingResultsEmpty(
        in database: OpaquePointer
    ) throws {
        let counts = try matchingResultCounts(in: database)
        guard counts.raw == 0, counts.verified == 0 else {
            throw ColmapDatabaseMatchStoreError.matchingResultsNotEmpty(
                rawMatchCount: counts.raw,
                verifiedMatchCount: counts.verified
            )
        }
    }

    private static func matchingResultCounts(
        in database: OpaquePointer
    ) throws -> (raw: Int64, verified: Int64) {
        let sql = "SELECT (SELECT COUNT(*) FROM matches),"
            + " (SELECT COUNT(*) FROM two_view_geometries);"
        var statement: OpaquePointer?
        let prepareResult = sqlite3_prepare_v2(database, sql, -1, &statement, nil)
        guard prepareResult == SQLITE_OK, let statement else {
            throw operationError(
                operation: "count matching results",
                code: prepareResult,
                in: database
            )
        }
        defer { sqlite3_finalize(statement) }

        let rowResult = sqlite3_step(statement)
        guard rowResult == SQLITE_ROW,
              sqlite3_column_count(statement) == 2,
              sqlite3_column_type(statement, 0) == SQLITE_INTEGER,
              sqlite3_column_type(statement, 1) == SQLITE_INTEGER else {
            throw operationError(
                operation: "count matching results",
                code: rowResult,
                in: database
            )
        }
        let raw = sqlite3_column_int64(statement, 0)
        let verified = sqlite3_column_int64(statement, 1)
        let completionResult = sqlite3_step(statement)
        guard completionResult == SQLITE_DONE, raw >= 0, verified >= 0 else {
            throw operationError(
                operation: "count matching results",
                code: completionResult,
                in: database
            )
        }
        return (raw, verified)
    }

    private static func operationError(
        operation: String,
        code: Int32,
        in database: OpaquePointer
    ) -> ColmapDatabaseMatchStoreError {
        ColmapDatabaseMatchStoreError.operationFailed(
            operation: operation,
            code: code,
            message: String(cString: sqlite3_errmsg(database))
        )
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
