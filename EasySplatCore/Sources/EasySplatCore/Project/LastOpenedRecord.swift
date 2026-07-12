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
    private static let maximumBytes = 4 * 1_024

    public static func load(from url: URL) -> Date? {
        let parent = url.deletingLastPathComponent()
        guard (try? ProjectPaths(root: parent).validateRootDirectory()) != nil,
              let data = try? BoundedFileReader.readRegularFile(
                at: url,
                maximumBytes: maximumBytes
              ) else {
            return nil
        }
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
        try ProjectPaths(root: parent).validateRootDirectory()
        try data.write(to: url, options: [.atomic])
    }
}
