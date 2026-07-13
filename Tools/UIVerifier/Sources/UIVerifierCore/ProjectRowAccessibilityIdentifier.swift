import CryptoKit
import Foundation

public enum ProjectRowAccessibilityIdentifier {
    public static func make(for projectURL: URL) -> String {
        make(prefix: "project.row", for: projectURL)
    }

    public static func action(for projectURL: URL) -> String {
        make(prefix: "project.action", for: projectURL)
    }

    private static func make(prefix: String, for projectURL: URL) -> String {
        let canonicalPath = canonicalPath(for: projectURL)
        let digest = SHA256.hash(data: Data(canonicalPath.utf8))
        let shortDigest = digest.prefix(8).map { String(format: "%02x", $0) }.joined()
        return "\(prefix).\(shortDigest)"
    }

    public static func canonicalPath(for projectURL: URL) -> String {
        projectURL.standardizedFileURL.resolvingSymlinksInPath().path
    }
}
