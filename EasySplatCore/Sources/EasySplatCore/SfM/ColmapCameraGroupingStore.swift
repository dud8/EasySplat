import Foundation
import SQLite3

struct ColmapSelectedImageCameraEvidence: Sendable, Equatable {
    let imageName: String
    let sourceGroupID: String
    let isVideo: Bool
}

public enum ColmapCameraGroupingMode: String, Codable, Sendable, Equatable {
    case preserveExisting
    case videoSourceGroups
    case allSelectedImagesShared
}

public struct ColmapCameraGroupReceipt: Codable, Sendable, Equatable {
    public let sourceGroupID: String
    public let memberCount: Int
    public let canonicalCameraID: Int64

    public init(sourceGroupID: String, memberCount: Int, canonicalCameraID: Int64) {
        self.sourceGroupID = sourceGroupID
        self.memberCount = memberCount
        self.canonicalCameraID = canonicalCameraID
    }
}

public struct ColmapCameraGroupingReceipt: Codable, Sendable, Equatable {
    public let mode: ColmapCameraGroupingMode
    public let cameraCountBefore: Int
    public let cameraCountAfter: Int
    public let groupedVideoSourceCount: Int
    public let groups: [ColmapCameraGroupReceipt]

    public init(
        mode: ColmapCameraGroupingMode,
        cameraCountBefore: Int,
        cameraCountAfter: Int,
        groupedVideoSourceCount: Int,
        groups: [ColmapCameraGroupReceipt]
    ) {
        self.mode = mode
        self.cameraCountBefore = cameraCountBefore
        self.cameraCountAfter = cameraCountAfter
        self.groupedVideoSourceCount = groupedVideoSourceCount
        self.groups = groups
    }

    func isValid(selectedImageCount: Int) -> Bool {
        guard selectedImageCount >= 2,
              cameraCountBefore > 0,
              cameraCountAfter > 0,
              cameraCountAfter <= cameraCountBefore,
              groupedVideoSourceCount >= 0,
              groups.allSatisfy({ group in
                  !group.sourceGroupID.isEmpty
                      && group.memberCount > 0
                      && group.canonicalCameraID > 0
              }),
              Set(groups.map(\.sourceGroupID)).count == groups.count,
              Set(groups.map(\.canonicalCameraID)).count == groups.count else {
            return false
        }
        switch mode {
        case .preserveExisting:
            return cameraCountBefore == cameraCountAfter
                && groupedVideoSourceCount == 0
                && groups.isEmpty
        case .videoSourceGroups:
            return groupedVideoSourceCount > 0
                && groups.count == groupedVideoSourceCount
                && groups.reduce(0, { $0 + $1.memberCount }) <= selectedImageCount
                && cameraCountAfter >= groups.count
        case .allSelectedImagesShared:
            return groups.count == 1
                && groups[0].sourceGroupID == "all-selected-images"
                && groups[0].memberCount == selectedImageCount
        }
    }
}

enum ColmapCameraGroupingStoreError: LocalizedError, Equatable {
    case emptySelectedImageSet
    case invalidImageName(String)
    case duplicateSelectedImageName(String)
    case invalidSourceGroupID(String)
    case sourceGroupMediaCollision(String)
    case noVideoSourceGroups
    case unsafeDatabaseFile
    case databaseOpenFailed(code: Int32, message: String)
    case databaseOperationFailed(operation: String, code: Int32, message: String)
    case unsafeSchema(table: String)
    case invalidDatabaseImageName
    case duplicateDatabaseImageName(String)
    case databaseImageSetMismatch(expected: [String], actual: [String])
    case invalidCameraReference(imageName: String, cameraID: Int64)
    case invalidCameraRecord(cameraID: Int64)
    case invalidCameraRelation(imageName: String)
    case invalidRigRecord(rigID: Int64)
    case receiptMismatch
    case cameraSharedAcrossSourceGroups(cameraID: Int64)
    case incompatibleCameras(
        sourceGroupID: String,
        canonicalCameraID: Int64,
        incompatibleCameraID: Int64
    )

    var errorDescription: String? {
        switch self {
        case .emptySelectedImageSet:
            return "The selected-frame camera evidence is empty."
        case .invalidImageName(let name):
            return "The selected-frame camera evidence contains an invalid image name: \(name)."
        case .duplicateSelectedImageName(let name):
            return "The selected-frame camera evidence maps \(name) more than once."
        case .invalidSourceGroupID(let groupID):
            return "The selected-frame camera evidence contains an invalid source group: \(groupID)."
        case .sourceGroupMediaCollision(let groupID):
            return "Source group \(groupID) contains both video frames and photos."
        case .noVideoSourceGroups:
            return "The selected-frame camera evidence contains no video source groups."
        case .unsafeDatabaseFile:
            return "The COLMAP database must be a stable, ordinary file."
        case let .databaseOpenFailed(code, message):
            return "Could not open the COLMAP database (SQLite \(code)): \(message)"
        case let .databaseOperationFailed(operation, code, message):
            return "Could not \(operation) in the COLMAP database (SQLite \(code)): \(message)"
        case .unsafeSchema(let table):
            return "The COLMAP database has an invalid or unsafe \(table) table."
        case .invalidDatabaseImageName:
            return "The COLMAP database contains an invalid image name."
        case .duplicateDatabaseImageName(let name):
            return "The COLMAP database contains \(name) more than once."
        case let .databaseImageSetMismatch(expected, actual):
            return "The COLMAP database image set does not match the selected-frame evidence (expected \(expected), found \(actual))."
        case let .invalidCameraReference(imageName, cameraID):
            return "COLMAP image \(imageName) refers to missing camera \(cameraID)."
        case .invalidCameraRecord(let cameraID):
            return "The COLMAP database contains an invalid camera record: \(cameraID)."
        case .invalidCameraRelation(let imageName):
            return "COLMAP image \(imageName) has an inconsistent camera, frame, or pose-prior assignment."
        case .invalidRigRecord(let rigID):
            return "The COLMAP database contains an unsupported or inconsistent camera rig: \(rigID)."
        case .receiptMismatch:
            return "The COLMAP camera grouping receipt does not match the selected frames or database."
        case .cameraSharedAcrossSourceGroups(let cameraID):
            return "COLMAP camera \(cameraID) is already shared across source groups."
        case let .incompatibleCameras(groupID, canonicalID, incompatibleID):
            return "Source group \(groupID) contains incompatible cameras \(canonicalID) and \(incompatibleID)."
        }
    }
}

enum ColmapCameraGroupingStore {
    private static let maximumNameBytes = 4_096
    // This table mirrors the camera IDs and parameter cardinalities at the
    // repository's pinned COLMAP 4.1.1 commit a0d785f. A model outside this
    // closure cannot be safely coalesced by byte comparison alone.
    private static let cameraModelParameterCounts: [Int64: (total: Int, focal: Int)] = [
        0: (3, 1),
        1: (4, 2),
        2: (4, 1),
        3: (5, 1),
        4: (8, 2),
        5: (8, 2),
        6: (12, 2),
        7: (5, 2),
        8: (4, 1),
        9: (5, 1),
        10: (12, 2),
        11: (16, 2),
        12: (4, 1),
        13: (5, 2),
        14: (3, 1),
        15: (4, 2),
        16: (6, 2),
        17: (2, 0),
    ]

    static func normalize(
        databaseURL: URL,
        selectedImages: [ColmapSelectedImageCameraEvidence],
        mode: ColmapCameraGroupingMode,
        checkCancellation: () throws -> Void = { try Task.checkCancellation() }
    ) throws -> ColmapCameraGroupingReceipt {
        let evidence = try validatedEvidence(selectedImages, checkCancellation: checkCancellation)
        let handle = try openDatabase(at: databaseURL)
        let database = handle.database
        sqlite3_extended_result_codes(database, 1)
        let timeoutResult = sqlite3_busy_timeout(database, 5_000)
        guard timeoutResult == SQLITE_OK else {
            throw operationFailure("set the write timeout", database: database, code: timeoutResult)
        }

        try execute(
            "BEGIN IMMEDIATE TRANSACTION;",
            operation: "begin camera grouping",
            in: database
        )
        var transactionIsOpen = true
        defer {
            if transactionIsOpen {
                sqlite3_exec(database, "ROLLBACK;", nil, nil, nil)
            }
        }

        do {
            try checkCancellation()
            try verifyUnchanged(handle)
            try validateSchema(database, checkCancellation: checkCancellation)
            let images = try readImages(database, checkCancellation: checkCancellation)
            let expectedNames = evidence.map(\.imageName).sorted()
            let actualNames = images.map(\.name).sorted()
            guard expectedNames == actualNames else {
                throw ColmapCameraGroupingStoreError.databaseImageSetMismatch(
                    expected: expectedNames,
                    actual: actualNames
                )
            }
            let cameras = try readCameras(database, checkCancellation: checkCancellation)
            for image in images where cameras[image.cameraID] == nil {
                throw ColmapCameraGroupingStoreError.invalidCameraReference(
                    imageName: image.name,
                    cameraID: image.cameraID
                )
            }
            let cameraCountBefore = cameras.count
            let imagesByName = Dictionary(uniqueKeysWithValues: images.map { ($0.name, $0) })
            let groups = try targetGroups(for: evidence, mode: mode)
            let references = Dictionary(grouping: images, by: \.cameraID)

            var receipts: [ColmapCameraGroupReceipt] = []
            var obsoleteCameraIDs = Set<Int64>()
            var obsoleteRigIDs = Set<Int64>()
            for group in groups {
                try checkCancellation()
                let members = group.imageNames.compactMap { imagesByName[$0] }
                let memberNames = Set(group.imageNames)
                let cameraIDs = Set(members.map(\.cameraID))
                guard let canonicalCameraID = cameraIDs.min(),
                      let canonicalCamera = cameras[canonicalCameraID],
                      let canonicalMember = members.first(where: {
                          $0.cameraID == canonicalCameraID
                      }) else {
                    throw ColmapCameraGroupingStoreError.invalidCameraReference(
                        imageName: group.imageNames[0],
                        cameraID: members.first?.cameraID ?? 0
                    )
                }
                for cameraID in cameraIDs.sorted() {
                    guard let camera = cameras[cameraID] else {
                        let imageName = members.first(where: { $0.cameraID == cameraID })?.name
                            ?? group.imageNames[0]
                        throw ColmapCameraGroupingStoreError.invalidCameraReference(
                            imageName: imageName,
                            cameraID: cameraID
                        )
                    }
                    if mode == .videoSourceGroups,
                       !(references[cameraID] ?? []).allSatisfy({ memberNames.contains($0.name) }) {
                        throw ColmapCameraGroupingStoreError.cameraSharedAcrossSourceGroups(
                            cameraID: cameraID
                        )
                    }
                    guard camera.signature == canonicalCamera.signature else {
                        throw ColmapCameraGroupingStoreError.incompatibleCameras(
                            sourceGroupID: group.sourceGroupID,
                            canonicalCameraID: canonicalCameraID,
                            incompatibleCameraID: cameraID
                        )
                    }
                }

                for member in members where member.cameraID != canonicalCameraID
                    || member.rigID != canonicalMember.rigID {
                    try checkCancellation()
                    try updateCamera(
                        canonicalCameraID,
                        canonicalRigID: canonicalMember.rigID,
                        for: member,
                        in: database
                    )
                    if member.cameraID != canonicalCameraID {
                        obsoleteCameraIDs.insert(member.cameraID)
                    }
                    if member.rigID != canonicalMember.rigID {
                        obsoleteRigIDs.insert(member.rigID)
                    }
                }
                receipts.append(ColmapCameraGroupReceipt(
                    sourceGroupID: group.sourceGroupID,
                    memberCount: members.count,
                    canonicalCameraID: canonicalCameraID
                ))
            }

            for rigID in obsoleteRigIDs.sorted() {
                try checkCancellation()
                try deleteRigIfUnreferenced(rigID, in: database)
            }
            for cameraID in obsoleteCameraIDs.sorted() {
                try checkCancellation()
                try deleteCameraIfUnreferenced(cameraID, in: database)
            }
            try checkCancellation()
            let normalizedImages = try readImages(
                database,
                checkCancellation: checkCancellation
            )
            try verifyTargets(
                groups,
                receipts: receipts,
                images: normalizedImages
            )
            let cameraCountAfter = try cameraCount(database)
            try checkCancellation()
            try verifyUnchanged(handle)
            try execute("COMMIT;", operation: "commit camera grouping", in: database)
            transactionIsOpen = false
            try verifyUnchanged(handle)
            return ColmapCameraGroupingReceipt(
                mode: mode,
                cameraCountBefore: cameraCountBefore,
                cameraCountAfter: cameraCountAfter,
                groupedVideoSourceCount: Set(
                    evidence.lazy.filter(\.isVideo).map(\.sourceGroupID)
                ).count,
                groups: receipts
            )
        } catch {
            try? execute("ROLLBACK;", operation: "roll back camera grouping", in: database)
            transactionIsOpen = false
            throw error
        }
    }

    static func verify(
        databaseURL: URL,
        selectedImages: [ColmapSelectedImageCameraEvidence],
        expectedMode: ColmapCameraGroupingMode,
        expectedReceipt: ColmapCameraGroupingReceipt,
        checkCancellation: () throws -> Void = { try Task.checkCancellation() }
    ) throws -> ColmapCameraGroupingReceipt {
        let evidence = try validatedEvidence(selectedImages, checkCancellation: checkCancellation)
        guard expectedReceipt.mode == expectedMode,
              expectedReceipt.isValid(selectedImageCount: evidence.count) else {
            throw ColmapCameraGroupingStoreError.receiptMismatch
        }
        let handle = try openDatabase(at: databaseURL)
        let database = handle.database
        sqlite3_extended_result_codes(database, 1)
        let timeoutResult = sqlite3_busy_timeout(database, 5_000)
        guard timeoutResult == SQLITE_OK else {
            throw operationFailure("set the read timeout", database: database, code: timeoutResult)
        }
        try execute(
            "BEGIN TRANSACTION;",
            operation: "begin camera grouping verification",
            in: database
        )
        var transactionIsOpen = true
        defer {
            if transactionIsOpen {
                sqlite3_exec(database, "ROLLBACK;", nil, nil, nil)
            }
        }

        do {
            try checkCancellation()
            try verifyUnchanged(handle)
            let result = try verify(
                in: database,
                evidence: evidence,
                expectedMode: expectedMode,
                expectedReceipt: expectedReceipt,
                checkCancellation: checkCancellation
            )
            try checkCancellation()
            try verifyUnchanged(handle)
            try execute(
                "COMMIT;",
                operation: "commit camera grouping verification",
                in: database
            )
            transactionIsOpen = false
            try verifyUnchanged(handle)
            return result
        } catch {
            try? execute(
                "ROLLBACK;",
                operation: "roll back camera grouping verification",
                in: database
            )
            transactionIsOpen = false
            throw error
        }
    }

    static func verify(
        in database: OpaquePointer,
        selectedImages: [ColmapSelectedImageCameraEvidence],
        expectedMode: ColmapCameraGroupingMode,
        expectedReceipt: ColmapCameraGroupingReceipt,
        checkCancellation: () throws -> Void = { try Task.checkCancellation() }
    ) throws -> ColmapCameraGroupingReceipt {
        let evidence = try validatedEvidence(
            selectedImages,
            checkCancellation: checkCancellation
        )
        guard expectedReceipt.mode == expectedMode,
              expectedReceipt.isValid(selectedImageCount: evidence.count) else {
            throw ColmapCameraGroupingStoreError.receiptMismatch
        }
        return try verify(
            in: database,
            evidence: evidence,
            expectedMode: expectedMode,
            expectedReceipt: expectedReceipt,
            checkCancellation: checkCancellation
        )
    }

    private static func verify(
        in database: OpaquePointer,
        evidence: [ValidatedEvidence],
        expectedMode: ColmapCameraGroupingMode,
        expectedReceipt: ColmapCameraGroupingReceipt,
        checkCancellation: () throws -> Void
    ) throws -> ColmapCameraGroupingReceipt {
        try validateSchema(database, checkCancellation: checkCancellation)
        let images = try readImages(database, checkCancellation: checkCancellation)
        guard images.map(\.name).sorted() == evidence.map(\.imageName).sorted() else {
            throw ColmapCameraGroupingStoreError.receiptMismatch
        }
        let cameras = try readCameras(database, checkCancellation: checkCancellation)
        guard cameras.count == expectedReceipt.cameraCountAfter else {
            throw ColmapCameraGroupingStoreError.receiptMismatch
        }
        let imagesByName = Dictionary(uniqueKeysWithValues: images.map { ($0.name, $0) })
        let references = Dictionary(grouping: images, by: \.cameraID)
        let targets = try targetGroups(for: evidence, mode: expectedMode)
        guard targets.count == expectedReceipt.groups.count,
              expectedReceipt.groupedVideoSourceCount == Set(
                  evidence.lazy.filter(\.isVideo).map(\.sourceGroupID)
              ).count else {
            throw ColmapCameraGroupingStoreError.receiptMismatch
        }
        for (target, receipt) in zip(targets, expectedReceipt.groups) {
            try checkCancellation()
            guard target.sourceGroupID == receipt.sourceGroupID,
                  target.imageNames.count == receipt.memberCount else {
                throw ColmapCameraGroupingStoreError.receiptMismatch
            }
            let members = target.imageNames.compactMap { imagesByName[$0] }
            guard members.count == target.imageNames.count,
                  Set(members.map(\.cameraID)) == [receipt.canonicalCameraID],
                  cameras[receipt.canonicalCameraID] != nil else {
                throw ColmapCameraGroupingStoreError.receiptMismatch
            }
            if expectedMode == .videoSourceGroups {
                let memberNames = Set(target.imageNames)
                guard (references[receipt.canonicalCameraID] ?? []).allSatisfy({
                    memberNames.contains($0.name)
                }) else {
                    throw ColmapCameraGroupingStoreError.receiptMismatch
                }
            }
        }
        try verifyTargets(
            targets,
            receipts: expectedReceipt.groups,
            images: images
        )
        return expectedReceipt
    }

    private struct ValidatedEvidence {
        let imageName: String
        let sourceGroupID: String
        let isVideo: Bool
    }

    private struct DatabaseImage {
        let imageID: Int64
        let name: String
        let cameraID: Int64
        let frameID: Int64
        let rigID: Int64
    }

    private struct CameraSignature: Equatable {
        let model: Int64
        let width: Int64
        let height: Int64
        let parameters: Data
        let hasPriorFocalLength: Bool
    }

    private struct DatabaseCamera {
        let signature: CameraSignature
    }

    private struct TargetGroup {
        let sourceGroupID: String
        let imageNames: [String]
    }

    private struct SchemaColumn {
        let type: String
        let primaryKeyOrder: Int64
    }

    private static func validatedEvidence(
        _ selectedImages: [ColmapSelectedImageCameraEvidence],
        checkCancellation: () throws -> Void
    ) throws -> [ValidatedEvidence] {
        guard !selectedImages.isEmpty else {
            throw ColmapCameraGroupingStoreError.emptySelectedImageSet
        }
        var names = Set<String>()
        var mediaByGroup: [String: Bool] = [:]
        var result: [ValidatedEvidence] = []
        result.reserveCapacity(selectedImages.count)
        for image in selectedImages {
            try checkCancellation()
            guard !image.imageName.isEmpty,
                  image.imageName.utf8.count <= maximumNameBytes,
                  !image.imageName.contains("\0") else {
                throw ColmapCameraGroupingStoreError.invalidImageName(image.imageName)
            }
            guard names.insert(image.imageName).inserted else {
                throw ColmapCameraGroupingStoreError.duplicateSelectedImageName(image.imageName)
            }
            guard !image.sourceGroupID.isEmpty,
                  image.sourceGroupID.utf8.count <= maximumNameBytes,
                  !image.sourceGroupID.contains("\0") else {
                throw ColmapCameraGroupingStoreError.invalidSourceGroupID(image.sourceGroupID)
            }
            if let isVideo = mediaByGroup[image.sourceGroupID],
               isVideo != image.isVideo {
                throw ColmapCameraGroupingStoreError.sourceGroupMediaCollision(
                    image.sourceGroupID
                )
            }
            mediaByGroup[image.sourceGroupID] = image.isVideo
            result.append(ValidatedEvidence(
                imageName: image.imageName,
                sourceGroupID: image.sourceGroupID,
                isVideo: image.isVideo
            ))
        }
        return result
    }

    private static func targetGroups(
        for evidence: [ValidatedEvidence],
        mode: ColmapCameraGroupingMode
    ) throws -> [TargetGroup] {
        switch mode {
        case .preserveExisting:
            return []
        case .videoSourceGroups:
            let videos = evidence.filter(\.isVideo)
            guard !videos.isEmpty else {
                throw ColmapCameraGroupingStoreError.noVideoSourceGroups
            }
            return Dictionary(grouping: videos, by: \.sourceGroupID)
                .map { groupID, members in
                    TargetGroup(
                        sourceGroupID: groupID,
                        imageNames: members.map(\.imageName).sorted()
                    )
                }
                .sorted { $0.sourceGroupID < $1.sourceGroupID }
        case .allSelectedImagesShared:
            return [TargetGroup(
                sourceGroupID: "all-selected-images",
                imageNames: evidence.map(\.imageName).sorted()
            )]
        }
    }

    private static func openDatabase(at databaseURL: URL) throws -> ColmapSQLiteDatabaseHandle {
        do {
            return try ColmapSQLiteDatabaseHandle.open(
                at: databaseURL,
                flags: SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
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

    private static func mapped(_ error: Error) -> ColmapCameraGroupingStoreError {
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
            return .databaseOpenFailed(code: SQLITE_ERROR, message: error.localizedDescription)
        }
    }

    private static func readImages(
        _ database: OpaquePointer,
        checkCancellation: () throws -> Void
    ) throws -> [DatabaseImage] {
        let statement = try prepare(
            "SELECT i.image_id, i.name, i.camera_id, fd.frame_id, fd.sensor_id, "
                + "f.rig_id, r.ref_sensor_id, r.ref_sensor_type, "
                + "(SELECT COUNT(*) FROM frame_data x "
                + "WHERE x.data_id = i.image_id AND x.sensor_type = 0), "
                + "(SELECT COUNT(*) FROM frame_data x WHERE x.frame_id = fd.frame_id), "
                + "(SELECT COUNT(*) FROM rig_sensors x WHERE x.rig_id = f.rig_id), "
                + "(SELECT COUNT(*) FROM rig_sensors x WHERE x.rig_id = f.rig_id "
                + "AND x.sensor_id = fd.sensor_id AND x.sensor_type = 0), "
                + "(SELECT COUNT(*) FROM pose_priors x WHERE x.corr_data_id = i.image_id), "
                + "(SELECT COUNT(*) FROM pose_priors x WHERE x.corr_data_id = i.image_id "
                + "AND x.corr_sensor_id = i.camera_id AND x.corr_sensor_type = 0) "
                + "FROM images i LEFT JOIN frame_data fd "
                + "ON fd.data_id = i.image_id AND fd.sensor_type = 0 "
                + "LEFT JOIN frames f ON f.frame_id = fd.frame_id "
                + "LEFT JOIN rigs r ON r.rig_id = f.rig_id ORDER BY i.image_id;",
            operation: "read image camera assignments",
            in: database
        )
        defer { sqlite3_finalize(statement) }
        var images: [DatabaseImage] = []
        var names = Set<String>()
        while true {
            try checkCancellation()
            let result = sqlite3_step(statement)
            if result == SQLITE_DONE { break }
            guard result == SQLITE_ROW,
                  sqlite3_column_type(statement, 0) == SQLITE_INTEGER,
                  sqlite3_column_type(statement, 1) == SQLITE_TEXT,
                  sqlite3_column_type(statement, 2) == SQLITE_INTEGER,
                  (3...13).allSatisfy({
                      sqlite3_column_type(statement, Int32($0)) == SQLITE_INTEGER
                  }),
                  let nameBytes = sqlite3_column_text(statement, 1) else {
                throw operationFailure(
                    "read image camera assignments",
                    database: database,
                    code: result
                )
            }
            let byteCount = Int(sqlite3_column_bytes(statement, 1))
            let bytes = UnsafeBufferPointer(start: nameBytes, count: byteCount)
            guard byteCount > 0,
                  byteCount <= maximumNameBytes,
                  !bytes.contains(0),
                  let name = String(bytes: bytes, encoding: .utf8) else {
                throw ColmapCameraGroupingStoreError.invalidDatabaseImageName
            }
            guard names.insert(name).inserted else {
                throw ColmapCameraGroupingStoreError.duplicateDatabaseImageName(name)
            }
            let imageID = sqlite3_column_int64(statement, 0)
            let cameraID = sqlite3_column_int64(statement, 2)
            let frameID = sqlite3_column_int64(statement, 3)
            let frameSensorID = sqlite3_column_int64(statement, 4)
            let rigID = sqlite3_column_int64(statement, 5)
            let refSensorID = sqlite3_column_int64(statement, 6)
            let refSensorType = sqlite3_column_int64(statement, 7)
            let cameraFrameDataCount = sqlite3_column_int64(statement, 8)
            let frameDataCount = sqlite3_column_int64(statement, 9)
            let rigSensorCount = sqlite3_column_int64(statement, 10)
            let matchingRigSensorCount = sqlite3_column_int64(statement, 11)
            let posePriorCount = sqlite3_column_int64(statement, 12)
            let matchingPosePriorCount = sqlite3_column_int64(statement, 13)
            guard imageID > 0,
                  cameraID > 0,
                  frameID > 0,
                  rigID > 0,
                  cameraID == frameSensorID,
                  cameraID == refSensorID,
                  refSensorType == 0,
                  cameraFrameDataCount == 1,
                  frameDataCount == 1,
                  rigSensorCount == 0,
                  matchingRigSensorCount == 0,
                  posePriorCount == 0 || posePriorCount == 1,
                  matchingPosePriorCount == posePriorCount else {
                throw ColmapCameraGroupingStoreError.invalidCameraRelation(
                    imageName: name
                )
            }
            images.append(DatabaseImage(
                imageID: imageID,
                name: name,
                cameraID: cameraID,
                frameID: frameID,
                rigID: rigID
            ))
        }
        return images
    }

    private static func validateSchema(
        _ database: OpaquePointer,
        checkCancellation: () throws -> Void
    ) throws {
        let required: [(table: String, columns: [String: (type: String, primaryKey: Bool)])] = [
            (
                table: "cameras",
                columns: [
                    "camera_id": ("INTEGER", true),
                    "model": ("INTEGER", false),
                    "width": ("INTEGER", false),
                    "height": ("INTEGER", false),
                    "params": ("BLOB", false),
                    "prior_focal_length": ("INTEGER", false),
                ]
            ),
            (
                table: "images",
                columns: [
                    "image_id": ("INTEGER", true),
                    "name": ("TEXT", false),
                    "camera_id": ("INTEGER", false),
                ]
            ),
            (
                table: "rigs",
                columns: [
                    "rig_id": ("INTEGER", true),
                    "ref_sensor_id": ("INTEGER", false),
                    "ref_sensor_type": ("INTEGER", false),
                ]
            ),
            (
                table: "rig_sensors",
                columns: [
                    "rig_id": ("INTEGER", false),
                    "sensor_id": ("INTEGER", false),
                    "sensor_type": ("INTEGER", false),
                    "sensor_from_rig": ("BLOB", false),
                ]
            ),
            (
                table: "frames",
                columns: [
                    "frame_id": ("INTEGER", true),
                    "rig_id": ("INTEGER", false),
                ]
            ),
            (
                table: "frame_data",
                columns: [
                    "frame_id": ("INTEGER", false),
                    "data_id": ("INTEGER", false),
                    "sensor_id": ("INTEGER", false),
                    "sensor_type": ("INTEGER", false),
                ]
            ),
            (
                table: "pose_priors",
                columns: [
                    "pose_prior_id": ("INTEGER", true),
                    "corr_data_id": ("INTEGER", false),
                    "corr_sensor_id": ("INTEGER", false),
                    "corr_sensor_type": ("INTEGER", false),
                    "position": ("BLOB", false),
                    "position_covariance": ("BLOB", false),
                    "gravity": ("BLOB", false),
                    "coordinate_system": ("INTEGER", false),
                ]
            ),
        ]
        for table in required {
            try checkCancellation()
            let columns = try schemaColumns(table: table.table, in: database)
            guard table.columns.allSatisfy({ name, expected in
                guard let actual = columns[name],
                      actual.type == expected.type else {
                    return false
                }
                return !expected.primaryKey || actual.primaryKeyOrder == 1
            }) else {
                throw ColmapCameraGroupingStoreError.unsafeSchema(table: table.table)
            }
        }
        let uniqueIndices: [(table: String, columns: [String])] = [
            ("rigs", ["ref_sensor_id", "ref_sensor_type"]),
            ("rig_sensors", ["sensor_id", "sensor_type"]),
            ("frame_data", ["data_id", "sensor_type"]),
            ("images", ["name"]),
            ("pose_priors", ["corr_data_id", "corr_sensor_id", "corr_sensor_type"]),
        ]
        for contract in uniqueIndices {
            try checkCancellation()
            guard try hasUniqueIndex(
                table: contract.table,
                columns: contract.columns,
                in: database
            ) else {
                throw ColmapCameraGroupingStoreError.unsafeSchema(table: contract.table)
            }
        }
    }

    private static func hasUniqueIndex(
        table: String,
        columns: [String],
        in database: OpaquePointer
    ) throws -> Bool {
        let statement = try prepare(
            "SELECT name FROM pragma_index_list(?) "
                + "WHERE \"unique\" = 1 AND partial = 0 ORDER BY name;",
            operation: "inspect the \(table) indices",
            in: database
        )
        defer { sqlite3_finalize(statement) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        guard table.withCString({
            sqlite3_bind_text(statement, 1, $0, -1, transient)
        }) == SQLITE_OK else {
            throw operationFailure("inspect the \(table) indices", database: database)
        }
        while true {
            let result = sqlite3_step(statement)
            if result == SQLITE_DONE { break }
            guard result == SQLITE_ROW,
                  sqlite3_column_type(statement, 0) == SQLITE_TEXT,
                  let nameBytes = sqlite3_column_text(statement, 0) else {
                throw operationFailure(
                    "inspect the \(table) indices",
                    database: database,
                    code: result
                )
            }
            let name = String(cString: nameBytes)
            guard !name.isEmpty,
                  name.utf8.count <= maximumNameBytes else {
                throw ColmapCameraGroupingStoreError.unsafeSchema(table: table)
            }
            if try indexColumns(name: name, table: table, in: database) == columns {
                return true
            }
        }
        return false
    }

    private static func indexColumns(
        name: String,
        table: String,
        in database: OpaquePointer
    ) throws -> [String] {
        let statement = try prepare(
            "SELECT name FROM pragma_index_info(?) ORDER BY seqno;",
            operation: "inspect an index on \(table)",
            in: database
        )
        defer { sqlite3_finalize(statement) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        guard name.withCString({
            sqlite3_bind_text(statement, 1, $0, -1, transient)
        }) == SQLITE_OK else {
            throw operationFailure("inspect an index on \(table)", database: database)
        }
        var columns: [String] = []
        while true {
            let result = sqlite3_step(statement)
            if result == SQLITE_DONE { break }
            guard result == SQLITE_ROW,
                  sqlite3_column_type(statement, 0) == SQLITE_TEXT,
                  let bytes = sqlite3_column_text(statement, 0) else {
                throw operationFailure(
                    "inspect an index on \(table)",
                    database: database,
                    code: result
                )
            }
            columns.append(String(cString: bytes))
        }
        return columns
    }

    private static func schemaColumns(
        table: String,
        in database: OpaquePointer
    ) throws -> [String: SchemaColumn] {
        let statement = try prepare(
            "PRAGMA table_info(\(table));",
            operation: "inspect the \(table) schema",
            in: database
        )
        defer { sqlite3_finalize(statement) }
        var columns: [String: SchemaColumn] = [:]
        while true {
            let result = sqlite3_step(statement)
            if result == SQLITE_DONE { break }
            guard result == SQLITE_ROW,
                  sqlite3_column_type(statement, 1) == SQLITE_TEXT,
                  sqlite3_column_type(statement, 2) == SQLITE_TEXT,
                  let nameBytes = sqlite3_column_text(statement, 1),
                  let typeBytes = sqlite3_column_text(statement, 2) else {
                throw ColmapCameraGroupingStoreError.unsafeSchema(table: table)
            }
            let name = String(cString: nameBytes)
            let column = SchemaColumn(
                type: String(cString: typeBytes).uppercased(),
                primaryKeyOrder: sqlite3_column_int64(statement, 5)
            )
            guard columns.updateValue(column, forKey: name) == nil else {
                throw ColmapCameraGroupingStoreError.unsafeSchema(table: table)
            }
        }
        return columns
    }

    private static func readCameras(
        _ database: OpaquePointer,
        checkCancellation: () throws -> Void
    ) throws -> [Int64: DatabaseCamera] {
        let statement = try prepare(
            "SELECT camera_id, model, width, height, params, prior_focal_length "
                + "FROM cameras ORDER BY camera_id;",
            operation: "read camera records",
            in: database
        )
        defer { sqlite3_finalize(statement) }
        var cameras: [Int64: DatabaseCamera] = [:]
        while true {
            try checkCancellation()
            let result = sqlite3_step(statement)
            if result == SQLITE_DONE { break }
            guard result == SQLITE_ROW,
                  (0...3).allSatisfy({ sqlite3_column_type(statement, Int32($0)) == SQLITE_INTEGER }),
                  sqlite3_column_type(statement, 4) == SQLITE_BLOB,
                  sqlite3_column_type(statement, 5) == SQLITE_INTEGER else {
                throw operationFailure("read camera records", database: database, code: result)
            }
            let cameraID = sqlite3_column_int64(statement, 0)
            let model = sqlite3_column_int64(statement, 1)
            let width = sqlite3_column_int64(statement, 2)
            let height = sqlite3_column_int64(statement, 3)
            let byteCount = Int(sqlite3_column_bytes(statement, 4))
            let priorFocalLength = sqlite3_column_int64(statement, 5)
            guard cameraID > 0,
                  let modelContract = cameraModelParameterCounts[model],
                  width > 0,
                  height > 0,
                  byteCount == modelContract.total * MemoryLayout<UInt64>.size,
                  priorFocalLength == 0 || priorFocalLength == 1,
                  let bytes = sqlite3_column_blob(statement, 4) else {
                throw ColmapCameraGroupingStoreError.invalidCameraRecord(cameraID: cameraID)
            }
            let parameters = Data(bytes: bytes, count: byteCount)
            let values = parameters.withUnsafeBytes { rawBuffer in
                (0..<modelContract.total).map { index in
                    let bits = rawBuffer.loadUnaligned(
                        fromByteOffset: index * MemoryLayout<UInt64>.size,
                        as: UInt64.self
                    )
                    return Double(bitPattern: UInt64(littleEndian: bits))
                }
            }
            guard values.allSatisfy(\.isFinite),
                  values.prefix(modelContract.focal).allSatisfy({ $0 > 0 }) else {
                throw ColmapCameraGroupingStoreError.invalidCameraRecord(cameraID: cameraID)
            }
            let signature = CameraSignature(
                model: model,
                width: width,
                height: height,
                parameters: parameters,
                hasPriorFocalLength: priorFocalLength == 1
            )
            guard cameras.updateValue(DatabaseCamera(signature: signature), forKey: cameraID) == nil else {
                throw ColmapCameraGroupingStoreError.invalidCameraRecord(cameraID: cameraID)
            }
        }
        return cameras
    }

    private static func updateCamera(
        _ cameraID: Int64,
        canonicalRigID: Int64,
        for image: DatabaseImage,
        in database: OpaquePointer
    ) throws {
        var statement = try prepare(
            "UPDATE images SET camera_id = ? WHERE image_id = ?;",
            operation: "update image camera assignment",
            in: database
        )
        guard sqlite3_bind_int64(statement, 1, cameraID) == SQLITE_OK,
              sqlite3_bind_int64(statement, 2, image.imageID) == SQLITE_OK,
              sqlite3_step(statement) == SQLITE_DONE,
              sqlite3_changes(database) == 1 else {
            sqlite3_finalize(statement)
            throw operationFailure("update image camera assignment", database: database)
        }
        sqlite3_finalize(statement)

        statement = try prepare(
            "UPDATE frame_data SET sensor_id = ? "
                + "WHERE frame_id = ? AND data_id = ? AND sensor_type = 0;",
            operation: "update frame camera assignment",
            in: database
        )
        guard sqlite3_bind_int64(statement, 1, cameraID) == SQLITE_OK,
              sqlite3_bind_int64(statement, 2, image.frameID) == SQLITE_OK,
              sqlite3_bind_int64(statement, 3, image.imageID) == SQLITE_OK,
              sqlite3_step(statement) == SQLITE_DONE,
              sqlite3_changes(database) == 1 else {
            sqlite3_finalize(statement)
            throw operationFailure("update frame camera assignment", database: database)
        }
        sqlite3_finalize(statement)

        statement = try prepare(
            "UPDATE frames SET rig_id = ? WHERE frame_id = ?;",
            operation: "update frame rig assignment",
            in: database
        )
        guard sqlite3_bind_int64(statement, 1, canonicalRigID) == SQLITE_OK,
              sqlite3_bind_int64(statement, 2, image.frameID) == SQLITE_OK,
              sqlite3_step(statement) == SQLITE_DONE,
              sqlite3_changes(database) == 1 else {
            sqlite3_finalize(statement)
            throw operationFailure("update frame rig assignment", database: database)
        }
        sqlite3_finalize(statement)

        statement = try prepare(
            "UPDATE pose_priors SET corr_sensor_id = ? "
                + "WHERE corr_data_id = ? AND corr_sensor_type = 0;",
            operation: "update pose-prior camera assignment",
            in: database
        )
        guard sqlite3_bind_int64(statement, 1, cameraID) == SQLITE_OK,
              sqlite3_bind_int64(statement, 2, image.imageID) == SQLITE_OK,
              sqlite3_step(statement) == SQLITE_DONE,
              sqlite3_changes(database) <= 1 else {
            sqlite3_finalize(statement)
            throw operationFailure("update pose-prior camera assignment", database: database)
        }
        sqlite3_finalize(statement)
    }

    private static func deleteRigIfUnreferenced(
        _ rigID: Int64,
        in database: OpaquePointer
    ) throws {
        var statement = try prepare(
            "DELETE FROM rig_sensors WHERE rig_id = ? "
                + "AND NOT EXISTS (SELECT 1 FROM frames WHERE rig_id = ?);",
            operation: "delete unreferenced rig sensors",
            in: database
        )
        guard sqlite3_bind_int64(statement, 1, rigID) == SQLITE_OK,
              sqlite3_bind_int64(statement, 2, rigID) == SQLITE_OK,
              sqlite3_step(statement) == SQLITE_DONE,
              sqlite3_changes(database) == 0 else {
            sqlite3_finalize(statement)
            throw ColmapCameraGroupingStoreError.invalidRigRecord(rigID: rigID)
        }
        sqlite3_finalize(statement)

        statement = try prepare(
            "DELETE FROM rigs WHERE rig_id = ? "
                + "AND NOT EXISTS (SELECT 1 FROM frames WHERE rig_id = ?);",
            operation: "delete an unreferenced rig",
            in: database
        )
        guard sqlite3_bind_int64(statement, 1, rigID) == SQLITE_OK,
              sqlite3_bind_int64(statement, 2, rigID) == SQLITE_OK,
              sqlite3_step(statement) == SQLITE_DONE,
              sqlite3_changes(database) == 1 else {
            sqlite3_finalize(statement)
            throw ColmapCameraGroupingStoreError.invalidRigRecord(rigID: rigID)
        }
        sqlite3_finalize(statement)
    }

    private static func deleteCameraIfUnreferenced(
        _ cameraID: Int64,
        in database: OpaquePointer
    ) throws {
        let statement = try prepare(
            "DELETE FROM cameras WHERE camera_id = ? "
                + "AND NOT EXISTS (SELECT 1 FROM images WHERE camera_id = ?) "
                + "AND NOT EXISTS (SELECT 1 FROM rig_sensors "
                + "WHERE sensor_id = ? AND sensor_type = 0) "
                + "AND NOT EXISTS (SELECT 1 FROM frame_data "
                + "WHERE sensor_id = ? AND sensor_type = 0) "
                + "AND NOT EXISTS (SELECT 1 FROM pose_priors "
                + "WHERE corr_sensor_id = ? AND corr_sensor_type = 0) "
                + "AND NOT EXISTS (SELECT 1 FROM rigs "
                + "WHERE ref_sensor_id = ? AND ref_sensor_type = 0);",
            operation: "delete an unreferenced camera",
            in: database
        )
        defer { sqlite3_finalize(statement) }
        guard sqlite3_bind_int64(statement, 1, cameraID) == SQLITE_OK,
              sqlite3_bind_int64(statement, 2, cameraID) == SQLITE_OK,
              sqlite3_bind_int64(statement, 3, cameraID) == SQLITE_OK,
              sqlite3_bind_int64(statement, 4, cameraID) == SQLITE_OK,
              sqlite3_bind_int64(statement, 5, cameraID) == SQLITE_OK,
              sqlite3_bind_int64(statement, 6, cameraID) == SQLITE_OK,
              sqlite3_step(statement) == SQLITE_DONE,
              sqlite3_changes(database) == 1 else {
            throw operationFailure("delete an unreferenced camera", database: database)
        }
    }

    private static func verifyTargets(
        _ targets: [TargetGroup],
        receipts: [ColmapCameraGroupReceipt],
        images: [DatabaseImage]
    ) throws {
        guard targets.count == receipts.count else {
            throw ColmapCameraGroupingStoreError.receiptMismatch
        }
        let imagesByName = Dictionary(uniqueKeysWithValues: images.map { ($0.name, $0) })
        for (target, receipt) in zip(targets, receipts) {
            let members = target.imageNames.compactMap { imagesByName[$0] }
            guard target.sourceGroupID == receipt.sourceGroupID,
                  members.count == target.imageNames.count,
                  members.count == receipt.memberCount,
                  Set(members.map(\.cameraID)) == [receipt.canonicalCameraID],
                  Set(members.map(\.rigID)).count == 1 else {
                throw ColmapCameraGroupingStoreError.receiptMismatch
            }
        }
    }

    private static func cameraCount(_ database: OpaquePointer) throws -> Int {
        let statement = try prepare(
            "SELECT COUNT(*) FROM cameras;",
            operation: "count camera records",
            in: database
        )
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else {
            throw operationFailure("count camera records", database: database)
        }
        return Int(sqlite3_column_int64(statement, 0))
    }

    private static func prepare(
        _ sql: String,
        operation: String,
        in database: OpaquePointer
    ) throws -> OpaquePointer {
        var statement: OpaquePointer?
        let result = sqlite3_prepare_v2(database, sql, -1, &statement, nil)
        guard result == SQLITE_OK, let statement else {
            throw operationFailure(operation, database: database, code: result)
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
            throw ColmapCameraGroupingStoreError.databaseOperationFailed(
                operation: operation,
                code: result,
                message: message.map { String(cString: $0) }
                    ?? String(cString: sqlite3_errmsg(database))
            )
        }
    }

    private static func operationFailure(
        _ operation: String,
        database: OpaquePointer,
        code: Int32? = nil
    ) -> ColmapCameraGroupingStoreError {
        .databaseOperationFailed(
            operation: operation,
            code: code ?? sqlite3_extended_errcode(database),
            message: String(cString: sqlite3_errmsg(database))
        )
    }
}
