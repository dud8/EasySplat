import Darwin
import Foundation
import SQLite3

enum ColmapSparseModelFormat: String, Sendable, Equatable {
    case binary
    case text
}

enum ColmapSparseModelBinaryIssue: Sendable, Equatable {
    case invalidImageCount
    case truncated
    case missingNameTerminator
    case nameTooLong
    case invalidUTF8
    case invalidImageID
    case nonfinitePose
    case zeroQuaternion
    case invalidCameraID
    case pointCountOverflow
    case trailingBytes
}

enum ColmapSparseModelTextIssue: Sendable, Equatable {
    case missingImages
    case invalidPoseLine
    case missingObservationLine
    case invalidObservationLine
    case invalidUTF8
    case lineTooLong
}

enum ColmapSparseModelMembershipReaderError: Error, LocalizedError, Equatable {
    case emptySelectedImageSet
    case invalidSelectedImageName(String)
    case duplicateSelectedImageName(String)
    case unsafeDatabaseFile
    case databaseOpenFailed(code: Int32, message: String)
    case databaseReadFailed(code: Int32, message: String)
    case invalidDatabaseImageID(Int64)
    case invalidDatabaseImageName
    case duplicateDatabaseImageID(UInt32)
    case duplicateDatabaseImageName(String)
    case databaseImageSetMismatch(expected: [String], actual: [String])
    case emptyModelSet
    case invalidModelDirectory(String)
    case duplicateModelOrder(Int)
    case missingModelFamily(modelOrder: Int)
    case partialModelFamily(modelOrder: Int, format: ColmapSparseModelFormat)
    case unsafeModelFile(modelOrder: Int, file: String)
    case malformedBinary(modelOrder: Int, issue: ColmapSparseModelBinaryIssue)
    case malformedText(
        modelOrder: Int,
        line: Int,
        issue: ColmapSparseModelTextIssue
    )
    case duplicateModelImageID(modelOrder: Int, imageID: UInt32)
    case duplicateModelImageName(modelOrder: Int, name: String)
    case unknownModelImageID(modelOrder: Int, imageID: UInt32)
    case imageBindingMismatch(
        modelOrder: Int,
        imageID: UInt32,
        expectedName: String,
        actualName: String
    )
    case unknownModelImageName(modelOrder: Int, name: String)

    var errorDescription: String? {
        switch self {
        case .emptySelectedImageSet:
            return "The selected input does not contain any images."
        case .invalidSelectedImageName(let name):
            return "The selected input contains an invalid image name: \(name)."
        case .duplicateSelectedImageName(let name):
            return "The selected input contains the image more than once: \(name)."
        case .unsafeDatabaseFile:
            return "The COLMAP database must be a stable, ordinary file."
        case .databaseOpenFailed(let code, let message):
            return "Could not open the COLMAP database (SQLite \(code)): \(message)"
        case .databaseReadFailed(let code, let message):
            return "Could not read the COLMAP image table (SQLite \(code)): \(message)"
        case .invalidDatabaseImageID(let imageID):
            return "The COLMAP database contains an invalid image ID: \(imageID)."
        case .invalidDatabaseImageName:
            return "The COLMAP database contains an invalid image name."
        case .duplicateDatabaseImageID(let imageID):
            return "The COLMAP database contains image ID \(imageID) more than once."
        case .duplicateDatabaseImageName(let name):
            return "The COLMAP database contains the image more than once: \(name)."
        case .databaseImageSetMismatch(let expected, let actual):
            return "The COLMAP database image set does not match the selected input (expected \(expected), found \(actual))."
        case .emptyModelSet:
            return "COLMAP did not produce any sparse models."
        case .invalidModelDirectory(let name):
            return "COLMAP produced an invalid sparse-model directory: \(name)."
        case .duplicateModelOrder(let order):
            return "COLMAP produced sparse-model directory \(order) more than once."
        case .missingModelFamily(let order):
            return "COLMAP sparse model \(order) has no complete model files."
        case .partialModelFamily(let order, let format):
            return "COLMAP sparse model \(order) has an incomplete \(format.rawValue) file family."
        case .unsafeModelFile(let order, let file):
            return "COLMAP sparse model \(order) contains an unsafe or changing \(file)."
        case .malformedBinary(let order, let issue):
            return "COLMAP sparse model \(order) has malformed images.bin data (\(issue))."
        case .malformedText(let order, let line, let issue):
            return "COLMAP sparse model \(order) has malformed images.txt data at line \(line) (\(issue))."
        case .duplicateModelImageID(let order, let imageID):
            return "COLMAP sparse model \(order) contains image ID \(imageID) more than once."
        case .duplicateModelImageName(let order, let name):
            return "COLMAP sparse model \(order) contains the image more than once: \(name)."
        case .unknownModelImageID(let order, let imageID):
            return "COLMAP sparse model \(order) refers to unknown image ID \(imageID)."
        case .imageBindingMismatch(let order, let imageID, let expected, let actual):
            return "COLMAP sparse model \(order) binds image ID \(imageID) to \(actual), but the database binds it to \(expected)."
        case .unknownModelImageName(let order, let name):
            return "COLMAP sparse model \(order) refers to an image outside the selected set: \(name)."
        }
    }
}

struct ColmapSparseModelMembership: Sendable, Equatable {
    let modelOrder: Int
    let imageIDs: Set<UInt32>
}

struct ColmapSparseModelMembershipSummary: Sendable, Equatable {
    let models: [ColmapSparseModelMembership]
    let unionImageIDs: Set<UInt32>
    let largestModelRegisteredViewCount: Int
    let secondLargestModelRegisteredViewCount: Int

    var modelCount: Int { models.count }
    var unionRegisteredViewCount: Int { unionImageIDs.count }

    fileprivate init(models: [ColmapSparseModelMembership]) {
        self.models = models.sorted { $0.modelOrder < $1.modelOrder }
        unionImageIDs = models.reduce(into: Set<UInt32>()) {
            $0.formUnion($1.imageIDs)
        }
        let sizes = models.map { $0.imageIDs.count }.sorted(by: >)
        largestModelRegisteredViewCount = sizes.first ?? 0
        secondLargestModelRegisteredViewCount = sizes.dropFirst().first ?? 0
    }
}

struct ColmapSparseModelMembershipReader: Sendable {
    private static let maximumCOLMAPImageID: Int64 = 2_147_483_646
    private static let maximumImageNameBytes = 4_096
    private static let binaryFiles = ["cameras.bin", "images.bin", "points3D.bin"]
    private static let textFiles = ["cameras.txt", "images.txt", "points3D.txt"]

    let databaseURL: URL
    let selectedImageNames: [String]

    func read(
        modelDirectories: [URL],
        checkCancellation: () throws -> Void = { try Task.checkCancellation() }
    ) throws -> ColmapSparseModelMembershipSummary {
        try checkCancellation()
        let selectedNames = try validatedSelectedImageNames(
            checkCancellation: checkCancellation
        )
        let orderedModels = try validatedModelDirectories(
            modelDirectories,
            checkCancellation: checkCancellation
        )
        let handle = try openDatabase()
        let database = handle.database
        sqlite3_extended_result_codes(database, 1)
        guard sqlite3_busy_timeout(database, 5_000) == SQLITE_OK else {
            throw databaseFailure(database)
        }
        try execute("PRAGMA query_only = ON;", in: database)
        try execute("BEGIN DEFERRED TRANSACTION;", in: database)
        var transactionIsOpen = true
        defer {
            if transactionIsOpen {
                sqlite3_exec(database, "ROLLBACK;", nil, nil, nil)
            }
        }

        let databaseImages = try readDatabaseImages(
            database,
            checkCancellation: checkCancellation
        )
        let actualNames = databaseImages.values.sorted()
        guard actualNames == selectedNames.sorted() else {
            throw ColmapSparseModelMembershipReaderError.databaseImageSetMismatch(
                expected: selectedNames.sorted(),
                actual: actualNames
            )
        }

        var memberships: [ColmapSparseModelMembership] = []
        memberships.reserveCapacity(orderedModels.count)
        for model in orderedModels {
            try checkCancellation()
            let records = try readModel(
                model,
                maximumImageCount: databaseImages.count,
                checkCancellation: checkCancellation
            )
            let imageIDs = try bind(
                records,
                modelOrder: model.order,
                databaseImages: databaseImages,
                checkCancellation: checkCancellation
            )
            memberships.append(
                ColmapSparseModelMembership(
                    modelOrder: model.order,
                    imageIDs: imageIDs
                )
            )
        }

        try checkCancellation()
        try execute("COMMIT;", in: database)
        transactionIsOpen = false
        do {
            try handle.verifyUnchanged()
        } catch {
            throw mappedDatabase(error)
        }
        return ColmapSparseModelMembershipSummary(models: memberships)
    }

    /// Returns the exact camera image set consumed from `images.bin`, preserving the
    /// authenticated selected-frame order. The training dataset intentionally has no
    /// database dependency, so this path binds names directly to the selected set.
    func registeredImageNames(
        in modelDirectory: URL,
        checkCancellation: () throws -> Void = { try Task.checkCancellation() }
    ) throws -> [String] {
        try checkCancellation()
        let selectedNames = try validatedSelectedImageNames(
            checkCancellation: checkCancellation
        )
        let models = try validatedModelDirectories(
            [modelDirectory],
            checkCancellation: checkCancellation
        )
        guard let model = models.first else {
            throw ColmapSparseModelMembershipReaderError.emptyModelSet
        }
        let records = try readModel(
            model,
            maximumImageCount: selectedNames.count,
            checkCancellation: checkCancellation
        )
        let selectedSet = Set(selectedNames)
        var imageIDs: Set<UInt32> = []
        var registeredNames: Set<String> = []
        for record in records {
            try checkCancellation()
            guard imageIDs.insert(record.id).inserted else {
                throw ColmapSparseModelMembershipReaderError.duplicateModelImageID(
                    modelOrder: model.order,
                    imageID: record.id
                )
            }
            guard registeredNames.insert(record.name).inserted else {
                throw ColmapSparseModelMembershipReaderError.duplicateModelImageName(
                    modelOrder: model.order,
                    name: record.name
                )
            }
            guard selectedSet.contains(record.name) else {
                throw ColmapSparseModelMembershipReaderError.unknownModelImageName(
                    modelOrder: model.order,
                    name: record.name
                )
            }
        }
        let ordered = selectedNames.filter(registeredNames.contains)
        guard !ordered.isEmpty, ordered.count == registeredNames.count else {
            throw ColmapSparseModelMembershipReaderError.emptySelectedImageSet
        }
        return ordered
    }

    private func validatedSelectedImageNames(
        checkCancellation: () throws -> Void
    ) throws -> [String] {
        guard !selectedImageNames.isEmpty else {
            throw ColmapSparseModelMembershipReaderError.emptySelectedImageSet
        }
        var seen: Set<String> = []
        for name in selectedImageNames {
            try checkCancellation()
            guard !name.isEmpty,
                  !name.contains("\0"),
                  name.utf8.count <= Self.maximumImageNameBytes else {
                throw ColmapSparseModelMembershipReaderError.invalidSelectedImageName(name)
            }
            guard seen.insert(name).inserted else {
                throw ColmapSparseModelMembershipReaderError.duplicateSelectedImageName(name)
            }
        }
        return selectedImageNames
    }

    private func validatedModelDirectories(
        _ directories: [URL],
        checkCancellation: () throws -> Void
    ) throws -> [ModelDirectory] {
        guard !directories.isEmpty else {
            throw ColmapSparseModelMembershipReaderError.emptyModelSet
        }
        var seenOrders: Set<Int> = []
        var models: [ModelDirectory] = []
        models.reserveCapacity(directories.count)
        for directory in directories {
            try checkCancellation()
            let name = directory.lastPathComponent
            guard directory.isFileURL,
                  let order = Int(name),
                  order >= 0,
                  String(order) == name,
                  let snapshot = try? FileSnapshot(at: directory),
                  snapshot.isDirectory else {
                throw ColmapSparseModelMembershipReaderError.invalidModelDirectory(name)
            }
            guard seenOrders.insert(order).inserted else {
                throw ColmapSparseModelMembershipReaderError.duplicateModelOrder(order)
            }
            models.append(ModelDirectory(url: directory, order: order, snapshot: snapshot))
        }
        return models.sorted { $0.order < $1.order }
    }

    private func openDatabase() throws -> ColmapSQLiteDatabaseHandle {
        do {
            return try ColmapSQLiteDatabaseHandle.open(
                at: databaseURL,
                flags: SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX
            )
        } catch {
            throw mappedDatabase(error)
        }
    }

    private func mappedDatabase(_ error: Error) -> ColmapSparseModelMembershipReaderError {
        switch error as? ColmapSQLiteDatabaseHandleError {
        case .unsafeDatabaseFile:
            return .unsafeDatabaseFile
        case .openFailed(let code, let message):
            return .databaseOpenFailed(code: code, message: message)
        case .verificationFailed(let code, let message):
            return .databaseOpenFailed(
                code: code,
                message: "File identity verification failed: \(message)"
            )
        case nil:
            return .databaseOpenFailed(code: SQLITE_ERROR, message: error.localizedDescription)
        }
    }

    private func databaseFailure(_ database: OpaquePointer) -> ColmapSparseModelMembershipReaderError {
        .databaseReadFailed(
            code: sqlite3_extended_errcode(database),
            message: String(cString: sqlite3_errmsg(database))
        )
    }

    private func execute(_ sql: String, in database: OpaquePointer) throws {
        var message: UnsafeMutablePointer<CChar>?
        let result = sqlite3_exec(database, sql, nil, nil, &message)
        defer { sqlite3_free(message) }
        guard result == SQLITE_OK else {
            throw ColmapSparseModelMembershipReaderError.databaseReadFailed(
                code: result,
                message: message.map { String(cString: $0) }
                    ?? String(cString: sqlite3_errmsg(database))
            )
        }
    }

    private func readDatabaseImages(
        _ database: OpaquePointer,
        checkCancellation: () throws -> Void
    ) throws -> [UInt32: String] {
        var statement: OpaquePointer?
        let result = sqlite3_prepare_v2(
            database,
            "SELECT image_id, name FROM images ORDER BY image_id;",
            -1,
            &statement,
            nil
        )
        guard result == SQLITE_OK, let statement else {
            throw databaseFailure(database)
        }
        defer { sqlite3_finalize(statement) }

        var images: [UInt32: String] = [:]
        var names: Set<String> = []
        while true {
            try checkCancellation()
            let step = sqlite3_step(statement)
            if step == SQLITE_DONE { break }
            guard step == SQLITE_ROW,
                  sqlite3_column_type(statement, 0) == SQLITE_INTEGER,
                  sqlite3_column_type(statement, 1) == SQLITE_TEXT else {
                throw databaseFailure(database)
            }
            let rawID = sqlite3_column_int64(statement, 0)
            guard rawID > 0, rawID <= Self.maximumCOLMAPImageID else {
                throw ColmapSparseModelMembershipReaderError.invalidDatabaseImageID(rawID)
            }
            guard let namePointer = sqlite3_column_text(statement, 1) else {
                throw ColmapSparseModelMembershipReaderError.invalidDatabaseImageName
            }
            let byteCount = Int(sqlite3_column_bytes(statement, 1))
            let bytes = UnsafeBufferPointer(start: namePointer, count: byteCount)
            guard byteCount > 0,
                  byteCount <= Self.maximumImageNameBytes,
                  !bytes.contains(0),
                  let name = String(bytes: bytes, encoding: .utf8) else {
                throw ColmapSparseModelMembershipReaderError.invalidDatabaseImageName
            }
            let imageID = UInt32(rawID)
            guard images.updateValue(name, forKey: imageID) == nil else {
                throw ColmapSparseModelMembershipReaderError.duplicateDatabaseImageID(imageID)
            }
            guard names.insert(name).inserted else {
                throw ColmapSparseModelMembershipReaderError.duplicateDatabaseImageName(name)
            }
        }
        return images
    }

    private func readModel(
        _ model: ModelDirectory,
        maximumImageCount: Int,
        checkCancellation: () throws -> Void
    ) throws -> [ParsedImage] {
        let binary = try snapshots(
            fileNames: Self.binaryFiles,
            model: model,
            checkCancellation: checkCancellation
        )
        let text = try snapshots(
            fileNames: Self.textFiles,
            model: model,
            checkCancellation: checkCancellation
        )
        if !binary.isEmpty, binary.count != Self.binaryFiles.count {
            throw ColmapSparseModelMembershipReaderError.partialModelFamily(
                modelOrder: model.order,
                format: .binary
            )
        }
        if !text.isEmpty, text.count != Self.textFiles.count {
            throw ColmapSparseModelMembershipReaderError.partialModelFamily(
                modelOrder: model.order,
                format: .text
            )
        }
        guard !binary.isEmpty || !text.isEmpty else {
            throw ColmapSparseModelMembershipReaderError.missingModelFamily(
                modelOrder: model.order
            )
        }

        let records: [ParsedImage]
        if binary.count == Self.binaryFiles.count {
            records = try readBinaryImages(
                at: model.url.appendingPathComponent("images.bin"),
                modelOrder: model.order,
                maximumImageCount: maximumImageCount,
                checkCancellation: checkCancellation
            )
        } else {
            records = try readTextImages(
                at: model.url.appendingPathComponent("images.txt"),
                modelOrder: model.order,
                maximumImageCount: maximumImageCount,
                checkCancellation: checkCancellation
            )
        }

        try checkCancellation()
        guard (try? FileSnapshot(at: model.url)) == model.snapshot else {
            throw ColmapSparseModelMembershipReaderError.invalidModelDirectory(
                model.url.lastPathComponent
            )
        }
        for (name, snapshot) in binary.merging(text, uniquingKeysWith: { first, _ in first }) {
            guard (try? FileSnapshot(at: model.url.appendingPathComponent(name))) == snapshot else {
                throw ColmapSparseModelMembershipReaderError.unsafeModelFile(
                    modelOrder: model.order,
                    file: name
                )
            }
        }
        return records
    }

    private func snapshots(
        fileNames: [String],
        model: ModelDirectory,
        checkCancellation: () throws -> Void
    ) throws -> [String: FileSnapshot] {
        var result: [String: FileSnapshot] = [:]
        for name in fileNames {
            try checkCancellation()
            let url = model.url.appendingPathComponent(name)
            do {
                let snapshot = try FileSnapshot(at: url)
                guard snapshot.isSingleLinkedRegularFile,
                      snapshot.size <= maximumBytes(for: name) else {
                    throw ColmapSparseModelMembershipReaderError.unsafeModelFile(
                        modelOrder: model.order,
                        file: name
                    )
                }
                result[name] = snapshot
            } catch FileSnapshot.Error.missing {
                continue
            } catch let error as ColmapSparseModelMembershipReaderError {
                throw error
            } catch {
                throw ColmapSparseModelMembershipReaderError.unsafeModelFile(
                    modelOrder: model.order,
                    file: name
                )
            }
        }
        return result
    }

    private func maximumBytes(for name: String) -> off_t {
        switch name {
        case "cameras.bin", "cameras.txt":
            return off_t(ColmapTextFileLimits.cameras)
        case "images.bin", "images.txt":
            return off_t(ColmapTextFileLimits.images)
        default:
            return off_t(ColmapTextFileLimits.points)
        }
    }

    private func readBinaryImages(
        at url: URL,
        modelOrder: Int,
        maximumImageCount: Int,
        checkCancellation: () throws -> Void
    ) throws -> [ParsedImage] {
        let reader = try StableBinaryReader(
            at: url,
            maximumBytes: off_t(ColmapTextFileLimits.images),
            modelOrder: modelOrder
        )
        let count = try reader.readUInt64()
        guard count > 0,
              count <= UInt64(maximumImageCount),
              count <= UInt64(Int.max) else {
            throw ColmapSparseModelMembershipReaderError.malformedBinary(
                modelOrder: modelOrder,
                issue: .invalidImageCount
            )
        }
        var records: [ParsedImage] = []
        records.reserveCapacity(Int(count))
        for _ in 0..<count {
            try checkCancellation()
            let imageID = try reader.readUInt32()
            guard imageID > 0,
                  Int64(imageID) <= Self.maximumCOLMAPImageID else {
                throw ColmapSparseModelMembershipReaderError.malformedBinary(
                    modelOrder: modelOrder,
                    issue: .invalidImageID
                )
            }
            var pose: [Double] = []
            pose.reserveCapacity(7)
            for _ in 0..<7 { pose.append(try reader.readDouble()) }
            guard pose.allSatisfy(\.isFinite) else {
                throw ColmapSparseModelMembershipReaderError.malformedBinary(
                    modelOrder: modelOrder,
                    issue: .nonfinitePose
                )
            }
            let norm = pose[0..<4].reduce(0.0) { $0 + $1 * $1 }
            guard norm.isFinite else {
                throw ColmapSparseModelMembershipReaderError.malformedBinary(
                    modelOrder: modelOrder,
                    issue: .nonfinitePose
                )
            }
            guard norm > 0 else {
                throw ColmapSparseModelMembershipReaderError.malformedBinary(
                    modelOrder: modelOrder,
                    issue: .zeroQuaternion
                )
            }
            guard try reader.readUInt32() > 0 else {
                throw ColmapSparseModelMembershipReaderError.malformedBinary(
                    modelOrder: modelOrder,
                    issue: .invalidCameraID
                )
            }
            let name = try reader.readName(
                maximumBytes: Self.maximumImageNameBytes,
                checkCancellation: checkCancellation
            )
            let pointCount = try reader.readUInt64()
            try reader.skipPointRecords(count: pointCount)
            records.append(ParsedImage(id: imageID, name: name, line: nil))
        }
        try reader.requireEndOfFile()
        try reader.verifyUnchanged()
        return records
    }

    private func readTextImages(
        at url: URL,
        modelOrder: Int,
        maximumImageCount: Int,
        checkCancellation: () throws -> Void
    ) throws -> [ParsedImage] {
        let reader: BoundedUTF8LineReader
        do {
            reader = try BoundedUTF8LineReader(
                at: url,
                maximumBytes: ColmapTextFileLimits.images,
                maximumLineBytes: ColmapTextFileLimits.maximumLine
            )
        } catch {
            throw mappedTextReader(error, modelOrder: modelOrder)
        }
        var records: [ParsedImage] = []
        var pendingPoseLine: Int?
        while true {
            let line: BoundedUTF8LineReader.Line?
            do {
                line = try reader.next(checkCancellation: checkCancellation)
            } catch {
                throw mappedTextReader(error, modelOrder: modelOrder)
            }
            guard let line else { break }
            let trimmed = line.text.trimmingCharacters(in: .whitespaces)
            if let poseLine = pendingPoseLine {
                guard !trimmed.hasPrefix("#"), validObservationLine(trimmed) else {
                    throw ColmapSparseModelMembershipReaderError.malformedText(
                        modelOrder: modelOrder,
                        line: line.number,
                        issue: .invalidObservationLine
                    )
                }
                pendingPoseLine = nil
                _ = poseLine
                continue
            }
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
            guard let record = parsedTextPose(line.text, line: line.number) else {
                throw ColmapSparseModelMembershipReaderError.malformedText(
                    modelOrder: modelOrder,
                    line: line.number,
                    issue: .invalidPoseLine
                )
            }
            records.append(record)
            guard records.count <= maximumImageCount else {
                throw ColmapSparseModelMembershipReaderError.malformedText(
                    modelOrder: modelOrder,
                    line: line.number,
                    issue: .invalidPoseLine
                )
            }
            pendingPoseLine = line.number
        }
        if let pendingPoseLine {
            throw ColmapSparseModelMembershipReaderError.malformedText(
                modelOrder: modelOrder,
                line: pendingPoseLine,
                issue: .missingObservationLine
            )
        }
        guard !records.isEmpty else {
            throw ColmapSparseModelMembershipReaderError.malformedText(
                modelOrder: modelOrder,
                line: 0,
                issue: .missingImages
            )
        }
        return records
    }

    private func mappedTextReader(
        _ error: Error,
        modelOrder: Int
    ) -> ColmapSparseModelMembershipReaderError {
        switch error as? BoundedUTF8LineReader.Error {
        case .invalidUTF8:
            return .malformedText(modelOrder: modelOrder, line: 0, issue: .invalidUTF8)
        case .lineTooLong:
            return .malformedText(modelOrder: modelOrder, line: 0, issue: .lineTooLong)
        default:
            return .unsafeModelFile(modelOrder: modelOrder, file: "images.txt")
        }
    }

    private func parsedTextPose(_ text: String, line: Int) -> ParsedImage? {
        var cursor = TokenCursor(text)
        var fields: [Substring] = []
        fields.reserveCapacity(9)
        for _ in 0..<9 {
            guard let token = cursor.next() else { return nil }
            fields.append(token)
        }
        guard let name = cursor.remainder(),
              name.utf8.count <= Self.maximumImageNameBytes,
              !name.contains("\0"),
              let imageID = UInt32(fields[0]),
              imageID > 0,
              Int64(imageID) <= Self.maximumCOLMAPImageID,
              let cameraID = UInt32(fields[8]),
              cameraID > 0 else {
            return nil
        }
        let pose = fields[1...7].compactMap(Double.init)
        guard pose.count == 7,
              pose.allSatisfy(\.isFinite) else {
            return nil
        }
        let norm = pose[0..<4].reduce(0.0) { $0 + $1 * $1 }
        guard norm.isFinite, norm > 0 else { return nil }
        return ParsedImage(id: imageID, name: String(name), line: line)
    }

    private func validObservationLine(_ text: String) -> Bool {
        if text.isEmpty { return true }
        var cursor = TokenCursor(text)
        var tokens: [Substring] = []
        while let token = cursor.next() { tokens.append(token) }
        guard !tokens.isEmpty, tokens.count.isMultiple(of: 3) else { return false }
        for index in stride(from: 0, to: tokens.count, by: 3) {
            guard let x = Double(tokens[index]), x.isFinite,
                  let y = Double(tokens[index + 1]), y.isFinite else {
                return false
            }
            let pointID = tokens[index + 2]
            guard pointID == "-1" || UInt64(pointID) != nil else { return false }
        }
        return true
    }

    private func bind(
        _ records: [ParsedImage],
        modelOrder: Int,
        databaseImages: [UInt32: String],
        checkCancellation: () throws -> Void
    ) throws -> Set<UInt32> {
        var imageIDs: Set<UInt32> = []
        var names: Set<String> = []
        for record in records {
            try checkCancellation()
            guard imageIDs.insert(record.id).inserted else {
                throw ColmapSparseModelMembershipReaderError.duplicateModelImageID(
                    modelOrder: modelOrder,
                    imageID: record.id
                )
            }
            guard names.insert(record.name).inserted else {
                throw ColmapSparseModelMembershipReaderError.duplicateModelImageName(
                    modelOrder: modelOrder,
                    name: record.name
                )
            }
            guard let expectedName = databaseImages[record.id] else {
                throw ColmapSparseModelMembershipReaderError.unknownModelImageID(
                    modelOrder: modelOrder,
                    imageID: record.id
                )
            }
            guard record.name == expectedName else {
                throw ColmapSparseModelMembershipReaderError.imageBindingMismatch(
                    modelOrder: modelOrder,
                    imageID: record.id,
                    expectedName: expectedName,
                    actualName: record.name
                )
            }
        }
        return imageIDs
    }

    private struct ModelDirectory {
        let url: URL
        let order: Int
        let snapshot: FileSnapshot
    }

    private struct ParsedImage {
        let id: UInt32
        let name: String
        let line: Int?
    }

    private struct TokenCursor {
        let text: String
        var index: String.Index

        init(_ text: String) {
            self.text = text
            index = text.startIndex
        }

        mutating func next() -> Substring? {
            skipWhitespace()
            guard index < text.endIndex else { return nil }
            let start = index
            while index < text.endIndex, !text[index].isWhitespace {
                index = text.index(after: index)
            }
            return text[start..<index]
        }

        mutating func remainder() -> Substring? {
            skipWhitespace()
            guard index < text.endIndex else { return nil }
            return text[index...]
        }

        private mutating func skipWhitespace() {
            while index < text.endIndex, text[index].isWhitespace {
                index = text.index(after: index)
            }
        }
    }

    private struct FileSnapshot: Equatable {
        enum Error: Swift.Error {
            case missing
            case inaccessible
        }

        let device: dev_t
        let inode: ino_t
        let mode: mode_t
        let linkCount: nlink_t
        let size: off_t
        let modifiedSeconds: Int
        let modifiedNanoseconds: Int
        let changedSeconds: Int
        let changedNanoseconds: Int

        init(_ metadata: stat) {
            device = metadata.st_dev
            inode = metadata.st_ino
            mode = metadata.st_mode
            linkCount = metadata.st_nlink
            size = metadata.st_size
            modifiedSeconds = metadata.st_mtimespec.tv_sec
            modifiedNanoseconds = metadata.st_mtimespec.tv_nsec
            changedSeconds = metadata.st_ctimespec.tv_sec
            changedNanoseconds = metadata.st_ctimespec.tv_nsec
        }

        init(at url: URL) throws {
            var metadata = stat()
            while true {
                let result = Darwin.lstat(url.path, &metadata)
                if result < 0, errno == EINTR { continue }
                if result < 0, errno == ENOENT { throw Error.missing }
                guard result == 0 else { throw Error.inaccessible }
                self.init(metadata)
                return
            }
        }

        var isDirectory: Bool { (mode & S_IFMT) == S_IFDIR }

        var isSingleLinkedRegularFile: Bool {
            (mode & S_IFMT) == S_IFREG && linkCount == 1 && size >= 0
        }
    }

    private final class StableBinaryReader {
        private let url: URL
        private let descriptor: Int32
        private let initialSnapshot: FileSnapshot
        private let modelOrder: Int
        private var offset: UInt64 = 0

        init(at url: URL, maximumBytes: off_t, modelOrder: Int) throws {
            self.url = url
            self.modelOrder = modelOrder
            var opened: Int32 = -1
            while true {
                opened = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
                if opened < 0, errno == EINTR { continue }
                break
            }
            guard opened >= 0 else {
                throw ColmapSparseModelMembershipReaderError.unsafeModelFile(
                    modelOrder: modelOrder,
                    file: url.lastPathComponent
                )
            }
            descriptor = opened
            do {
                var metadata = stat()
                guard Darwin.fstat(opened, &metadata) == 0 else {
                    throw ColmapSparseModelMembershipReaderError.unsafeModelFile(
                        modelOrder: modelOrder,
                        file: url.lastPathComponent
                    )
                }
                let descriptorSnapshot = FileSnapshot(metadata)
                let pathSnapshot = try FileSnapshot(at: url)
                guard descriptorSnapshot == pathSnapshot,
                      descriptorSnapshot.isSingleLinkedRegularFile,
                      descriptorSnapshot.size <= maximumBytes else {
                    throw ColmapSparseModelMembershipReaderError.unsafeModelFile(
                        modelOrder: modelOrder,
                        file: url.lastPathComponent
                    )
                }
                initialSnapshot = descriptorSnapshot
            } catch {
                Darwin.close(opened)
                throw error
            }
        }

        deinit {
            Darwin.close(descriptor)
        }

        func readUInt32() throws -> UInt32 {
            let bytes = try readExact(4)
            return bytes.enumerated().reduce(UInt32(0)) {
                $0 | UInt32($1.element) << UInt32($1.offset * 8)
            }
        }

        func readUInt64() throws -> UInt64 {
            let bytes = try readExact(8)
            return bytes.enumerated().reduce(UInt64(0)) {
                $0 | UInt64($1.element) << UInt64($1.offset * 8)
            }
        }

        func readDouble() throws -> Double {
            Double(bitPattern: try readUInt64())
        }

        func readName(
            maximumBytes: Int,
            checkCancellation: () throws -> Void
        ) throws -> String {
            var nameBytes: [UInt8] = []
            nameBytes.reserveCapacity(min(maximumBytes, 256))
            while true {
                try checkCancellation()
                let permitted = maximumBytes - nameBytes.count + 1
                guard permitted > 0 else {
                    throw malformed(.nameTooLong)
                }
                let bytes = try readAvailable(min(256, permitted))
                guard !bytes.isEmpty else { throw malformed(.missingNameTerminator) }
                if let terminator = bytes.firstIndex(of: 0) {
                    nameBytes.append(contentsOf: bytes[..<terminator])
                    offset += UInt64(terminator + 1)
                    guard !nameBytes.isEmpty,
                          let name = String(bytes: nameBytes, encoding: .utf8) else {
                        throw malformed(nameBytes.isEmpty ? .invalidUTF8 : .invalidUTF8)
                    }
                    return name
                }
                nameBytes.append(contentsOf: bytes)
                offset += UInt64(bytes.count)
                if nameBytes.count > maximumBytes { throw malformed(.nameTooLong) }
            }
        }

        func skipPointRecords(count: UInt64) throws {
            let (bytes, multiplicationOverflow) = count.multipliedReportingOverflow(by: 24)
            guard !multiplicationOverflow else { throw malformed(.pointCountOverflow) }
            let (end, additionOverflow) = offset.addingReportingOverflow(bytes)
            guard !additionOverflow,
                  end <= UInt64(initialSnapshot.size) else {
                if additionOverflow { throw malformed(.pointCountOverflow) }
                throw malformed(.truncated)
            }
            offset = end
        }

        func requireEndOfFile() throws {
            guard offset == UInt64(initialSnapshot.size) else {
                throw malformed(.trailingBytes)
            }
        }

        func verifyUnchanged() throws {
            var metadata = stat()
            guard Darwin.fstat(descriptor, &metadata) == 0,
                  FileSnapshot(metadata) == initialSnapshot,
                  (try? FileSnapshot(at: url)) == initialSnapshot else {
                throw ColmapSparseModelMembershipReaderError.unsafeModelFile(
                    modelOrder: modelOrder,
                    file: url.lastPathComponent
                )
            }
        }

        private func readExact(_ count: Int) throws -> [UInt8] {
            let bytes = try readAvailable(count)
            guard bytes.count == count else { throw malformed(.truncated) }
            offset += UInt64(count)
            return bytes
        }

        private func readAvailable(_ count: Int) throws -> [UInt8] {
            guard count >= 0,
                  offset <= UInt64(initialSnapshot.size) else {
                throw malformed(.truncated)
            }
            let remaining = UInt64(initialSnapshot.size) - offset
            let requested = min(UInt64(count), remaining)
            guard requested > 0 else { return [] }
            var bytes = [UInt8](repeating: 0, count: Int(requested))
            let byteCount = bytes.count
            var bytesRead = 0
            while bytesRead < byteCount {
                let result = bytes.withUnsafeMutableBytes { buffer in
                    Darwin.pread(
                        descriptor,
                        buffer.baseAddress?.advanced(by: bytesRead),
                        byteCount - bytesRead,
                        off_t(offset) + off_t(bytesRead)
                    )
                }
                if result < 0, errno == EINTR { continue }
                guard result > 0 else { throw malformed(.truncated) }
                bytesRead += result
            }
            return bytes
        }

        private func malformed(
            _ issue: ColmapSparseModelBinaryIssue
        ) -> ColmapSparseModelMembershipReaderError {
            .malformedBinary(modelOrder: modelOrder, issue: issue)
        }
    }
}
