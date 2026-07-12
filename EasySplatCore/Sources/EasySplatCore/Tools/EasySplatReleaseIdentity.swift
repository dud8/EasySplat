import Foundation

public enum EasySplatReleaseIdentity {
    public static func version(in infoDictionary: [String: Any]?) -> String {
        for key in ["EasySplatReleaseVersion", "CFBundleShortVersionString"] {
            guard let value = infoDictionary?[key] as? String else { continue }
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                return trimmed
            }
        }
        return "0.0.0"
    }

    public static func version(in bundle: Bundle = .main) -> String {
        version(in: bundle.infoDictionary)
    }
}
