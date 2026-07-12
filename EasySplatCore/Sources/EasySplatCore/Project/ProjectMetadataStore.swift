import Foundation

/// JSON loader/saver for persisted project metadata files.
public enum ProjectMetadataStore {
    private static let maximumMetadataBytes = 8 * 1_024 * 1_024
    private static let fileLocks = ProjectMetadataFileLocks()
    /// Highest `formatVersion` this build can read. Bump when introducing
    /// breaking schema changes that older builds would silently corrupt.
    public static let supportedFormatVersion: Int = 2

    public enum LoadError: Error, LocalizedError {
        case unsupportedFormatVersion(Int)
        case invalidArtifactPath(field: String, path: String)
        case invalidArtifactNamespace(field: String, path: String)

        public var errorDescription: String? {
            switch self {
            case .unsupportedFormatVersion(let version):
                return "Project metadata uses formatVersion \(version), but this build supports up to \(ProjectMetadataStore.supportedFormatVersion). Update EasySplat to open this project."
            case .invalidArtifactPath(let field, let path):
                return "Project metadata contains an invalid project-relative artifact path for \(field): \(path)"
            case .invalidArtifactNamespace(let field, let path):
                return "Project metadata stores \(field) outside its allowed project directory: \(path)"
            }
        }
    }

    public enum SaveError: Error, LocalizedError {
        case metadataTooLarge(maximumBytes: Int)

        public var errorDescription: String? {
            switch self {
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
                let current = try loadWithoutLock(from: url)
                merged.title = current.title
                merged.notes = current.notes
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
        try ProjectPaths(root: url.deletingLastPathComponent()).validateRootDirectory()
        let data = try BoundedFileReader.readRegularFile(
            at: url,
            maximumBytes: maximumMetadataBytes
        )
        // Peek at formatVersion via a permissive envelope decode first. A future build can
        // rename or drop fields that the strict ProjectMetadata decoder requires; we want
        // such projects to surface as "needs app update" rather than as opaque DecodingErrors.
        if let envelope = try? JSONDecoder().decode(FormatVersionEnvelope.self, from: data),
           envelope.formatVersion > supportedFormatVersion {
            throw LoadError.unsupportedFormatVersion(envelope.formatVersion)
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var metadata = try decoder.decode(ProjectMetadata.self, from: data)
        // Defensive: catch the case where the envelope decode failed but the strict one
        // somehow succeeded with a future formatVersion (shouldn't happen today, but
        // belt-and-braces — the contract is we never hand back a future version).
        guard metadata.formatVersion <= supportedFormatVersion else {
            throw LoadError.unsupportedFormatVersion(metadata.formatVersion)
        }
        if metadata.formatVersion == 1 {
            metadata = migrateVersionOne(metadata)
        }
        do {
            try validateArtifactPaths(in: metadata, metadataURL: url)
        } catch TrainingArtifactStoreError.invalidManifest where metadata.trainingArtifact != nil {
            // Early format-v2 builds wrote training receipts without the input/build
            // binding required for safe resume. Keep the project and public output
            // viewable, but discard that untrusted restart hint.
            metadata.trainingArtifact = nil
            try validateArtifactPaths(in: metadata, metadataURL: url)
        }
        return metadata
    }

    /// Minimal decode that only requires `formatVersion`. Used to recognize future-schema
    /// project files before attempting the strict, schema-bound decode of `ProjectMetadata`.
    private struct FormatVersionEnvelope: Decodable {
        let formatVersion: Int
    }

    private static func saveWithoutLock(_ metadata: ProjectMetadata, to url: URL) throws {
        try ProjectPaths(root: url.deletingLastPathComponent()).validateRootDirectory()
        try validateArtifactPaths(in: metadata, metadataURL: url)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(metadata)
        guard data.count <= maximumMetadataBytes else {
            throw SaveError.metadataTooLarge(maximumBytes: maximumMetadataBytes)
        }
        try data.write(to: url, options: [.atomic])
    }

    private static func migrateVersionOne(_ legacy: ProjectMetadata) -> ProjectMetadata {
        var migrated = legacy
        migrated.formatVersion = supportedFormatVersion
        migrated.requestedRunOptions = RequestedRunOptions(
            capturePath: legacy.preset.mode == .object ? .orbit : .walkthrough,
            detailProfile: {
                switch legacy.preset.quality {
                case .draft: return .fast
                case .standard: return .balanced
                case .ultra: return .highDetail
                }
            }()
        )
        migrated.resolvedRunPlan = nil
        migrated.geometryArtifact = nil
        migrated.trainingArtifact = nil
        return migrated
    }

    private static func validateArtifactPaths(
        in metadata: ProjectMetadata,
        metadataURL: URL
    ) throws {
        let paths = ProjectPaths(root: metadataURL.deletingLastPathComponent())
        var artifactPaths: [(field: String, path: String)] = []
        if let path = metadata.geometryArtifact?.canonicalModelPath {
            artifactPaths.append(("geometryArtifact.canonicalModelPath", path))
        }
        if let path = metadata.trainingArtifact?.checkpointPath {
            artifactPaths.append(("trainingArtifact.checkpointPath", path))
        }
        if let path = metadata.trainingArtifact?.outputPath {
            artifactPaths.append(("trainingArtifact.outputPath", path))
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

        if let trainingArtifact = metadata.trainingArtifact {
            try TrainingArtifactStore.validateArtifact(
                trainingArtifact,
                projectPaths: paths
            )
            guard trainingArtifact.detailProfile == metadata.effectiveDetailProfile else {
                throw TrainingArtifactStoreError.invalidManifest
            }
        }
    }

    private static func pathUsesAllowedNamespace(field: String, path: String) -> Bool {
        switch field {
        case "geometryArtifact.canonicalModelPath":
            return path.hasPrefix("SfM/")
        case "trainingArtifact.checkpointPath":
            return path == "Training/checkpoints/msplat"
                || path.hasPrefix("Training/checkpoints/msplat/")
        case "trainingArtifact.outputPath":
            return path == "Output/splat.ply" || path.hasPrefix("Training/")
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
