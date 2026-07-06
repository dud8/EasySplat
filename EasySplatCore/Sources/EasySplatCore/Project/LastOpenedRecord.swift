import Foundation

/// Sidecar record written when the user opens a project in the viewer.
/// Kept out of `ProjectMetadata` so a UI-driven stamp can never clobber
/// concurrent pipeline writes to `project.json`.
public struct LastOpenedRecord: Codable, Sendable, Equatable {
    public var openedAt: Date

    public init(openedAt: Date) {
        self.openedAt = openedAt
    }
}

public enum LastOpenedSidecar {
    public static func load(from url: URL) -> Date? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode(LastOpenedRecord.self, from: data))?.openedAt
    }

    public static func save(_ moment: Date, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(LastOpenedRecord(openedAt: moment))
        let parent = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        try data.write(to: url, options: [.atomic])
    }
}
