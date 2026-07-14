import Foundation

struct ColmapFeatureEvidence: Codable, Sendable, Equatable {
    static let currentSchemaVersion = 1

    var schemaVersion: Int
    var selectedFramesDigest: String
    var imageNames: [String]
    var featureDatabaseDigest: String

    init(
        selectedFramesDigest: String,
        imageNames: [String],
        featureDatabaseDigest: String
    ) {
        schemaVersion = Self.currentSchemaVersion
        self.selectedFramesDigest = selectedFramesDigest
        self.imageNames = imageNames
        self.featureDatabaseDigest = featureDatabaseDigest
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
        databaseURL: URL,
        projectPaths: ProjectPaths
    ) throws -> ColmapFeatureEvidence {
        try Task.checkCancellation()
        let evidence = try load(from: url, projectPaths: projectPaths)
        let selectedFramesDigest = try GeometryArtifactStore.selectedFramesDigest(
            orderedImageNames: expectedImageNames,
            projectPaths: projectPaths
        )
        let featureDatabaseDigest = try ColmapDatabaseDigester
            .digests(at: databaseURL).feature
        guard evidence.imageNames == expectedImageNames,
              evidence.selectedFramesDigest == selectedFramesDigest,
              evidence.featureDatabaseDigest == featureDatabaseDigest else {
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
              Set(evidence.imageNames).count == evidence.imageNames.count,
              evidence.imageNames.allSatisfy({ name in
                  !name.isEmpty && !name.contains(where: \.isWhitespace)
              }) else {
            throw ColmapFeatureEvidenceStoreError.invalidEvidence
        }
    }

    private static func validateLocation(
        _ url: URL,
        projectPaths: ProjectPaths
    ) throws {
        try projectPaths.validateRootDirectory()
        let expected = try projectPaths.resolveProjectRelativePath(
            "SfM/colmap/feature_evidence.json"
        )
        guard expected.standardizedFileURL == url.standardizedFileURL else {
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
