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

struct ColmapVerifiedGraphSnapshot: Sendable, Equatable {
    let verifiedPairs: [ColmapScheduledPair]
    let components: [[String]]
}

enum PairGraphConnectivityPolicy {
    static let minimumDominantFractionWithVerifiedMinority = 0.95

    static func dominantViewCount(
        totalViewCount: Int,
        componentViewCounts: [Int],
        connectedComponentCount: Int,
        isolatedViewCount: Int,
        descriptorlessViewCount: Int
    ) -> Int? {
        guard totalViewCount >= 2,
              !componentViewCounts.isEmpty,
              componentViewCounts.count <= totalViewCount,
              connectedComponentCount == componentViewCounts.count,
              descriptorlessViewCount >= 0,
              descriptorlessViewCount <= isolatedViewCount,
              isolatedViewCount >= 0,
              isolatedViewCount <= totalViewCount - 2 else {
            return nil
        }
        var sum = 0
        var previous = totalViewCount
        var measuredIsolatedViewCount = 0
        for count in componentViewCounts {
            guard count > 0,
                  count <= previous,
                  count <= totalViewCount else {
                return nil
            }
            let addition = sum.addingReportingOverflow(count)
            guard !addition.overflow, addition.partialValue <= totalViewCount else {
                return nil
            }
            sum = addition.partialValue
            previous = count
            if count == 1 {
                measuredIsolatedViewCount += 1
            }
        }
        guard sum == totalViewCount,
              measuredIsolatedViewCount == isolatedViewCount,
              let dominantViewCount = componentViewCounts.first,
              dominantViewCount >= 2,
              componentViewCounts.dropFirst().first.map({ dominantViewCount > $0 }) ?? true else {
            return nil
        }
        let hasMinorVerifiedComponent = componentViewCounts.dropFirst().contains { $0 > 1 }
        let requiredFraction = hasMinorVerifiedComponent
            ? minimumDominantFractionWithVerifiedMinority
            : ReconstructionScorer.minimumRegisteredViewFraction
        guard Double(dominantViewCount) / Double(totalViewCount) >= requiredFraction else {
            return nil
        }
        return dominantViewCount
    }
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
    let articulationViewCount: Int
    let biconnectedBlockCount: Int
    let largestBiconnectedBlockViewCount: Int
    let secondLargestBiconnectedBlockViewCount: Int
    let degreeP10: Int
    let degreeMedian: Int
    let degreeP90: Int
    let featureDatabaseDigest: String
    let matchingDatabaseDigest: String
    let descriptorlessImageNames: [String]
    private(set) var verifiedGraph = ColmapVerifiedGraphSnapshot(
        verifiedPairs: [],
        components: []
    )

    var descriptorlessViewCount: Int {
        descriptorlessImageNames.count
    }

    var hasAcceptableDominantVerifiedComponent: Bool {
        hasAcceptableDominantVerifiedComponent(allowMinorVerifiedComponents: false)
    }

    func hasAcceptableDominantVerifiedComponent(
        allowMinorVerifiedComponents: Bool
    ) -> Bool {
        let components = verifiedGraph.components
        guard connectedComponentCount == components.count,
              isolatedViewCount == components.count(where: { $0.count == 1 }),
              spatiallyVerifiedPairCount == verifiedGraph.verifiedPairs.count,
              components.allSatisfy({ !$0.isEmpty }) else {
            return false
        }

        var componentIndexByImageName: [String: Int] = [:]
        var componentNames: [Set<String>] = []
        componentNames.reserveCapacity(components.count)
        for (componentIndex, component) in components.enumerated() {
            let names = Set(component)
            guard names.count == component.count else {
                return false
            }
            for name in names {
                guard componentIndexByImageName.updateValue(
                    componentIndex,
                    forKey: name
                ) == nil else {
                    return false
                }
            }
            componentNames.append(names)
        }

        let descriptorlessNames = Set(descriptorlessImageNames)
        let singletonNames = Set(
            components.filter { $0.count == 1 }.compactMap(\.first)
        )
        guard descriptorlessNames.count == descriptorlessImageNames.count,
              descriptorlessNames.isSubset(of: singletonNames) else {
            return false
        }

        var adjacency = Dictionary(
            uniqueKeysWithValues: componentIndexByImageName.keys.map { ($0, Set<String>()) }
        )
        var verifiedEdges: Set<Set<String>> = []
        for pair in verifiedGraph.verifiedPairs {
            let first = pair.firstImageName
            let second = pair.secondImageName
            guard first != second,
                  let firstComponent = componentIndexByImageName[first],
                  let secondComponent = componentIndexByImageName[second],
                  firstComponent == secondComponent else {
                return false
            }
            let edge = Set([first, second])
            guard verifiedEdges.insert(edge).inserted else {
                return false
            }
            adjacency[first, default: []].insert(second)
            adjacency[second, default: []].insert(first)
        }

        for names in componentNames {
            guard let start = names.first else {
                return false
            }
            var reached: Set<String> = [start]
            var pending = [start]
            while let imageName = pending.popLast() {
                for neighbor in adjacency[imageName, default: []]
                    where reached.insert(neighbor).inserted {
                    pending.append(neighbor)
                }
            }
            guard reached == names else {
                return false
            }
        }

        let sortedComponentSizes = components.map(\.count).sorted(by: >)
        guard PairGraphConnectivityPolicy.dominantViewCount(
            totalViewCount: componentIndexByImageName.count,
            componentViewCounts: sortedComponentSizes,
            connectedComponentCount: connectedComponentCount,
            isolatedViewCount: isolatedViewCount,
            descriptorlessViewCount: descriptorlessViewCount
        ) != nil else {
            return false
        }

        let hasMinorVerifiedComponent = sortedComponentSizes.dropFirst().contains { $0 > 1 }
        guard hasMinorVerifiedComponent else {
            return true
        }
        guard allowMinorVerifiedComponents,
              sortedComponentSizes.first != nil else {
            return false
        }
        return true
    }
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
    case descriptorlessImageHasCorrespondences(table: String, pairID: Int64)
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
        case .descriptorlessImageHasCorrespondences(let table, let pairID):
            return
                "The COLMAP \(table) pair \(pairID) contains correspondences for an image without descriptors."
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
        let descriptorRowsByImageID = try readDescriptorRows(
            imageNameByID: imageNameByID,
            from: database
        )
        let descriptorlessImageIDs = Set(
            descriptorRowsByImageID.compactMap { imageID, rows in
                rows == 0 ? imageID : nil
            }
        )
        let imageIDByName = Dictionary(
            uniqueKeysWithValues: databaseImages.map { ($0.name, $0.id) }
        )
        let pairIDByNames = try validatedSchedule.pairIDs(
            imageIDByName: imageIDByName
        )
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
        try validatePairRows(
            rawRows,
            table: "matches",
            descriptorlessImageIDs: descriptorlessImageIDs
        )
        try validatePairRows(
            verifiedRows,
            table: "two_view_geometries",
            descriptorlessImageIDs: descriptorlessImageIDs
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
                rows >= ColmapMappingPolicy.minimumPairInlierCount ? pairID : nil
            })
        let verifiedPairs = validatedSchedule.pairs.filter { pair in
            guard let pairID = pairIDByNames[NameEdge(
                pair.firstImageName,
                pair.secondImageName
            )] else {
                return false
            }
            return verifiedPairIDs.contains(pairID)
        }
        let descriptorlessImageNames = validatedSchedule.imageNames.filter { name in
            imageIDByName[name].map(descriptorlessImageIDs.contains) ?? false
        }
        let graph = try graphSnapshot(
            imageNames: validatedSchedule.imageNames,
            verifiedPairs: verifiedPairs,
            descriptorlessImageNames: Set(descriptorlessImageNames)
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
            articulationViewCount: graph.articulationCount,
            biconnectedBlockCount: graph.biconnectedBlockSizes.count,
            largestBiconnectedBlockViewCount: graph.biconnectedBlockSizes.first ?? 0,
            secondLargestBiconnectedBlockViewCount: graph.biconnectedBlockSizes.dropFirst().first ?? 0,
            degreeP10: nearestRank(graph.sortedDegrees, percentile: 0.10),
            degreeMedian: nearestRank(graph.sortedDegrees, percentile: 0.50),
            degreeP90: nearestRank(graph.sortedDegrees, percentile: 0.90),
            featureDatabaseDigest: databaseDigests.feature,
            matchingDatabaseDigest: databaseDigests.matching,
            descriptorlessImageNames: descriptorlessImageNames,
            verifiedGraph: graph.snapshot
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

    private func readDescriptorRows(
        imageNameByID: [Int64: String],
        from database: OpaquePointer
    ) throws -> [Int64: Int64] {
        var statement: OpaquePointer?
        let sql = "SELECT image_id, rows FROM descriptors ORDER BY image_id;"
        let prepareResult = sqlite3_prepare_v2(database, sql, -1, &statement, nil)
        guard prepareResult == SQLITE_OK, let statement else {
            throw ColmapPairGraphInspectorError.malformedSchema(
                table: "descriptors",
                message: String(cString: sqlite3_errmsg(database))
            )
        }
        defer { sqlite3_finalize(statement) }

        var rowsByImageID: [Int64: Int64] = [:]
        while true {
            try Task.checkCancellation()
            let stepResult = sqlite3_step(statement)
            if stepResult == SQLITE_DONE { break }
            guard stepResult == SQLITE_ROW else {
                throw ColmapPairGraphInspectorError.databaseReadFailed(
                    table: "descriptors",
                    code: stepResult,
                    message: String(cString: sqlite3_errmsg(database))
                )
            }
            guard sqlite3_column_type(statement, 0) == SQLITE_INTEGER,
                  sqlite3_column_type(statement, 1) == SQLITE_INTEGER else {
                throw ColmapPairGraphInspectorError.malformedSchema(
                    table: "descriptors",
                    message: "image_id and rows must be non-null INTEGER values"
                )
            }
            let imageID = sqlite3_column_int64(statement, 0)
            let rows = sqlite3_column_int64(statement, 1)
            guard imageNameByID[imageID] != nil else {
                throw ColmapPairGraphInspectorError.malformedSchema(
                    table: "descriptors",
                    message: "descriptor row refers to unknown image ID \(imageID)"
                )
            }
            guard rows >= 0 else {
                throw ColmapPairGraphInspectorError.malformedSchema(
                    table: "descriptors",
                    message: "descriptor row count is negative for image ID \(imageID)"
                )
            }
            guard rowsByImageID.updateValue(rows, forKey: imageID) == nil else {
                throw ColmapPairGraphInspectorError.malformedSchema(
                    table: "descriptors",
                    message: "descriptor evidence contains image ID \(imageID) more than once"
                )
            }
        }

        let expectedImageIDs = Set(imageNameByID.keys)
        let actualImageIDs = Set(rowsByImageID.keys)
        guard actualImageIDs == expectedImageIDs else {
            let missing = expectedImageIDs.subtracting(actualImageIDs).sorted()
            throw ColmapPairGraphInspectorError.malformedSchema(
                table: "descriptors",
                message: "descriptor evidence is missing image IDs \(missing)"
            )
        }
        return rowsByImageID
    }

    private func validatePairRows(
        _ rowsByPairID: [Int64: Int64],
        table: String,
        descriptorlessImageIDs: Set<Int64>
    ) throws {
        guard !descriptorlessImageIDs.isEmpty else { return }
        for (pairID, rows) in rowsByPairID where rows > 0 {
            try Task.checkCancellation()
            let endpoints = try decode(pairID: pairID, table: table)
            guard !descriptorlessImageIDs.contains(endpoints.first),
                  !descriptorlessImageIDs.contains(endpoints.second) else {
                throw ColmapPairGraphInspectorError.descriptorlessImageHasCorrespondences(
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

    private func graphSnapshot(
        imageNames: [String],
        verifiedPairs: [ColmapScheduledPair],
        descriptorlessImageNames: Set<String>
    ) throws -> (
        componentCount: Int,
        isolatedCount: Int,
        sortedDegrees: [Int],
        articulationCount: Int,
        biconnectedBlockSizes: [Int],
        snapshot: ColmapVerifiedGraphSnapshot
    ) {
        let indexByName = Dictionary(uniqueKeysWithValues: imageNames.enumerated().map {
            ($0.element, $0.offset)
        })
        var parent = Array(imageNames.indices)
        var degrees = Array(repeating: 0, count: imageNames.count)

        func root(of index: Int) -> Int {
            var current = index
            while parent[current] != current {
                current = parent[current]
            }
            return current
        }

        for pair in verifiedPairs {
            try Task.checkCancellation()
            guard let first = indexByName[pair.firstImageName],
                  let second = indexByName[pair.secondImageName] else {
                throw ColmapPairGraphInspectorError.scheduledPairUnknownImage(
                    indexByName[pair.firstImageName] == nil
                        ? pair.firstImageName
                        : pair.secondImageName
                )
            }
            degrees[first] += 1
            degrees[second] += 1
            let firstRoot = root(of: first)
            let secondRoot = root(of: second)
            if firstRoot != secondRoot {
                parent[secondRoot] = firstRoot
            }
        }

        var membersByRoot: [Int: [String]] = [:]
        for index in imageNames.indices {
            try Task.checkCancellation()
            membersByRoot[root(of: index), default: []].append(imageNames[index])
        }
        let components = membersByRoot.values.sorted { first, second in
            indexByName[first[0]]! < indexByName[second[0]]!
        }
        var dominantComponent = components[0]
        for component in components.dropFirst() where component.count > dominantComponent.count {
            dominantComponent = component
        }
        let sortedDegrees = degrees.sorted()
        let robustness = try biconnectedRobustness(
            imageNames: imageNames,
            verifiedPairs: verifiedPairs,
            descriptorlessImageNames: descriptorlessImageNames,
            includedImageNames: Set(dominantComponent),
            indexByName: indexByName
        )
        return (
            componentCount: components.count,
            isolatedCount: sortedDegrees.count(where: { $0 == 0 }),
            sortedDegrees: sortedDegrees,
            articulationCount: robustness.articulationCount,
            biconnectedBlockSizes: robustness.blockSizes,
            snapshot: ColmapVerifiedGraphSnapshot(
                verifiedPairs: verifiedPairs,
                components: components
            )
        )
    }

    private func biconnectedRobustness(
        imageNames: [String],
        verifiedPairs: [ColmapScheduledPair],
        descriptorlessImageNames: Set<String>,
        includedImageNames: Set<String>,
        indexByName: [String: Int]
    ) throws -> (articulationCount: Int, blockSizes: [Int]) {
        struct Edge: Sendable {
            let id: Int
            let first: Int
            let second: Int

            func other(than vertex: Int) -> Int {
                vertex == first ? second : first
            }
        }
        struct Frame: Sendable {
            let vertex: Int
            var nextEdgeIndex: Int
        }

        var adjacency = Array(repeating: [Edge](), count: imageNames.count)
        for (edgeID, pair) in verifiedPairs.enumerated() {
            try Task.checkCancellation()
            if !includedImageNames.contains(pair.firstImageName)
                || !includedImageNames.contains(pair.secondImageName)
                || descriptorlessImageNames.contains(pair.firstImageName)
                || descriptorlessImageNames.contains(pair.secondImageName) {
                continue
            }
            guard let first = indexByName[pair.firstImageName],
                  let second = indexByName[pair.secondImageName] else {
                throw ColmapPairGraphInspectorError.scheduledPairUnknownImage(
                    indexByName[pair.firstImageName] == nil
                        ? pair.firstImageName
                        : pair.secondImageName
                )
            }
            let edge = Edge(id: edgeID, first: first, second: second)
            adjacency[first].append(edge)
            adjacency[second].append(edge)
        }

        var discovery = Array(repeating: -1, count: imageNames.count)
        var low = Array(repeating: 0, count: imageNames.count)
        var parent = Array(repeating: -1, count: imageNames.count)
        var parentEdge = Array(repeating: -1, count: imageNames.count)
        var childCount = Array(repeating: 0, count: imageNames.count)
        var articulationVertices: Set<Int> = []
        var edgeStack: [Edge] = []
        var blockSizes: [Int] = []
        var timestamp = 0

        // Blocks partition verified edges: bridges form two-view blocks, while
        // isolated and descriptorless views form no block.
        func popBlock(endingAt edgeID: Int) throws -> Int {
            var vertices: Set<Int> = []
            var foundBoundary = false
            while let edge = edgeStack.popLast() {
                try Task.checkCancellation()
                vertices.insert(edge.first)
                vertices.insert(edge.second)
                if edge.id == edgeID {
                    foundBoundary = true
                    break
                }
            }
            guard foundBoundary else {
                throw ColmapPairGraphInspectorError.malformedSchema(
                    table: "two_view_geometries",
                    message: "verified graph block boundary is missing"
                )
            }
            return vertices.count
        }

        for root in imageNames.indices {
            try Task.checkCancellation()
            guard includedImageNames.contains(imageNames[root]),
                  !descriptorlessImageNames.contains(imageNames[root]),
                  discovery[root] == -1 else {
                continue
            }
            discovery[root] = timestamp
            low[root] = timestamp
            timestamp += 1
            var traversal = [Frame(vertex: root, nextEdgeIndex: 0)]

            while !traversal.isEmpty {
                try Task.checkCancellation()
                let vertex = traversal[traversal.count - 1].vertex
                let nextEdgeIndex = traversal[traversal.count - 1].nextEdgeIndex
                if nextEdgeIndex < adjacency[vertex].count {
                    let edge = adjacency[vertex][nextEdgeIndex]
                    traversal[traversal.count - 1].nextEdgeIndex += 1
                    let neighbor = edge.other(than: vertex)
                    if discovery[neighbor] == -1 {
                        parent[neighbor] = vertex
                        parentEdge[neighbor] = edge.id
                        childCount[vertex] += 1
                        edgeStack.append(edge)
                        discovery[neighbor] = timestamp
                        low[neighbor] = timestamp
                        timestamp += 1
                        traversal.append(Frame(vertex: neighbor, nextEdgeIndex: 0))
                    } else if edge.id != parentEdge[vertex],
                              discovery[neighbor] < discovery[vertex] {
                        low[vertex] = min(low[vertex], discovery[neighbor])
                        edgeStack.append(edge)
                    }
                    continue
                }

                traversal.removeLast()
                let parentVertex = parent[vertex]
                guard parentVertex != -1 else {
                    if childCount[vertex] > 1 {
                        articulationVertices.insert(vertex)
                    }
                    continue
                }
                low[parentVertex] = min(low[parentVertex], low[vertex])
                if low[vertex] >= discovery[parentVertex] {
                    if parent[parentVertex] != -1 || childCount[parentVertex] > 1 {
                        articulationVertices.insert(parentVertex)
                    }
                    let blockSize = try popBlock(endingAt: parentEdge[vertex])
                    if blockSize > 0 { blockSizes.append(blockSize) }
                }
            }
            // Each DFS tree drains its own edges at articulation boundaries.
            guard edgeStack.isEmpty else {
                throw ColmapPairGraphInspectorError.malformedSchema(
                    table: "two_view_geometries",
                    message: "verified graph traversal left unassigned edges"
                )
            }
        }

        blockSizes.sort(by: >)
        return (articulationVertices.count, blockSizes)
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
