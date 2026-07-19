import Foundation

public enum SplatExport {
    public static func copyIfExists(from source: URL, to destination: URL) throws {
        _ = try ProjectArtifactValidator.publishValidatedPly(
            from: source,
            to: destination
        )
    }
}
