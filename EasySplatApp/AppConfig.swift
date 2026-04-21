import Foundation

enum AppConfig {
    private static let defaultProjectHomeURLString = "https://github.com/EasySplat/EasySplat"

    static var projectHomeURL: URL {
        if let url = urlFromEnv("EASYSPLAT_PROJECT_HOME_URL") {
            return url
        }
        if let url = readURLResource(named: "project_home_url") {
            return url
        }
        return URL(string: defaultProjectHomeURLString) ?? URL(fileURLWithPath: "/")
    }

    static var toolchainManifestURL: URL {
        if let url = urlFromEnv("EASYSPLAT_TOOLCHAIN_MANIFEST_URL") {
            return url
        }
        if let url = readURLResource(named: "toolchain_manifest_url") {
            return url
        }
        return projectHomeURL
            .appendingPathComponent("releases", isDirectory: true)
            .appendingPathComponent("latest", isDirectory: true)
            .appendingPathComponent("download", isDirectory: true)
            .appendingPathComponent("manifest.json")
    }

    static var toolchainPublicKeyBase64: String {
        if let env = ProcessInfo.processInfo.environment["EASYSPLAT_TOOLCHAIN_PUBLIC_KEY_BASE64"], !env.isEmpty {
            return env
        }
        guard let url = Bundle.module.url(forResource: "public_key_ed25519", withExtension: "txt"),
              let text = try? String(contentsOf: url, encoding: .utf8) else {
            return ""
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func urlFromEnv(_ name: String) -> URL? {
        guard let value = ProcessInfo.processInfo.environment[name], !value.isEmpty else { return nil }
        return URL(string: value)
    }

    private static func readURLResource(named: String) -> URL? {
        guard let url = Bundle.module.url(forResource: named, withExtension: "txt"),
              let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}
