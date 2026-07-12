import Foundation

enum AppConfig {
    private static let defaultProjectHomeURLString = "https://github.com/dud8/EasySplat"

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

    static var allowInsecureLoopbackToolchainHTTP: Bool {
#if DEBUG
        guard toolchainManifestURL.scheme?.lowercased() == "http" else { return false }
        let host = toolchainManifestURL.host?.lowercased()
        return host == "localhost" || host == "127.0.0.1" || host == "::1"
#else
        return false
#endif
    }

    static var uiVerificationProcessingProjectURL: URL? {
        uiVerificationProcessingProjectURL(
            environment: ProcessInfo.processInfo.environment,
            arguments: ProcessInfo.processInfo.arguments
        )
    }

    static func uiVerificationProcessingProjectURL(
        environment: [String: String],
        arguments: [String]
    ) -> URL? {
        guard environment["EASYSPLAT_ISOLATED_UI_RUNNER"] == "1",
              arguments.contains("--easysplat-ui-verifier-processing-fixture"),
              let homePath = environment["HOME"],
              (homePath as NSString).isAbsolutePath,
              let projectPath = environment["EASYSPLAT_UI_VERIFIER_PROCESSING_PROJECT"],
              (projectPath as NSString).isAbsolutePath else {
            return nil
        }

        let projectRoot = URL(fileURLWithPath: homePath, isDirectory: true)
            .appendingPathComponent("Documents", isDirectory: true)
            .appendingPathComponent("EasySplat Projects", isDirectory: true)
            .standardizedFileURL
        let projectURL = URL(fileURLWithPath: projectPath, isDirectory: true)
            .standardizedFileURL
        guard projectURL.pathExtension == "easysplatproj",
              projectURL.deletingLastPathComponent() == projectRoot else {
            return nil
        }
        return projectURL
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
