import CryptoKit
import Foundation
import SQLite3

struct ColmapDatabaseDigests: Sendable, Equatable {
    let feature: String
    let matching: String
}

enum ColmapDatabaseDigesterError: Error, LocalizedError, Equatable {
    case unsafeDatabase
    case openFailed(code: Int32, message: String)
    case operationFailed(operation: String, code: Int32, message: String)
    case invalidTable(String)

    var errorDescription: String? {
        switch self {
        case .unsafeDatabase:
            return "The COLMAP database must be a plain regular file."
        case let .openFailed(code, message):
            return "Could not open the COLMAP database (SQLite \(code)): \(message)"
        case let .operationFailed(operation, code, message):
            return "Could not \(operation) in the COLMAP database (SQLite \(code)): \(message)"
        case .invalidTable(let table):
            return "The COLMAP database has an invalid or missing \(table) table."
        }
    }
}

enum ColmapDatabaseDigester {
    private struct Table {
        let name: String
        let orderingColumn: String
    }

    private static let featureTables = [
        Table(name: "cameras", orderingColumn: "camera_id"),
        Table(name: "images", orderingColumn: "image_id"),
        Table(name: "keypoints", orderingColumn: "image_id"),
        Table(name: "descriptors", orderingColumn: "image_id"),
    ]
    private static let matchingTables = [
        Table(name: "matches", orderingColumn: "pair_id"),
        Table(name: "two_view_geometries", orderingColumn: "pair_id"),
    ]

    static func digests(at databaseURL: URL) throws -> ColmapDatabaseDigests {
        let handle: ColmapSQLiteDatabaseHandle
        do {
            handle = try ColmapSQLiteDatabaseHandle.open(
                at: databaseURL,
                flags: SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX
            )
        } catch {
            throw mapped(error)
        }
        let database = handle.database

        sqlite3_extended_result_codes(database, 1)
        let timeoutResult = sqlite3_busy_timeout(database, 5_000)
        guard timeoutResult == SQLITE_OK else {
            throw ColmapDatabaseDigesterError.operationFailed(
                operation: "set the read timeout",
                code: timeoutResult,
                message: String(cString: sqlite3_errmsg(database))
            )
        }
        try execute(
            "PRAGMA query_only = ON;",
            operation: "enable query-only mode",
            in: database
        )
        try execute(
            "BEGIN DEFERRED TRANSACTION;",
            operation: "begin the database digest snapshot",
            in: database
        )
        var transactionIsOpen = true
        defer {
            if transactionIsOpen {
                sqlite3_exec(database, "ROLLBACK;", nil, nil, nil)
            }
        }
        let result = try digests(in: database)
        try execute(
            "COMMIT;",
            operation: "commit the database digest snapshot",
            in: database
        )
        transactionIsOpen = false
        do {
            try handle.verifyUnchanged()
        } catch {
            throw mapped(error)
        }
        return result
    }

    private static func mapped(_ error: Error) -> ColmapDatabaseDigesterError {
        switch error as? ColmapSQLiteDatabaseHandleError {
        case .unsafeDatabaseFile:
            return .unsafeDatabase
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

    static func digests(in database: OpaquePointer) throws -> ColmapDatabaseDigests {
        try Task.checkCancellation()
        return ColmapDatabaseDigests(
            feature: try digest(featureTables, in: database),
            matching: try digest(matchingTables, in: database)
        )
    }

    private static func digest(
        _ tables: [Table],
        in database: OpaquePointer
    ) throws -> String {
        var hasher = SHA256()
        update("EasySplat COLMAP logical database digest v1", hasher: &hasher)
        for table in tables {
            try Task.checkCancellation()
            let columns = try readColumns(for: table, in: database)
            update(table.name, hasher: &hasher)
            update(Int64(columns.count), hasher: &hasher)
            for column in columns {
                update(column, hasher: &hasher)
            }

            var statement: OpaquePointer?
            let sql = "SELECT * FROM \(table.name) ORDER BY \(table.orderingColumn);"
            let prepareResult = sqlite3_prepare_v2(database, sql, -1, &statement, nil)
            guard prepareResult == SQLITE_OK, let statement else {
                throw ColmapDatabaseDigesterError.operationFailed(
                    operation: "read the \(table.name) table",
                    code: prepareResult,
                    message: String(cString: sqlite3_errmsg(database))
                )
            }
            defer { sqlite3_finalize(statement) }

            var rowCount: Int64 = 0
            while true {
                try Task.checkCancellation()
                let stepResult = sqlite3_step(statement)
                if stepResult == SQLITE_DONE { break }
                guard stepResult == SQLITE_ROW else {
                    throw ColmapDatabaseDigesterError.operationFailed(
                        operation: "read the \(table.name) table",
                        code: stepResult,
                        message: String(cString: sqlite3_errmsg(database))
                    )
                }
                update(UInt8(0x7f), hasher: &hasher)
                for index in 0..<Int32(columns.count) {
                    try updateColumn(index, from: statement, hasher: &hasher)
                }
                rowCount += 1
            }
            update(rowCount, hasher: &hasher)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func readColumns(
        for table: Table,
        in database: OpaquePointer
    ) throws -> [String] {
        var statement: OpaquePointer?
        let prepareResult = sqlite3_prepare_v2(
            database,
            "PRAGMA table_info(\(table.name));",
            -1,
            &statement,
            nil
        )
        guard prepareResult == SQLITE_OK, let statement else {
            throw ColmapDatabaseDigesterError.invalidTable(table.name)
        }
        defer { sqlite3_finalize(statement) }

        var columns: [String] = []
        while true {
            let stepResult = sqlite3_step(statement)
            if stepResult == SQLITE_DONE { break }
            guard stepResult == SQLITE_ROW,
                  sqlite3_column_type(statement, 1) == SQLITE_TEXT,
                  let bytes = sqlite3_column_text(statement, 1) else {
                throw ColmapDatabaseDigesterError.invalidTable(table.name)
            }
            let name = String(cString: bytes)
            guard !name.isEmpty,
                  name.utf8.allSatisfy({ byte in
                      (48...57).contains(byte)
                          || (65...90).contains(byte)
                          || (97...122).contains(byte)
                          || byte == 95
                  }) else {
                throw ColmapDatabaseDigesterError.invalidTable(table.name)
            }
            columns.append(name)
        }
        guard !columns.isEmpty,
              columns.contains(table.orderingColumn) else {
            throw ColmapDatabaseDigesterError.invalidTable(table.name)
        }
        return columns
    }

    private static func updateColumn(
        _ index: Int32,
        from statement: OpaquePointer,
        hasher: inout SHA256
    ) throws {
        switch sqlite3_column_type(statement, index) {
        case SQLITE_NULL:
            update(UInt8(0), hasher: &hasher)
        case SQLITE_INTEGER:
            update(UInt8(1), hasher: &hasher)
            update(sqlite3_column_int64(statement, index), hasher: &hasher)
        case SQLITE_FLOAT:
            update(UInt8(2), hasher: &hasher)
            update(sqlite3_column_double(statement, index).bitPattern, hasher: &hasher)
        case SQLITE_TEXT:
            update(UInt8(3), hasher: &hasher)
            try updateBytes(index, from: statement, hasher: &hasher)
        case SQLITE_BLOB:
            update(UInt8(4), hasher: &hasher)
            try updateBytes(index, from: statement, hasher: &hasher)
        default:
            throw ColmapDatabaseDigesterError.invalidTable("column value")
        }
    }

    private static func updateBytes(
        _ index: Int32,
        from statement: OpaquePointer,
        hasher: inout SHA256
    ) throws {
        let count = sqlite3_column_bytes(statement, index)
        guard count >= 0 else {
            throw ColmapDatabaseDigesterError.invalidTable("column payload")
        }
        update(Int64(count), hasher: &hasher)
        guard count > 0 else { return }
        guard let pointer = sqlite3_column_blob(statement, index) else {
            throw ColmapDatabaseDigesterError.invalidTable("column payload")
        }
        hasher.update(data: Data(bytes: pointer, count: Int(count)))
    }

    private static func update(_ value: String, hasher: inout SHA256) {
        let data = Data(value.utf8)
        update(Int64(data.count), hasher: &hasher)
        hasher.update(data: data)
    }

    private static func update(_ value: UInt8, hasher: inout SHA256) {
        var value = value
        hasher.update(data: Data(bytes: &value, count: MemoryLayout.size(ofValue: value)))
    }

    private static func update(_ value: Int64, hasher: inout SHA256) {
        var value = value.littleEndian
        hasher.update(data: Data(bytes: &value, count: MemoryLayout.size(ofValue: value)))
    }

    private static func update(_ value: UInt64, hasher: inout SHA256) {
        var value = value.littleEndian
        hasher.update(data: Data(bytes: &value, count: MemoryLayout.size(ofValue: value)))
    }

    private static func execute(
        _ sql: String,
        operation: String,
        in database: OpaquePointer
    ) throws {
        var message: UnsafeMutablePointer<CChar>?
        let result = sqlite3_exec(database, sql, nil, nil, &message)
        defer { sqlite3_free(message) }
        guard result == SQLITE_OK else {
            let detail = message.map { String(cString: $0) }
                ?? String(cString: sqlite3_errmsg(database))
            throw ColmapDatabaseDigesterError.operationFailed(
                operation: operation,
                code: result,
                message: detail
            )
        }
    }
}
