import Foundation
import SQLite3

struct ColmapFeatureEvidence: Codable, Sendable, Equatable {
    static let currentSchemaVersion = 3

    var schemaVersion: Int
    var selectedFramesDigest: String
    var imageNames: [String]
    var featureDatabaseDigest: String
    var cameraGroupingReceipt: ColmapCameraGroupingReceipt
    var cameraInitializationReceipt: ColmapCameraInitializationReceipt

    init(
        selectedFramesDigest: String,
        imageNames: [String],
        featureDatabaseDigest: String,
        cameraGroupingReceipt: ColmapCameraGroupingReceipt,
        cameraInitializationReceipt: ColmapCameraInitializationReceipt
    ) {
        schemaVersion = Self.currentSchemaVersion
        self.selectedFramesDigest = selectedFramesDigest
        self.imageNames = imageNames
        self.featureDatabaseDigest = featureDatabaseDigest
        self.cameraGroupingReceipt = cameraGroupingReceipt
        self.cameraInitializationReceipt = cameraInitializationReceipt
    }
}

enum ColmapFeatureEvidenceStoreError: Error, LocalizedError, Equatable {
    case invalidLocation
    case invalidEvidence

    var errorDescription: String? {
        switch self {
        case .invalidLocation:
            return "Feature evidence must stay at its canonical project path."
        case .invalidEvidence:
            return "Feature evidence is incomplete or does not match the project."
        }
    }
}

#if DEBUG
enum ColmapFeatureEvidenceDatabaseVerificationCheckpoint: Equatable {
    case afterIdentityVerification
    case afterDigestVerification
}
#endif

enum ColmapFeatureEvidenceStore {
    static let maximumBytes = 1 * 1_024 * 1_024

    static func save(
        _ evidence: ColmapFeatureEvidence,
        to url: URL,
        projectPaths: ProjectPaths
    ) throws {
        try validateLocation(url, projectPaths: projectPaths)
        try validate(evidence)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(evidence)
        guard !data.isEmpty, data.count <= maximumBytes else {
            throw ColmapFeatureEvidenceStoreError.invalidEvidence
        }
        try data.write(to: url, options: [.atomic])
    }

    static func load(
        from url: URL,
        projectPaths: ProjectPaths
    ) throws -> ColmapFeatureEvidence {
        try validateLocation(url, projectPaths: projectPaths)
        let data = try BoundedFileReader.readRegularFile(
            at: url,
            maximumBytes: maximumBytes
        )
        guard !data.isEmpty,
              let evidence = try? JSONDecoder().decode(
                  ColmapFeatureEvidence.self,
                  from: data
              ) else {
            throw ColmapFeatureEvidenceStoreError.invalidEvidence
        }
        try validate(evidence)
        return evidence
    }

    static func loadVerified(
        from url: URL,
        expectedImageNames: [String],
        expectedCameraEvidence: [ColmapSelectedImageCameraEvidence],
        expectedCameraGroupingMode: ColmapCameraGroupingMode,
        expectedCameraInitializationReceipt: ColmapCameraInitializationReceipt,
        databaseURL: URL,
        projectPaths: ProjectPaths
    ) throws -> ColmapFeatureEvidence {
        try loadVerified(
            from: url,
            expectedImageNames: expectedImageNames,
            expectedCameraEvidence: expectedCameraEvidence,
            expectedCameraGroupingMode: expectedCameraGroupingMode,
            expectedCameraInitializationReceipt: expectedCameraInitializationReceipt,
            databaseURL: databaseURL,
            projectPaths: projectPaths,
            afterIdentityVerification: {},
            afterDigestVerification: {}
        )
    }

#if DEBUG
    static func loadVerifiedForTesting(
        from url: URL,
        expectedImageNames: [String],
        expectedCameraEvidence: [ColmapSelectedImageCameraEvidence],
        expectedCameraGroupingMode: ColmapCameraGroupingMode,
        expectedCameraInitializationReceipt: ColmapCameraInitializationReceipt,
        databaseURL: URL,
        projectPaths: ProjectPaths,
        checkpoint: (ColmapFeatureEvidenceDatabaseVerificationCheckpoint) throws -> Void
    ) throws -> ColmapFeatureEvidence {
        try loadVerified(
            from: url,
            expectedImageNames: expectedImageNames,
            expectedCameraEvidence: expectedCameraEvidence,
            expectedCameraGroupingMode: expectedCameraGroupingMode,
            expectedCameraInitializationReceipt: expectedCameraInitializationReceipt,
            databaseURL: databaseURL,
            projectPaths: projectPaths,
            afterIdentityVerification: {
                try checkpoint(.afterIdentityVerification)
            },
            afterDigestVerification: {
                try checkpoint(.afterDigestVerification)
            }
        )
    }
#endif

    private static func loadVerified(
        from url: URL,
        expectedImageNames: [String],
        expectedCameraEvidence: [ColmapSelectedImageCameraEvidence],
        expectedCameraGroupingMode: ColmapCameraGroupingMode,
        expectedCameraInitializationReceipt: ColmapCameraInitializationReceipt,
        databaseURL: URL,
        projectPaths: ProjectPaths,
        afterIdentityVerification: () throws -> Void,
        afterDigestVerification: () throws -> Void
    ) throws -> ColmapFeatureEvidence {
        try Task.checkCancellation()
        let evidence = try load(from: url, projectPaths: projectPaths)
        let selectedFramesDigest = try GeometryArtifactStore.selectedFramesDigest(
            orderedImageNames: expectedImageNames,
            projectPaths: projectPaths
        )
        let verifiedDatabaseEvidence = try ColmapFeatureDatabaseIdentityVerifier
            .withVerifiedSnapshot(
            databaseURL: databaseURL,
            expectedImageNames: expectedImageNames
        ) { database in
            try afterIdentityVerification()
            let featureDatabaseDigest = try ColmapDatabaseDigester
                .digests(in: database).feature
            try afterDigestVerification()
            let cameraGroupingReceipt = try ColmapCameraGroupingStore.verify(
                in: database,
                selectedImages: expectedCameraEvidence,
                expectedMode: expectedCameraGroupingMode,
                expectedReceipt: evidence.cameraGroupingReceipt
            )
            try verifyCameraInitialization(
                evidence.cameraInitializationReceipt,
                expected: expectedCameraInitializationReceipt,
                expectedImageCount: expectedImageNames.count,
                database: database
            )
            return (featureDatabaseDigest, cameraGroupingReceipt)
        }
        guard evidence.imageNames == expectedImageNames,
              evidence.cameraInitializationReceipt
                == expectedCameraInitializationReceipt,
              evidence.selectedFramesDigest == selectedFramesDigest,
              evidence.featureDatabaseDigest == verifiedDatabaseEvidence.0 else {
            throw ColmapFeatureEvidenceStoreError.invalidEvidence
        }
        guard verifiedDatabaseEvidence.1 == evidence.cameraGroupingReceipt else {
            throw ColmapFeatureEvidenceStoreError.invalidEvidence
        }
        try Task.checkCancellation()
        return evidence
    }

    private static func validate(_ evidence: ColmapFeatureEvidence) throws {
        guard evidence.schemaVersion == ColmapFeatureEvidence.currentSchemaVersion,
              isSHA256(evidence.selectedFramesDigest),
              isSHA256(evidence.featureDatabaseDigest),
              evidence.imageNames.count >= 2,
              evidence.cameraGroupingReceipt.isValid(
                  selectedImageCount: evidence.imageNames.count
              ),
              evidence.cameraInitializationReceipt.isValid,
              Set(evidence.imageNames).count == evidence.imageNames.count,
              evidence.imageNames.allSatisfy({ name in
                  !name.isEmpty && !name.contains(where: \.isWhitespace)
              }) else {
            throw ColmapFeatureEvidenceStoreError.invalidEvidence
        }
    }

    private static func verifyCameraInitialization(
        _ actual: ColmapCameraInitializationReceipt,
        expected: ColmapCameraInitializationReceipt,
        expectedImageCount: Int,
        database: OpaquePointer
    ) throws {
        guard actual == expected, actual.isValid else {
            throw ColmapFeatureEvidenceStoreError.invalidEvidence
        }
        guard actual.recipe == .sharedOpenCVFisheyeEquidistantDiagonal150V1 else {
            return
        }
        guard let width = actual.pixelWidth,
              let height = actual.pixelHeight,
              let expectedParameters = actual.littleEndianParameterData else {
            throw ColmapFeatureEvidenceStoreError.invalidEvidence
        }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(
            database,
            "SELECT camera_id, model, width, height, params, prior_focal_length FROM cameras ORDER BY camera_id;",
            -1,
            &statement,
            nil
        ) == SQLITE_OK,
              let statement else {
            throw ColmapFeatureEvidenceStoreError.invalidEvidence
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else {
            throw ColmapFeatureEvidenceStoreError.invalidEvidence
        }
        let cameraID = sqlite3_column_int64(statement, 0)
        let model = sqlite3_column_int64(statement, 1)
        let storedWidth = sqlite3_column_int64(statement, 2)
        let storedHeight = sqlite3_column_int64(statement, 3)
        let blobCount = Int(sqlite3_column_bytes(statement, 4))
        let blob = sqlite3_column_blob(statement, 4).map {
            Data(bytes: $0, count: blobCount)
        }
        let priorFocalLength = sqlite3_column_int64(statement, 5)
        guard cameraID > 0,
              model == 5,
              storedWidth == Int64(width),
              storedHeight == Int64(height),
              blob == expectedParameters,
              priorFocalLength == 1,
              sqlite3_step(statement) == SQLITE_DONE else {
            throw ColmapFeatureEvidenceStoreError.invalidEvidence
        }

        var imageStatement: OpaquePointer?
        guard sqlite3_prepare_v2(
            database,
            "SELECT COUNT(*), COUNT(DISTINCT camera_id), MIN(camera_id), MAX(camera_id) FROM images;",
            -1,
            &imageStatement,
            nil
        ) == SQLITE_OK,
              let imageStatement else {
            throw ColmapFeatureEvidenceStoreError.invalidEvidence
        }
        defer { sqlite3_finalize(imageStatement) }
        guard sqlite3_step(imageStatement) == SQLITE_ROW,
              sqlite3_column_int64(imageStatement, 0) == Int64(expectedImageCount),
              sqlite3_column_int64(imageStatement, 1) == 1,
              sqlite3_column_int64(imageStatement, 2) == cameraID,
              sqlite3_column_int64(imageStatement, 3) == cameraID,
              sqlite3_step(imageStatement) == SQLITE_DONE else {
            throw ColmapFeatureEvidenceStoreError.invalidEvidence
        }
    }

    private static func validateLocation(
        _ url: URL,
        projectPaths: ProjectPaths
    ) throws {
        let expected: URL
        do {
            expected = try projectPaths.validateReservedProjectPath(
                url,
                relativePath: "SfM/colmap/feature_evidence.json"
            )
        } catch {
            throw ColmapFeatureEvidenceStoreError.invalidLocation
        }
        let parent = try expected.deletingLastPathComponent().resourceValues(
            forKeys: [.isDirectoryKey, .isSymbolicLinkKey]
        )
        guard parent.isDirectory == true,
              parent.isSymbolicLink != true else {
            throw ColmapFeatureEvidenceStoreError.invalidLocation
        }
    }

    private static func isSHA256(_ value: String) -> Bool {
        value.count == 64 && value.utf8.allSatisfy { byte in
            (48...57).contains(byte) || (97...102).contains(byte)
        }
    }
}
