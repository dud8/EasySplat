import Foundation
import SQLite3

enum ColmapFeatureDatabaseIdentityError: Error, LocalizedError, Equatable {
    case invalidExpectedImageNames
    case unsafeDatabase
    case unsafeSchema(table: String)
    case invalidDatabaseImageName
    case imageSetMismatch(expected: [String], actual: [String])
    case unstableImageID(imageName: String, expected: Int64, actual: Int64)
    case unstableFrameID(imageName: String, expected: Int64)
    case unstablePosePriorID(imageName: String, expected: Int64)
    case unexpectedRelationshipCount(table: String, expected: Int, actual: Int)
    case operationFailed(operation: String, code: Int32, message: String)

    var errorDescription: String? {
        switch self {
        case .invalidExpectedImageNames:
            "The selected image identity list is invalid."
        case .unsafeDatabase:
            "The COLMAP feature database must be a stable ordinary file."
        case .unsafeSchema(let table):
            "The COLMAP feature database has an invalid or unsafe \(table) table."
        case .invalidDatabaseImageName:
            "The COLMAP feature database contains an invalid image name."
        case let .imageSetMismatch(expected, actual):
            "The COLMAP feature database image set changed (expected \(expected.count), found \(actual.count))."
        case let .unstableImageID(imageName, expected, actual):
            "COLMAP image \(imageName) has nondeterministic ID \(actual); expected \(expected)."
        case let .unstableFrameID(imageName, expected):
            "COLMAP image \(imageName) is not bound to deterministic frame ID \(expected)."
        case let .unstablePosePriorID(imageName, expected):
            "COLMAP image \(imageName) has a pose prior not bound to deterministic ID \(expected)."
        case let .unexpectedRelationshipCount(table, expected, actual):
            "The COLMAP feature database has \(actual) \(table) rows; expected \(expected)."
        case let .operationFailed(operation, code, message):
            "Could not \(operation) in the COLMAP feature database (SQLite \(code)): \(message)"
        }
    }
}

/// Verifies the deterministic identity boundary emitted by EasySplat's pinned COLMAP writer.
/// Matching pair IDs encode image IDs, so completion-order IDs cannot be repaired after matching.
enum ColmapFeatureDatabaseIdentityVerifier {
    private static let maximumNameBytes = 4_096

    static func verify(
        databaseURL: URL,
        expectedImageNames: [String],
        checkCancellation: () throws -> Void = { try Task.checkCancellation() }
    ) throws {
        _ = try withVerifiedSnapshot(
            databaseURL: databaseURL,
            expectedImageNames: expectedImageNames,
            checkCancellation: checkCancellation
        ) { _ in () }
    }

    static func withVerifiedSnapshot<Result>(
        databaseURL: URL,
        expectedImageNames: [String],
        checkCancellation: () throws -> Void = { try Task.checkCancellation() },
        body: (OpaquePointer) throws -> Result
    ) throws -> Result {
        let expected = try validatedExpectedNames(expectedImageNames)
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
        let timeout = sqlite3_busy_timeout(database, 5_000)
        guard timeout == SQLITE_OK else {
            throw operationFailure("set the read timeout", code: timeout, database: database)
        }
        try execute(
            "PRAGMA query_only = ON;",
            operation: "enable query-only mode",
            in: database
        )
        try execute("BEGIN TRANSACTION;", operation: "begin identity verification", in: database)
        var transactionIsOpen = true
        defer {
            if transactionIsOpen {
                sqlite3_exec(database, "ROLLBACK;", nil, nil, nil)
            }
        }

        do {
            try checkCancellation()
            try verifyUnchanged(handle)
            try verify(
                in: database,
                expectedImageNames: expected,
                checkCancellation: checkCancellation
            )
            let result = try body(database)
            try checkCancellation()
            try verifyUnchanged(handle)
            try execute("COMMIT;", operation: "commit identity verification", in: database)
            transactionIsOpen = false
            try verifyUnchanged(handle)
            return result
        } catch {
            try? execute("ROLLBACK;", operation: "roll back identity verification", in: database)
            transactionIsOpen = false
            throw error
        }
    }

    private static func verify(
        in database: OpaquePointer,
        expectedImageNames expected: [String],
        checkCancellation: () throws -> Void
    ) throws {
        try validateSchema(database)
        let rows = try readRows(database, checkCancellation: checkCancellation)
        let actual = rows.map(\.name)
        guard actual == expected else {
            throw ColmapFeatureDatabaseIdentityError.imageSetMismatch(
                expected: expected,
                actual: actual
            )
        }

        var posePriorCount = 0
        for (offset, row) in rows.enumerated() {
            try checkCancellation()
            let expectedID = Int64(offset + 1)
            guard row.imageID == expectedID else {
                throw ColmapFeatureDatabaseIdentityError.unstableImageID(
                    imageName: row.name,
                    expected: expectedID,
                    actual: row.imageID
                )
            }
            guard row.frameCount == 1,
                  row.stableFrameCount == 1 else {
                throw ColmapFeatureDatabaseIdentityError.unstableFrameID(
                    imageName: row.name,
                    expected: expectedID
                )
            }
            guard row.posePriorCount == 0 || row.posePriorCount == 1,
                  row.stablePosePriorCount == row.posePriorCount else {
                throw ColmapFeatureDatabaseIdentityError.unstablePosePriorID(
                    imageName: row.name,
                    expected: expectedID
                )
            }
            posePriorCount += row.posePriorCount
        }
        try requireCount("frames", expected: rows.count, in: database)
        try requireCount("frame_data", expected: rows.count, in: database)
        try requireCount("pose_priors", expected: posePriorCount, in: database)
    }

    private struct Row {
        let imageID: Int64
        let name: String
        let frameCount: Int
        let stableFrameCount: Int
        let posePriorCount: Int
        let stablePosePriorCount: Int
    }

    private static func validatedExpectedNames(_ names: [String]) throws -> [String] {
        guard names.count >= 2,
              Set(names).count == names.count,
              names.allSatisfy({ name in
                  !name.isEmpty
                      && name.utf8.count <= maximumNameBytes
                      && !name.contains("\0")
              }) else {
            throw ColmapFeatureDatabaseIdentityError.invalidExpectedImageNames
        }
        return names.sorted { lhs, rhs in
            lhs.utf8.lexicographicallyPrecedes(rhs.utf8)
        }
    }

    private static func readRows(
        _ database: OpaquePointer,
        checkCancellation: () throws -> Void
    ) throws -> [Row] {
        let sql =
            "SELECT i.image_id, i.name, "
            + "(SELECT COUNT(*) FROM frame_data f WHERE f.data_id = i.image_id "
            + "AND f.sensor_type = 0), "
            + "(SELECT COUNT(*) FROM frame_data f WHERE f.data_id = i.image_id "
            + "AND f.sensor_type = 0 AND f.frame_id = i.image_id), "
            + "(SELECT COUNT(*) FROM pose_priors p WHERE p.corr_data_id = i.image_id), "
            + "(SELECT COUNT(*) FROM pose_priors p WHERE p.corr_data_id = i.image_id "
            + "AND p.pose_prior_id = i.image_id) "
            + "FROM images i ORDER BY i.name COLLATE BINARY;"
        let statement = try prepare(sql, operation: "read deterministic identities", in: database)
        defer { sqlite3_finalize(statement) }
        var rows: [Row] = []
        while true {
            try checkCancellation()
            let result = sqlite3_step(statement)
            if result == SQLITE_DONE { break }
            guard result == SQLITE_ROW,
                  sqlite3_column_type(statement, 0) == SQLITE_INTEGER,
                  sqlite3_column_type(statement, 1) == SQLITE_TEXT,
                  (2...5).allSatisfy({
                      sqlite3_column_type(statement, Int32($0)) == SQLITE_INTEGER
                  }),
                  let nameBytes = sqlite3_column_text(statement, 1) else {
                throw operationFailure(
                    "read deterministic identities",
                    code: result,
                    database: database
                )
            }
            let byteCount = Int(sqlite3_column_bytes(statement, 1))
            let bytes = UnsafeBufferPointer(start: nameBytes, count: byteCount)
            guard byteCount > 0,
                  byteCount <= maximumNameBytes,
                  !bytes.contains(0),
                  let name = String(bytes: bytes, encoding: .utf8) else {
                throw ColmapFeatureDatabaseIdentityError.invalidDatabaseImageName
            }
            rows.append(Row(
                imageID: sqlite3_column_int64(statement, 0),
                name: name,
                frameCount: Int(sqlite3_column_int64(statement, 2)),
                stableFrameCount: Int(sqlite3_column_int64(statement, 3)),
                posePriorCount: Int(sqlite3_column_int64(statement, 4)),
                stablePosePriorCount: Int(sqlite3_column_int64(statement, 5))
            ))
        }
        return rows
    }

    private static func validateSchema(_ database: OpaquePointer) throws {
        let required: [(String, [String: String])] = [
            ("images", ["image_id": "INTEGER", "name": "TEXT"]),
            ("frames", ["frame_id": "INTEGER"]),
            (
                "frame_data",
                ["frame_id": "INTEGER", "data_id": "INTEGER", "sensor_type": "INTEGER"]
            ),
            (
                "pose_priors",
                ["pose_prior_id": "INTEGER", "corr_data_id": "INTEGER"]
            ),
        ]
        for (table, expectedColumns) in required {
            let statement = try prepare(
                "PRAGMA table_info(\(table));",
                operation: "inspect the \(table) schema",
                in: database
            )
            var columns: [String: String] = [:]
            while true {
                let result = sqlite3_step(statement)
                if result == SQLITE_DONE { break }
                guard result == SQLITE_ROW,
                      sqlite3_column_type(statement, 1) == SQLITE_TEXT,
                      sqlite3_column_type(statement, 2) == SQLITE_TEXT,
                      let nameBytes = sqlite3_column_text(statement, 1),
                      let typeBytes = sqlite3_column_text(statement, 2) else {
                    sqlite3_finalize(statement)
                    throw ColmapFeatureDatabaseIdentityError.unsafeSchema(table: table)
                }
                let name = String(cString: nameBytes)
                guard columns.updateValue(
                    String(cString: typeBytes).uppercased(),
                    forKey: name
                ) == nil else {
                    sqlite3_finalize(statement)
                    throw ColmapFeatureDatabaseIdentityError.unsafeSchema(table: table)
                }
            }
            sqlite3_finalize(statement)
            guard expectedColumns.allSatisfy({ columns[$0.key] == $0.value }) else {
                throw ColmapFeatureDatabaseIdentityError.unsafeSchema(table: table)
            }
        }
    }

    private static func requireCount(
        _ table: String,
        expected: Int,
        in database: OpaquePointer
    ) throws {
        let statement = try prepare(
            "SELECT COUNT(*) FROM \(table);",
            operation: "count \(table)",
            in: database
        )
        defer { sqlite3_finalize(statement) }
        let result = sqlite3_step(statement)
        guard result == SQLITE_ROW,
              sqlite3_column_type(statement, 0) == SQLITE_INTEGER else {
            throw operationFailure("count \(table)", code: result, database: database)
        }
        let actual = Int(sqlite3_column_int64(statement, 0))
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw operationFailure("finish counting \(table)", database: database)
        }
        guard actual == expected else {
            throw ColmapFeatureDatabaseIdentityError.unexpectedRelationshipCount(
                table: table,
                expected: expected,
                actual: actual
            )
        }
    }

    private static func verifyUnchanged(_ handle: ColmapSQLiteDatabaseHandle) throws {
        do {
            try handle.verifyUnchanged()
        } catch {
            throw mapped(error)
        }
    }

    private static func mapped(_ error: Error) -> ColmapFeatureDatabaseIdentityError {
        switch error as? ColmapSQLiteDatabaseHandleError {
        case .unsafeDatabaseFile:
            .unsafeDatabase
        case let .openFailed(code, message), let .verificationFailed(code, message):
            .operationFailed(operation: "open the database", code: code, message: message)
        case nil:
            .operationFailed(
                operation: "open the database",
                code: SQLITE_ERROR,
                message: error.localizedDescription
            )
        }
    }

    private static func prepare(
        _ sql: String,
        operation: String,
        in database: OpaquePointer
    ) throws -> OpaquePointer {
        var statement: OpaquePointer?
        let result = sqlite3_prepare_v2(database, sql, -1, &statement, nil)
        guard result == SQLITE_OK, let statement else {
            throw operationFailure(operation, code: result, database: database)
        }
        return statement
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
            throw ColmapFeatureDatabaseIdentityError.operationFailed(
                operation: operation,
                code: result,
                message: message.map { String(cString: $0) }
                    ?? String(cString: sqlite3_errmsg(database))
            )
        }
    }

    private static func operationFailure(
        _ operation: String,
        code: Int32? = nil,
        database: OpaquePointer
    ) -> ColmapFeatureDatabaseIdentityError {
        .operationFailed(
            operation: operation,
            code: code ?? sqlite3_extended_errcode(database),
            message: String(cString: sqlite3_errmsg(database))
        )
    }
}
