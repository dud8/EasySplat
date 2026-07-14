import Foundation
import SQLite3

struct ColmapPairSchedule: Sendable, Equatable {
    let imageNames: [String]
    let pairs: [ColmapScheduledPair]
}

enum ColmapPairAttemptCompletion: Sendable, Equatable {
    case succeeded
    case failed
}

struct ColmapPairGraphInspection: Sendable, Equatable {
    let scheduledPairCount: Int
    let attemptedPairCount: Int
    let rawMatchedPairCount: Int
    let spatiallyVerifiedPairCount: Int
    let localPairCount: Int
    let retrievalPairCount: Int
    let loopRevisitPairCount: Int
    let connectedComponentCount: Int
    let isolatedViewCount: Int
    let degreeP10: Int
    let degreeMedian: Int
    let degreeP90: Int
    let featureDatabaseDigest: String
    let matchingDatabaseDigest: String
}

enum ColmapPairGraphInspectorError: Error, LocalizedError, Equatable {
    case unsafeDatabaseFile
    case emptyImageSet
    case invalidImageName(String)
    case duplicateImageName(String)
    case scheduledPairUnknownImage(String)
    case scheduledSelfPair(String)
    case duplicateScheduledPair(String, String)
    case invalidImageID(Int64)
    case duplicateDatabaseImageID(Int64)
    case duplicateDatabaseImageName(String)
    case imageSetMismatch(expected: [String], actual: [String])
    case databaseOpenFailed(code: Int32, message: String)
    case databaseOperationFailed(operation: String, code: Int32, message: String)
    case malformedSchema(table: String, message: String)
    case databaseReadFailed(table: String, code: Int32, message: String)
    case invalidPairID(table: String, pairID: Int64)
    case unknownImageID(table: String, pairID: Int64, imageID: Int64)
    case pairOutsideSchedule(table: String, pairID: Int64)
    case tableExceedsSchedule(table: String, rows: Int, scheduledPairs: Int)
    case duplicateDatabasePair(table: String, pairID: Int64)
    case negativeRows(table: String, pairID: Int64, rows: Int64)
    case verifiedRowsExceedRaw(pairID: Int64, verifiedRows: Int64, rawRows: Int64)
    case incompleteSuccessfulAttempt(table: String, missingPairIDs: [Int64])

    var errorDescription: String? {
        switch self {
        case .unsafeDatabaseFile:
            return "The COLMAP database must be a plain regular file."
        case .emptyImageSet:
            return "The pair schedule does not contain any images."
        case .invalidImageName(let name):
            return "The pair schedule contains an invalid image name: \(name)."
        case .duplicateImageName(let name):
            return "The pair schedule contains the image more than once: \(name)."
        case .scheduledPairUnknownImage(let name):
            return "A scheduled pair refers to an unknown image: \(name)."
        case .scheduledSelfPair(let name):
            return "A scheduled pair refers to the same image twice: \(name)."
        case .duplicateScheduledPair(let first, let second):
            return "The pair schedule contains a duplicate pair: \(first) and \(second)."
        case .invalidImageID(let imageID):
            return "The COLMAP database contains an invalid image ID: \(imageID)."
        case .duplicateDatabaseImageID(let imageID):
            return "The COLMAP database contains image ID more than once: \(imageID)."
        case .duplicateDatabaseImageName(let name):
            return "The COLMAP database contains the image name more than once: \(name)."
        case .imageSetMismatch(let expected, let actual):
            return
                "The COLMAP database image set does not match the schedule (expected \(expected), found \(actual))."
        case .databaseOpenFailed(let code, let message):
            return "Could not open the COLMAP database (SQLite \(code)): \(message)"
        case .databaseOperationFailed(let operation, let code, let message):
            return "Could not \(operation) in the COLMAP database (SQLite \(code)): \(message)"
        case .malformedSchema(let table, let message):
            return "The COLMAP \(table) table has an invalid schema: \(message)"
        case .databaseReadFailed(let table, let code, let message):
            return "Could not read the COLMAP \(table) table (SQLite \(code)): \(message)"
        case .invalidPairID(let table, let pairID):
            return "The COLMAP \(table) table contains an invalid pair ID: \(pairID)."
        case .unknownImageID(let table, let pairID, let imageID):
            return "The COLMAP \(table) pair \(pairID) refers to unknown image ID \(imageID)."
        case .pairOutsideSchedule(let table, let pairID):
            return "The COLMAP \(table) pair \(pairID) is outside the attempted schedule."
        case .tableExceedsSchedule(let table, let rows, let scheduledPairs):
            return "The COLMAP \(table) table has \(rows) rows for a \(scheduledPairs)-pair schedule."
        case .duplicateDatabasePair(let table, let pairID):
            return "The COLMAP \(table) table contains pair \(pairID) more than once."
        case .negativeRows(let table, let pairID, let rows):
            return "The COLMAP \(table) pair \(pairID) has a negative row count: \(rows)."
        case .verifiedRowsExceedRaw(let pairID, let verifiedRows, let rawRows):
            return
                "The COLMAP pair \(pairID) has \(verifiedRows) verified rows but only \(rawRows) raw rows."
        case .incompleteSuccessfulAttempt(let table, let missingPairIDs):
            return
                "The successful matching attempt is missing \(table) rows for pair IDs \(missingPairIDs)."
        }
    }
}

struct ColmapPairGraphInspector: Sendable {
    static let pairIDDivisor: Int64 = 2_147_483_647

    private let databaseURL: URL

    init(databaseURL: URL) {
        self.databaseURL = databaseURL
    }

    func inspect(
        schedule: ColmapPairSchedule,
        completion: ColmapPairAttemptCompletion
    ) throws -> ColmapPairGraphInspection {
        try Task.checkCancellation()
        let validatedSchedule = try ValidatedSchedule(schedule)

        let handle = try openDatabase()
        let database = handle.database

        sqlite3_extended_result_codes(database, 1)
        let timeoutResult = sqlite3_busy_timeout(database, 500)
        guard timeoutResult == SQLITE_OK else {
            throw ColmapPairGraphInspectorError.databaseOperationFailed(
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
            operation: "begin the pair-graph snapshot",
            in: database
        )
        var transactionIsOpen = true
        defer {
            if transactionIsOpen {
                sqlite3_exec(database, "ROLLBACK;", nil, nil, nil)
            }
        }

        let inspection: ColmapPairGraphInspection
        let databaseImages = try readImages(from: database)
        try validate(databaseImages, against: validatedSchedule)
        let imageNameByID = Dictionary(
            uniqueKeysWithValues: databaseImages.map {
                ($0.id, $0.name)
            })
        let pairIDByNames = try validatedSchedule.pairIDs(
            imageIDByName: Dictionary(
                uniqueKeysWithValues: databaseImages.map { ($0.name, $0.id) }
            ))
        let scheduledPairIDs = Set(pairIDByNames.values)

        let rawRows = try readPairRows(
            table: "matches",
            scheduledPairIDs: scheduledPairIDs,
            imageNameByID: imageNameByID,
            from: database
        )
        let verifiedRows = try readPairRows(
            table: "two_view_geometries",
            scheduledPairIDs: scheduledPairIDs,
            imageNameByID: imageNameByID,
            from: database
        )

        if completion == .succeeded {
            try requireComplete(
                table: "matches",
                scheduledPairIDs: scheduledPairIDs,
                recordedPairIDs: Set(rawRows.keys)
            )
            try requireComplete(
                table: "two_view_geometries",
                scheduledPairIDs: scheduledPairIDs,
                recordedPairIDs: Set(verifiedRows.keys)
            )
        }

        for (pairID, rows) in verifiedRows {
            try Task.checkCancellation()
            let raw = rawRows[pairID] ?? 0
            guard rows <= raw else {
                throw ColmapPairGraphInspectorError.verifiedRowsExceedRaw(
                    pairID: pairID,
                    verifiedRows: rows,
                    rawRows: raw
                )
            }
        }

        let verifiedPairIDs = Set(
            verifiedRows.compactMap { pairID, rows in
                rows > 0 ? pairID : nil
            })
        let graph = graphStatistics(
            imageIDs: databaseImages.map(\.id),
            verifiedPairIDs: verifiedPairIDs
        )
        let databaseDigests = try ColmapDatabaseDigester.digests(in: database)
        inspection = ColmapPairGraphInspection(
            scheduledPairCount: validatedSchedule.pairs.count,
            attemptedPairCount: Set(rawRows.keys).union(verifiedRows.keys).count,
            rawMatchedPairCount: rawRows.values.count(where: { $0 > 0 }),
            spatiallyVerifiedPairCount: verifiedPairIDs.count,
            localPairCount: validatedSchedule.pairs.count(where: { $0.role == .local }),
            retrievalPairCount: validatedSchedule.pairs.count(where: { $0.role == .retrieval }),
            loopRevisitPairCount: validatedSchedule.pairs.count(where: { $0.role == .loopRevisit }),
            connectedComponentCount: graph.componentCount,
            isolatedViewCount: graph.isolatedCount,
            degreeP10: nearestRank(graph.sortedDegrees, percentile: 0.10),
            degreeMedian: nearestRank(graph.sortedDegrees, percentile: 0.50),
            degreeP90: nearestRank(graph.sortedDegrees, percentile: 0.90),
            featureDatabaseDigest: databaseDigests.feature,
            matchingDatabaseDigest: databaseDigests.matching
        )
        try Task.checkCancellation()
        try execute(
            "COMMIT;",
            operation: "commit the pair-graph snapshot",
            in: database
        )
        transactionIsOpen = false
        try verifyUnchanged(handle)
        return inspection
    }

    private func openDatabase() throws -> ColmapSQLiteDatabaseHandle {
        do {
            return try ColmapSQLiteDatabaseHandle.open(
                at: databaseURL,
                flags: SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX
            )
        } catch {
            throw mapped(error)
        }
    }

    private func verifyUnchanged(_ handle: ColmapSQLiteDatabaseHandle) throws {
        do {
            try handle.verifyUnchanged()
        } catch {
            throw mapped(error)
        }
    }

    private func mapped(_ error: Error) -> ColmapPairGraphInspectorError {
        switch error as? ColmapSQLiteDatabaseHandleError {
        case .unsafeDatabaseFile:
            return .unsafeDatabaseFile
        case let .openFailed(code, message):
            return .databaseOpenFailed(code: code, message: message)
        case let .verificationFailed(code, message):
            return .databaseOpenFailed(
                code: code,
                message: "File identity verification failed: \(message)"
            )
        case nil:
            return .databaseOpenFailed(
                code: SQLITE_ERROR,
                message: error.localizedDescription
            )
        }
    }

    private func readImages(from database: OpaquePointer) throws -> [DatabaseImage] {
        var statement: OpaquePointer?
        let sql = "SELECT image_id, name FROM images ORDER BY image_id;"
        let prepareResult = sqlite3_prepare_v2(database, sql, -1, &statement, nil)
        guard prepareResult == SQLITE_OK, let statement else {
            throw ColmapPairGraphInspectorError.malformedSchema(
                table: "images",
                message: String(cString: sqlite3_errmsg(database))
            )
        }
        defer { sqlite3_finalize(statement) }

        var images: [DatabaseImage] = []
        while true {
            try Task.checkCancellation()
            let stepResult = sqlite3_step(statement)
            if stepResult == SQLITE_DONE { return images }
            guard stepResult == SQLITE_ROW else {
                throw ColmapPairGraphInspectorError.databaseReadFailed(
                    table: "images",
                    code: stepResult,
                    message: String(cString: sqlite3_errmsg(database))
                )
            }
            guard sqlite3_column_type(statement, 0) == SQLITE_INTEGER,
                sqlite3_column_type(statement, 1) == SQLITE_TEXT,
                let nameBytes = sqlite3_column_text(statement, 1)
            else {
                throw ColmapPairGraphInspectorError.malformedSchema(
                    table: "images",
                    message: "image_id and name must be non-null INTEGER and TEXT values"
                )
            }
            let imageID = sqlite3_column_int64(statement, 0)
            guard imageID >= 0, imageID < Self.pairIDDivisor else {
                throw ColmapPairGraphInspectorError.invalidImageID(imageID)
            }
            images.append(DatabaseImage(id: imageID, name: String(cString: nameBytes)))
        }
    }

    private func validate(
        _ databaseImages: [DatabaseImage],
        against schedule: ValidatedSchedule
    ) throws {
        var names: Set<String> = []
        var imageIDs: Set<Int64> = []
        for image in databaseImages {
            try Task.checkCancellation()
            guard imageIDs.insert(image.id).inserted else {
                throw ColmapPairGraphInspectorError.duplicateDatabaseImageID(image.id)
            }
            guard names.insert(image.name).inserted else {
                throw ColmapPairGraphInspectorError.duplicateDatabaseImageName(image.name)
            }
        }
        let expected = schedule.imageNames.sorted()
        let actual = names.sorted()
        guard expected == actual else {
            throw ColmapPairGraphInspectorError.imageSetMismatch(
                expected: expected,
                actual: actual
            )
        }
    }

    private func readPairRows(
        table: String,
        scheduledPairIDs: Set<Int64>,
        imageNameByID: [Int64: String],
        from database: OpaquePointer
    ) throws -> [Int64: Int64] {
        let rowCount = try readRowCount(table: table, from: database)
        guard rowCount <= scheduledPairIDs.count else {
            throw ColmapPairGraphInspectorError.tableExceedsSchedule(
                table: table,
                rows: rowCount,
                scheduledPairs: scheduledPairIDs.count
            )
        }
        var statement: OpaquePointer?
        let sql = "SELECT pair_id, rows FROM \(table);"
        let prepareResult = sqlite3_prepare_v2(database, sql, -1, &statement, nil)
        guard prepareResult == SQLITE_OK, let statement else {
            throw ColmapPairGraphInspectorError.malformedSchema(
                table: table,
                message: String(cString: sqlite3_errmsg(database))
            )
        }
        defer { sqlite3_finalize(statement) }

        var result: [Int64: Int64] = [:]
        while true {
            try Task.checkCancellation()
            let stepResult = sqlite3_step(statement)
            if stepResult == SQLITE_DONE { return result }
            guard stepResult == SQLITE_ROW else {
                throw ColmapPairGraphInspectorError.databaseReadFailed(
                    table: table,
                    code: stepResult,
                    message: String(cString: sqlite3_errmsg(database))
                )
            }
            guard sqlite3_column_type(statement, 0) == SQLITE_INTEGER,
                sqlite3_column_type(statement, 1) == SQLITE_INTEGER
            else {
                throw ColmapPairGraphInspectorError.malformedSchema(
                    table: table,
                    message: "pair_id and rows must be non-null INTEGER values"
                )
            }
            let pairID = sqlite3_column_int64(statement, 0)
            let rows = sqlite3_column_int64(statement, 1)
            let endpoints = try decode(pairID: pairID, table: table)
            guard imageNameByID[endpoints.first] != nil else {
                throw ColmapPairGraphInspectorError.unknownImageID(
                    table: table,
                    pairID: pairID,
                    imageID: endpoints.first
                )
            }
            guard imageNameByID[endpoints.second] != nil else {
                throw ColmapPairGraphInspectorError.unknownImageID(
                    table: table,
                    pairID: pairID,
                    imageID: endpoints.second
                )
            }
            guard scheduledPairIDs.contains(pairID) else {
                throw ColmapPairGraphInspectorError.pairOutsideSchedule(
                    table: table,
                    pairID: pairID
                )
            }
            guard rows >= 0 else {
                throw ColmapPairGraphInspectorError.negativeRows(
                    table: table,
                    pairID: pairID,
                    rows: rows
                )
            }
            guard result.updateValue(rows, forKey: pairID) == nil else {
                throw ColmapPairGraphInspectorError.duplicateDatabasePair(
                    table: table,
                    pairID: pairID
                )
            }
        }
    }

    private func readRowCount(table: String, from database: OpaquePointer) throws -> Int {
        var statement: OpaquePointer?
        let sql = "SELECT COUNT(*) FROM \(table);"
        let prepareResult = sqlite3_prepare_v2(database, sql, -1, &statement, nil)
        guard prepareResult == SQLITE_OK, let statement else {
            throw ColmapPairGraphInspectorError.malformedSchema(
                table: table,
                message: String(cString: sqlite3_errmsg(database))
            )
        }
        defer { sqlite3_finalize(statement) }
        let stepResult = sqlite3_step(statement)
        guard stepResult == SQLITE_ROW,
              sqlite3_column_type(statement, 0) == SQLITE_INTEGER else {
            throw ColmapPairGraphInspectorError.databaseReadFailed(
                table: table,
                code: stepResult,
                message: String(cString: sqlite3_errmsg(database))
            )
        }
        let count = sqlite3_column_int64(statement, 0)
        guard count >= 0, count <= Int64(Int.max) else {
            throw ColmapPairGraphInspectorError.malformedSchema(
                table: table,
                message: "row count is outside the supported range"
            )
        }
        return Int(count)
    }

    private func requireComplete(
        table: String,
        scheduledPairIDs: Set<Int64>,
        recordedPairIDs: Set<Int64>
    ) throws {
        let missing = scheduledPairIDs.subtracting(recordedPairIDs).sorted()
        guard missing.isEmpty else {
            throw ColmapPairGraphInspectorError.incompleteSuccessfulAttempt(
                table: table,
                missingPairIDs: missing
            )
        }
    }

    private func graphStatistics(
        imageIDs: [Int64],
        verifiedPairIDs: Set<Int64>
    ) -> (componentCount: Int, isolatedCount: Int, sortedDegrees: [Int]) {
        var parent = Dictionary(uniqueKeysWithValues: imageIDs.map { ($0, $0) })
        var degrees = Dictionary(uniqueKeysWithValues: imageIDs.map { ($0, 0) })

        func root(of imageID: Int64) -> Int64 {
            var current = imageID
            while parent[current] != current {
                current = parent[current]!
            }
            return current
        }

        for pairID in verifiedPairIDs {
            let first = pairID / Self.pairIDDivisor
            let second = pairID % Self.pairIDDivisor
            degrees[first, default: 0] += 1
            degrees[second, default: 0] += 1
            let firstRoot = root(of: first)
            let secondRoot = root(of: second)
            if firstRoot != secondRoot {
                parent[secondRoot] = firstRoot
            }
        }
        let roots = Set(imageIDs.map { root(of: $0) })
        let sortedDegrees = imageIDs.map { degrees[$0, default: 0] }.sorted()
        return (
            componentCount: roots.count,
            isolatedCount: sortedDegrees.count(where: { $0 == 0 }),
            sortedDegrees: sortedDegrees
        )
    }

    private func nearestRank(_ sortedValues: [Int], percentile: Double) -> Int {
        guard !sortedValues.isEmpty else { return 0 }
        let rank = max(1, Int(ceil(percentile * Double(sortedValues.count))))
        return sortedValues[min(rank - 1, sortedValues.count - 1)]
    }

    private func decode(pairID: Int64, table: String) throws -> (first: Int64, second: Int64) {
        guard pairID > 0 else {
            throw ColmapPairGraphInspectorError.invalidPairID(table: table, pairID: pairID)
        }
        let first = pairID / Self.pairIDDivisor
        let second = pairID % Self.pairIDDivisor
        guard first >= 0,
            second > first,
            second < Self.pairIDDivisor
        else {
            throw ColmapPairGraphInspectorError.invalidPairID(table: table, pairID: pairID)
        }
        return (first, second)
    }

    private func execute(
        _ sql: String,
        operation: String,
        in database: OpaquePointer
    ) throws {
        var message: UnsafeMutablePointer<CChar>?
        let result = sqlite3_exec(database, sql, nil, nil, &message)
        defer { sqlite3_free(message) }
        guard result == SQLITE_OK else {
            let detail =
                message.map { String(cString: $0) }
                ?? String(cString: sqlite3_errmsg(database))
            throw ColmapPairGraphInspectorError.databaseOperationFailed(
                operation: operation,
                code: result,
                message: detail
            )
        }
    }

    private struct DatabaseImage {
        let id: Int64
        let name: String
    }

    private struct ValidatedSchedule {
        let imageNames: [String]
        let pairs: [ColmapScheduledPair]

        init(_ schedule: ColmapPairSchedule) throws {
            guard !schedule.imageNames.isEmpty else {
                throw ColmapPairGraphInspectorError.emptyImageSet
            }
            var names: Set<String> = []
            for name in schedule.imageNames {
                try Task.checkCancellation()
                guard !name.isEmpty, !name.contains(where: \.isWhitespace) else {
                    throw ColmapPairGraphInspectorError.invalidImageName(name)
                }
                guard names.insert(name).inserted else {
                    throw ColmapPairGraphInspectorError.duplicateImageName(name)
                }
            }

            var edges: Set<NameEdge> = []
            for pair in schedule.pairs {
                try Task.checkCancellation()
                guard names.contains(pair.firstImageName) else {
                    throw ColmapPairGraphInspectorError.scheduledPairUnknownImage(
                        pair.firstImageName
                    )
                }
                guard names.contains(pair.secondImageName) else {
                    throw ColmapPairGraphInspectorError.scheduledPairUnknownImage(
                        pair.secondImageName
                    )
                }
                guard pair.firstImageName != pair.secondImageName else {
                    throw ColmapPairGraphInspectorError.scheduledSelfPair(pair.firstImageName)
                }
                let edge = NameEdge(pair.firstImageName, pair.secondImageName)
                guard edges.insert(edge).inserted else {
                    throw ColmapPairGraphInspectorError.duplicateScheduledPair(
                        edge.first,
                        edge.second
                    )
                }
            }
            imageNames = schedule.imageNames
            pairs = schedule.pairs
        }

        func pairIDs(imageIDByName: [String: Int64]) throws -> [NameEdge: Int64] {
            var result: [NameEdge: Int64] = [:]
            for pair in pairs {
                try Task.checkCancellation()
                guard let firstID = imageIDByName[pair.firstImageName],
                    let secondID = imageIDByName[pair.secondImageName]
                else {
                    throw ColmapPairGraphInspectorError.imageSetMismatch(
                        expected: imageNames.sorted(),
                        actual: imageIDByName.keys.sorted()
                    )
                }
                let low = min(firstID, secondID)
                let high = max(firstID, secondID)
                result[NameEdge(pair.firstImageName, pair.secondImageName)] =
                    low * ColmapPairGraphInspector.pairIDDivisor + high
            }
            return result
        }
    }

    private struct NameEdge: Hashable {
        let first: String
        let second: String

        init(_ first: String, _ second: String) {
            if first < second {
                self.first = first
                self.second = second
            } else {
                self.first = second
                self.second = first
            }
        }
    }
}
