import Foundation

/// JSON loader/saver for persisted project metadata files.
public enum ProjectMetadataStore {
    private static let maximumMetadataBytes = 8 * 1_024 * 1_024
    private static let fileLocks = ProjectMetadataFileLocks()
    /// The current project format EasySplat reads and writes.
    public static let supportedFormatVersion: Int = 31

    public enum LoadError: Error, LocalizedError {
        case unsupportedFormatVersion(Int)
        case invalidArtifactPath(field: String, path: String)
        case invalidArtifactNamespace(field: String, path: String)
        case invalidTrainingMemoryRetryBudget(Int64)
        case invalidGeometryRecovery(String)
        case invalidResolvedRunPlan
        case unexpectedFields

        public var errorDescription: String? {
            switch self {
            case .unsupportedFormatVersion(let version):
                return "Project format \(version) is not supported. This version of EasySplat opens format \(ProjectMetadataStore.supportedFormatVersion) projects only."
            case .invalidArtifactPath(let field, let path):
                return "Project metadata contains an invalid project-relative artifact path for \(field): \(path)"
            case .invalidArtifactNamespace(let field, let path):
                return "Project metadata stores \(field) outside its allowed project directory: \(path)"
            case .invalidTrainingMemoryRetryBudget(let bytes):
                return "Project metadata contains an invalid training memory retry budget: \(bytes) bytes."
            case .invalidGeometryRecovery(let reason):
                return "Project metadata contains invalid geometry recovery state: \(reason)"
            case .invalidResolvedRunPlan:
                return "Project metadata contains an invalid resolved run plan."
            case .unexpectedFields:
                return "Project metadata contains fields outside the current project format."
            }
        }
    }

    public enum SaveError: Error, LocalizedError {
        case invalidFormatVersion(Int)
        case metadataTooLarge(maximumBytes: Int)

        public var errorDescription: String? {
            switch self {
            case .invalidFormatVersion(let version):
                return "Cannot save project format \(version)."
            case .metadataTooLarge(let maximumBytes):
                return "Project metadata exceeds the \(maximumBytes)-byte save limit."
            }
        }
    }

    public static func load(from url: URL) throws -> ProjectMetadata {
        try fileLocks.withLock(for: url) {
            try loadWithoutLock(from: url)
        }
    }

    public static func save(_ metadata: ProjectMetadata, to url: URL) throws {
        try fileLocks.withLock(for: url) {
            try saveWithoutLock(metadata, to: url)
        }
    }

    public static func savePreservingUserEditableFields(_ metadata: ProjectMetadata, to url: URL) throws {
        try fileLocks.withLock(for: url) {
            var merged = metadata
            do {
                let current = try decodeWithoutArtifactValidation(from: url)
                merged.title = current.title
                merged.notes = current.notes
                merged.viewerPreferences = current.viewerPreferences
            } catch {
                guard BoundedFileReader.isMissingFileError(error) else {
                    throw error
                }
            }
            try saveWithoutLock(merged, to: url)
        }
    }

    @discardableResult
    public static func update(
        at url: URL,
        _ mutation: (inout ProjectMetadata) throws -> Void
    ) throws -> ProjectMetadata {
        try fileLocks.withLock(for: url) {
            var metadata = try loadWithoutLock(from: url)
            try mutation(&metadata)
            try saveWithoutLock(metadata, to: url)
            return metadata
        }
    }

    private static func loadWithoutLock(from url: URL) throws -> ProjectMetadata {
        var metadata = try decodeWithoutArtifactValidation(from: url)
        if let recovery = metadata.geometryRecovery,
           (try? recovery.validate()) == nil {
            // Recovery evidence is disposable internal state. A torn or stale
            // recovery payload must not make the project itself unreadable.
            metadata.geometryRecovery = nil
        }
        try validateArtifactPaths(in: metadata, metadataURL: url)
        try VideoInputReceiptValidator.validateMetadata(
            metadata,
            paths: ProjectPaths(root: url.deletingLastPathComponent())
        )
        try PhotoInputReceiptValidator.validateMetadata(
            metadata,
            paths: ProjectPaths(root: url.deletingLastPathComponent())
        )
        return metadata
    }

    private static func decodeWithoutArtifactValidation(from url: URL) throws -> ProjectMetadata {
        try ProjectPaths(root: url.deletingLastPathComponent()).validateRootDirectory()
        let data = try BoundedFileReader.readRegularFile(
            at: url,
            maximumBytes: maximumMetadataBytes
        )
        return try decodePayload(data)
    }

    /// Decodes and validates one already authenticated metadata byte snapshot.
    /// Publication uses this to ensure semantic checks and its file manifest bind
    /// the exact same `project.json` contents.
    static func decodeValidatedMetadataSnapshot(
        _ data: Data,
        metadataURL: URL
    ) throws -> ProjectMetadata {
        guard data.count <= maximumMetadataBytes else {
            throw SaveError.metadataTooLarge(maximumBytes: maximumMetadataBytes)
        }
        try ProjectPaths(root: metadataURL.deletingLastPathComponent()).validateRootDirectory()
        var metadata = try decodePayload(data)
        if let recovery = metadata.geometryRecovery,
           (try? recovery.validate()) == nil {
            metadata.geometryRecovery = nil
        }
        try validateArtifactPaths(in: metadata, metadataURL: metadataURL)
        let paths = ProjectPaths(root: metadataURL.deletingLastPathComponent())
        try VideoInputReceiptValidator.validateMetadata(metadata, paths: paths)
        try PhotoInputReceiptValidator.validateMetadata(metadata, paths: paths)
        return metadata
    }

    private static func decodePayload(_ data: Data) throws -> ProjectMetadata {
        // Read the schema envelope before the strict payload so unsupported projects fail
        // clearly without partially interpreting another format.
        let envelope = try JSONDecoder().decode(FormatVersionEnvelope.self, from: data)
        guard envelope.formatVersion == supportedFormatVersion else {
            throw LoadError.unsupportedFormatVersion(envelope.formatVersion)
        }
        let fieldEnvelope = try JSONDecoder().decode(FieldEnvelope.self, from: data)
        let allowedFields = Set(ProjectMetadata.CodingKeys.allCases.map(\.rawValue))
        guard fieldEnvelope.fields.isSubset(of: allowedFields) else {
            throw LoadError.unexpectedFields
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let metadata = try decoder.decode(ProjectMetadata.self, from: data)
        guard metadata.formatVersion == supportedFormatVersion else {
            throw SaveError.invalidFormatVersion(metadata.formatVersion)
        }
        return metadata
    }

    /// Minimal decode that only requires `formatVersion`. Used to recognize future-schema
    /// project files before attempting the strict, schema-bound decode of `ProjectMetadata`.
    private struct FormatVersionEnvelope: Decodable {
        let formatVersion: Int
    }

    private struct FieldEnvelope: Decodable {
        let fields: Set<String>

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: FieldKey.self)
            fields = Set(container.allKeys.map(\.stringValue))
        }
    }

    private struct FieldKey: CodingKey {
        let stringValue: String
        let intValue: Int? = nil

        init?(stringValue: String) {
            self.stringValue = stringValue
        }

        init?(intValue: Int) {
            return nil
        }
    }

    private static func saveWithoutLock(_ metadata: ProjectMetadata, to url: URL) throws {
        try ProjectPaths(root: url.deletingLastPathComponent()).validateRootDirectory()
        let persistedMetadata = metadata
        guard persistedMetadata.formatVersion == supportedFormatVersion else {
            throw SaveError.invalidFormatVersion(persistedMetadata.formatVersion)
        }
        try validateArtifactPaths(in: persistedMetadata, metadataURL: url)
        try VideoInputReceiptValidator.validateMetadata(
            persistedMetadata,
            paths: ProjectPaths(root: url.deletingLastPathComponent())
        )
        try PhotoInputReceiptValidator.validateMetadata(
            persistedMetadata,
            paths: ProjectPaths(root: url.deletingLastPathComponent())
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(persistedMetadata)
        guard data.count <= maximumMetadataBytes else {
            throw SaveError.metadataTooLarge(maximumBytes: maximumMetadataBytes)
        }
        try data.write(to: url, options: [.atomic])
    }

    private static func validateArtifactPaths(
        in metadata: ProjectMetadata,
        metadataURL: URL
    ) throws {
        let paths = ProjectPaths(root: metadataURL.deletingLastPathComponent())
        if let retryBudget = metadata.trainingMemoryRetryBudgetBytes,
           retryBudget <= 0 {
            throw LoadError.invalidTrainingMemoryRetryBudget(retryBudget)
        }
        if let plan = metadata.resolvedRunPlan {
            do {
                try plan.validate()
            } catch {
                throw LoadError.invalidResolvedRunPlan
            }
            let requiresCrossClipRetrieval = RunPlanResolver.requiresCrossClipRetrieval(
                requestedInputOrdering: metadata.requestedRunOptions.inputOrdering,
                input: metadata.input
            )
            guard plan.requiresCrossClipRetrieval == requiresCrossClipRetrieval else {
                throw LoadError.invalidResolvedRunPlan
            }
        }
        if let recovery = metadata.geometryRecovery {
            do {
                try recovery.validate()
            } catch {
                throw LoadError.invalidGeometryRecovery(error.localizedDescription)
            }
        }
        var artifactPaths: [(field: String, path: String)] = []
        if let details = metadata.checkpoint?.details {
            switch details {
            case .extractFrames:
                break
            case .selectFrames(let checkpoint):
                if let path = checkpoint.manifestPath {
                    artifactPaths.append(("checkpoint.selectFrames.manifestPath", path))
                }
            case .sfmFeatures(let checkpoint):
                artifactPaths.append(("checkpoint.sfmFeatures.databasePath", checkpoint.databasePath))
            case .sfmMatching(let checkpoint):
                artifactPaths.append(("checkpoint.sfmMatching.databasePath", checkpoint.databasePath))
            case .trainSplat:
                break
            case .exportSplat(let checkpoint):
                artifactPaths.append(("checkpoint.exportSplat.outputPath", checkpoint.outputPath))
                artifactPaths.append(("checkpoint.exportSplat.sourcePath", checkpoint.sourcePath))
            }
        }

        for artifactPath in artifactPaths {
            do {
                _ = try paths.resolveProjectRelativePath(artifactPath.path)
            } catch {
                throw LoadError.invalidArtifactPath(
                    field: artifactPath.field,
                    path: artifactPath.path
                )
            }
            guard pathUsesAllowedNamespace(
                field: artifactPath.field,
                path: artifactPath.path
            ) else {
                throw LoadError.invalidArtifactNamespace(
                    field: artifactPath.field,
                    path: artifactPath.path
                )
            }
        }

    }

    private static func pathUsesAllowedNamespace(field: String, path: String) -> Bool {
        switch field {
        case "checkpoint.exportSplat.outputPath":
            return path.hasPrefix("Output/")
        case "checkpoint.selectFrames.manifestPath":
            return path.hasPrefix("Frames/")
        case "checkpoint.sfmFeatures.databasePath", "checkpoint.sfmMatching.databasePath":
            return path == "SfM/colmap/database.db"
        case "checkpoint.exportSplat.sourcePath":
            return path.hasPrefix("Training/")
        default:
            return false
        }
    }
}

private final class ProjectMetadataFileLocks: @unchecked Sendable {
    private let registryLock = NSLock()
    private var locks: [String: NSLock] = [:]

    func withLock<Value>(for url: URL, _ body: () throws -> Value) rethrows -> Value {
        let key = url.standardizedFileURL.resolvingSymlinksInPath().path
        let fileLock = registryLock.withLock {
            if let existing = locks[key] {
                return existing
            }
            let created = NSLock()
            locks[key] = created
            return created
        }
        return try fileLock.withLock(body)
    }
}
