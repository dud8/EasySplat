import Darwin
import Foundation
import SQLite3

enum ColmapDatabaseDurabilityError: Error, LocalizedError, Equatable {
    case unsafeDatabase
    case operationFailed(operation: String, code: Int32, message: String)
    case checkpointBusy(logFrames: Int, checkpointedFrames: Int)
    case unexpectedJournalMode(String)
    case companionRemains(String)
    case syncFailed(operation: String, code: Int32)

    var errorDescription: String? {
        switch self {
        case .unsafeDatabase:
            "The COLMAP database is not a stable ordinary file."
        case let .operationFailed(operation, code, message):
            "Could not \(operation) the COLMAP database (SQLite \(code)): \(message)"
        case let .checkpointBusy(logFrames, checkpointedFrames):
            "The COLMAP database is still in use (\(checkpointedFrames) of \(logFrames) WAL frames checkpointed)."
        case .unexpectedJournalMode(let mode):
            "The COLMAP database remained in the unexpected journal mode \(mode)."
        case .companionRemains(let name):
            "The COLMAP database still has the SQLite companion \(name)."
        case let .syncFailed(operation, code):
            "Could not \(operation) the COLMAP database snapshot (errno \(code))."
        }
    }
}

/// Seals the database at a durable stage boundary after every COLMAP writer has exited.
/// COLMAP uses WAL with synchronous writes disabled while it works; a progress reader can be
/// the last connection to close and leave an empty WAL/SHM pair behind. A checkpoint is not
/// considered durable until SQLite has moved every committed frame into the main file, restored
/// rollback journaling, closed cleanly, and the database plus its directory have been synced.
enum ColmapDatabaseDurability {
    private static let knownSQLiteCompanionSuffixes = ["-journal", "-shm", "-wal"]

    static func seal(at databaseURL: URL) throws {
        try Task.checkCancellation()
        guard databaseURL.isFileURL,
              !databaseURL.lastPathComponent.isEmpty else {
            throw ColmapDatabaseDurabilityError.unsafeDatabase
        }
        if let companion = try firstUnknownCompanion(at: databaseURL) {
            throw ColmapDatabaseDurabilityError.companionRemains(companion)
        }
        try validateKnownCompanions(at: databaseURL)

        let handle: ColmapSQLiteDatabaseHandle
        do {
            handle = try ColmapSQLiteDatabaseHandle.open(
                at: databaseURL,
                flags: SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
            )
        } catch {
            throw mapped(error)
        }
        let database = handle.database
        sqlite3_extended_result_codes(database, 1)
        let timeout = sqlite3_busy_timeout(database, 5_000)
        guard timeout == SQLITE_OK else {
            throw operationError("set the checkpoint timeout", code: timeout, database: database)
        }
        var persistWAL: Int32 = 0
        let persistenceResult = sqlite3_file_control(
            database,
            "main",
            SQLITE_FCNTL_PERSIST_WAL,
            &persistWAL
        )
        guard persistenceResult == SQLITE_OK else {
            throw operationError(
                "disable persistent WAL files",
                code: persistenceResult,
                database: database
            )
        }

        try execute("PRAGMA synchronous = FULL;", operation: "enable durable writes", in: database)
        let checkpoint = try checkpointResult(in: database)
        guard checkpoint.busy == 0,
              checkpoint.logFrames == checkpoint.checkpointedFrames else {
            throw ColmapDatabaseDurabilityError.checkpointBusy(
                logFrames: checkpoint.logFrames,
                checkpointedFrames: checkpoint.checkpointedFrames
            )
        }
        let journalMode = try textResult(
            "PRAGMA journal_mode = DELETE;",
            operation: "restore rollback journaling",
            in: database
        ).lowercased()
        guard journalMode == "delete" else {
            throw ColmapDatabaseDurabilityError.unexpectedJournalMode(journalMode)
        }
        do {
            try handle.verifyUnchanged()
        } catch {
            throw mapped(error)
        }
        let closeResult = handle.close()
        guard closeResult == SQLITE_OK else {
            throw operationError("close the durable snapshot", code: closeResult, database: database)
        }

        if let companion = try firstCompanion(at: databaseURL) {
            throw ColmapDatabaseDurabilityError.companionRemains(companion)
        }
        try syncSnapshot(at: databaseURL)
        try Task.checkCancellation()
    }

    private static func checkpointResult(
        in database: OpaquePointer
    ) throws -> (busy: Int, logFrames: Int, checkpointedFrames: Int) {
        var statement: OpaquePointer?
        let prepare = sqlite3_prepare_v2(
            database,
            "PRAGMA wal_checkpoint(TRUNCATE);",
            -1,
            &statement,
            nil
        )
        guard prepare == SQLITE_OK, let statement else {
            throw operationError("prepare the WAL checkpoint", code: prepare, database: database)
        }
        defer { sqlite3_finalize(statement) }
        let step = sqlite3_step(statement)
        guard step == SQLITE_ROW,
              sqlite3_column_count(statement) == 3,
              (0..<3).allSatisfy({ sqlite3_column_type(statement, Int32($0)) == SQLITE_INTEGER }) else {
            throw operationError("checkpoint the WAL", code: step, database: database)
        }
        let result = (
            busy: Int(sqlite3_column_int64(statement, 0)),
            logFrames: Int(sqlite3_column_int64(statement, 1)),
            checkpointedFrames: Int(sqlite3_column_int64(statement, 2))
        )
        let done = sqlite3_step(statement)
        guard done == SQLITE_DONE else {
            throw operationError("finish the WAL checkpoint", code: done, database: database)
        }
        return result
    }

    private static func textResult(
        _ sql: String,
        operation: String,
        in database: OpaquePointer
    ) throws -> String {
        var statement: OpaquePointer?
        let prepare = sqlite3_prepare_v2(database, sql, -1, &statement, nil)
        guard prepare == SQLITE_OK, let statement else {
            throw operationError(operation, code: prepare, database: database)
        }
        defer { sqlite3_finalize(statement) }
        let step = sqlite3_step(statement)
        guard step == SQLITE_ROW,
              sqlite3_column_count(statement) == 1,
              sqlite3_column_type(statement, 0) == SQLITE_TEXT,
              let bytes = sqlite3_column_text(statement, 0) else {
            throw operationError(operation, code: step, database: database)
        }
        let value = String(cString: bytes)
        let done = sqlite3_step(statement)
        guard done == SQLITE_DONE else {
            throw operationError("finish \(operation)", code: done, database: database)
        }
        return value
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
            throw ColmapDatabaseDurabilityError.operationFailed(
                operation: operation,
                code: result,
                message: message.map { String(cString: $0) }
                    ?? String(cString: sqlite3_errmsg(database))
            )
        }
    }

    private static func firstUnknownCompanion(at databaseURL: URL) throws -> String? {
        try companionNames(at: databaseURL).first { name in
            !knownSQLiteCompanionSuffixes.contains { suffix in
                name == databaseURL.lastPathComponent + suffix
            }
        }
    }

    private static func firstCompanion(at databaseURL: URL) throws -> String? {
        try companionNames(at: databaseURL).first
    }

    private static func validateKnownCompanions(at databaseURL: URL) throws {
        for name in try companionNames(at: databaseURL) {
            let sidecar = databaseURL.deletingLastPathComponent().appendingPathComponent(name)
            var status = stat()
            guard lstat(sidecar.path, &status) == 0,
                  (status.st_mode & S_IFMT) == S_IFREG,
                  status.st_nlink == 1,
                  status.st_uid == geteuid() else {
                throw ColmapDatabaseDurabilityError.unsafeDatabase
            }
        }
    }

    private static func companionNames(at databaseURL: URL) throws -> [String] {
        let parent = databaseURL.deletingLastPathComponent()
        do {
            return try FileManager.default.contentsOfDirectory(atPath: parent.path)
                .filter { $0.hasPrefix(databaseURL.lastPathComponent + "-") }
                .sorted()
        } catch {
            throw ColmapDatabaseDurabilityError.unsafeDatabase
        }
    }

    private static func syncSnapshot(at databaseURL: URL) throws {
        let databaseDescriptor = Darwin.open(
            databaseURL.path,
            O_RDONLY | O_NOFOLLOW | O_CLOEXEC
        )
        guard databaseDescriptor >= 0 else {
            throw ColmapDatabaseDurabilityError.syncFailed(
                operation: "open",
                code: errno
            )
        }
        defer { Darwin.close(databaseDescriptor) }
        var databaseStatus = stat()
        guard fstat(databaseDescriptor, &databaseStatus) == 0,
              (databaseStatus.st_mode & S_IFMT) == S_IFREG,
              databaseStatus.st_nlink == 1,
              databaseStatus.st_uid == geteuid() else {
            throw ColmapDatabaseDurabilityError.unsafeDatabase
        }
        guard fsync(databaseDescriptor) == 0 else {
            throw ColmapDatabaseDurabilityError.syncFailed(
                operation: "sync",
                code: errno
            )
        }

        let parent = databaseURL.deletingLastPathComponent()
        let parentDescriptor = Darwin.open(
            parent.path,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard parentDescriptor >= 0 else {
            throw ColmapDatabaseDurabilityError.syncFailed(
                operation: "open the parent directory for",
                code: errno
            )
        }
        defer { Darwin.close(parentDescriptor) }
        guard fsync(parentDescriptor) == 0 else {
            throw ColmapDatabaseDurabilityError.syncFailed(
                operation: "sync the parent directory for",
                code: errno
            )
        }
    }

    private static func operationError(
        _ operation: String,
        code: Int32,
        database: OpaquePointer
    ) -> ColmapDatabaseDurabilityError {
        .operationFailed(
            operation: operation,
            code: code,
            message: String(cString: sqlite3_errmsg(database))
        )
    }

    private static func mapped(_ error: Error) -> ColmapDatabaseDurabilityError {
        switch error as? ColmapSQLiteDatabaseHandleError {
        case .unsafeDatabaseFile:
            .unsafeDatabase
        case let .openFailed(code, message), let .verificationFailed(code, message):
            .operationFailed(operation: "open", code: code, message: message)
        case nil:
            .operationFailed(
                operation: "open",
                code: SQLITE_ERROR,
                message: error.localizedDescription
            )
        }
    }
}
