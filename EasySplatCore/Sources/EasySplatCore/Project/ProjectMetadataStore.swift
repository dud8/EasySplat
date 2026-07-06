import Foundation

/// JSON loader/saver for persisted project metadata files.
public enum ProjectMetadataStore {
    /// Highest `formatVersion` this build can read. Bump when introducing
    /// breaking schema changes that older builds would silently corrupt.
    public static let supportedFormatVersion: Int = 1

    public enum LoadError: Error, LocalizedError {
        case unsupportedFormatVersion(Int)

        public var errorDescription: String? {
            switch self {
            case .unsupportedFormatVersion(let version):
                return "Project metadata uses formatVersion \(version), but this build supports up to \(ProjectMetadataStore.supportedFormatVersion). Update EasySplat to open this project."
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
        let metadata = try decoder.decode(ProjectMetadata.self, from: data)
        // Defensive: catch the case where the envelope decode failed but the strict one
        // somehow succeeded with a future formatVersion (shouldn't happen today, but
        // belt-and-braces — the contract is we never hand back a future version).
        guard metadata.formatVersion <= supportedFormatVersion else {
            throw LoadError.unsupportedFormatVersion(metadata.formatVersion)
        }
        return metadata
    }

    /// Minimal decode that only requires `formatVersion`. Used to recognize future-schema
    /// project files before attempting the strict, schema-bound decode of `ProjectMetadata`.
    private struct FormatVersionEnvelope: Decodable {
        let formatVersion: Int
    }

    public static func save(_ metadata: ProjectMetadata, to url: URL) throws {
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
}
