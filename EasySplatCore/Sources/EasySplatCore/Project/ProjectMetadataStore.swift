import Foundation

/// JSON loader/saver for persisted project metadata files.
public enum ProjectMetadataStore {
    /// Highest `formatVersion` this build can read. Bump when introducing
    /// breaking schema changes that older builds would silently corrupt.
    public static let supportedFormatVersion: Int = 2

    public enum LoadError: Error, LocalizedError {
        case unsupportedFormatVersion(Int)
        case invalidArtifactPath(field: String, path: String)

        public var errorDescription: String? {
            switch self {
            case .unsupportedFormatVersion(let version):
                return "Project metadata uses formatVersion \(version), but this build supports up to \(ProjectMetadataStore.supportedFormatVersion). Update EasySplat to open this project."
            case .invalidArtifactPath(let field, let path):
                return "Project metadata contains an invalid project-relative artifact path for \(field): \(path)"
            }
        }
    }

    public static func load(from url: URL) throws -> ProjectMetadata {
        let data = try Data(contentsOf: url)
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
        try validateArtifactPaths(in: metadata, metadataURL: url)
        return metadata
    }

    /// Minimal decode that only requires `formatVersion`. Used to recognize future-schema
    /// project files before attempting the strict, schema-bound decode of `ProjectMetadata`.
    private struct FormatVersionEnvelope: Decodable {
        let formatVersion: Int
    }

    public static func save(_ metadata: ProjectMetadata, to url: URL) throws {
        try validateArtifactPaths(in: metadata, metadataURL: url)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(metadata)
        try data.write(to: url, options: [.atomic])
    }

    public static func savePreservingUserEditableFields(_ metadata: ProjectMetadata, to url: URL) throws {
        var merged = metadata
        if let current = try? load(from: url) {
            merged.notes = current.notes
        }
        try save(merged, to: url)
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
        }
    }
}
