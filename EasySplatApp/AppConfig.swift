import Darwin
import EasySplatCore
import Foundation

enum AppConfig {
    struct ReleaseVerificationConfiguration: Equatable {
        var photoFolderURL: URL
        var successMarkerURL: URL
    }

    private static let defaultProjectHomeURLString = "https://github.com/dud8/EasySplat"
    private static let defaultToolchainManifestURLString = "https://github.com/dud8/EasySplat/releases/download/toolchain-v2.0.0/manifest.json"

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
        return URL(string: defaultToolchainManifestURLString) ?? projectHomeURL
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

    static var bundledToolchainBootstrap: ToolchainBootstrap? {
        bundledToolchainBootstrap(
            environment: ProcessInfo.processInfo.environment,
            resourceRoot: Bundle.main.resourceURL
        )
    }

    static func bundledToolchainBootstrap(
        environment: [String: String],
        resourceRoot: URL?
    ) -> ToolchainBootstrap? {
        guard environment["EASYSPLAT_TOOLCHAIN_MANIFEST_URL"]?.isEmpty != false,
              environment["EASYSPLAT_TOOLCHAIN_PUBLIC_KEY_BASE64"]?.isEmpty != false,
              let resourceRoot else {
            return nil
        }

        let bootstrapRoot = resourceRoot
            .appendingPathComponent("ToolchainBootstrap", isDirectory: true)
        let manifestURL = bootstrapRoot
            .appendingPathComponent("manifest.json", isDirectory: false)
        let coreArchiveURL = bootstrapRoot
            .appendingPathComponent("macos-arm64-core.zip", isDirectory: false)
        guard isOrdinaryDirectory(bootstrapRoot),
              isSingleLinkRegularFile(manifestURL),
              isSingleLinkRegularFile(coreArchiveURL) else {
            return nil
        }
        return ToolchainBootstrap(
            manifestURL: manifestURL,
            coreArchiveURL: coreArchiveURL
        )
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

    static var releaseVerificationPhotoFolderURL: URL? {
        releaseVerificationConfiguration(
            environment: ProcessInfo.processInfo.environment,
            arguments: ProcessInfo.processInfo.arguments
        )?.photoFolderURL
    }

    static var releaseVerificationConfiguration: ReleaseVerificationConfiguration? {
        releaseVerificationConfiguration(
            environment: ProcessInfo.processInfo.environment,
            arguments: ProcessInfo.processInfo.arguments
        )
    }

    static func releaseVerificationPhotoFolderURL(
        environment: [String: String],
        arguments: [String]
    ) -> URL? {
        releaseVerificationConfiguration(
            environment: environment,
            arguments: arguments
        )?.photoFolderURL
    }

    static func releaseVerificationConfiguration(
        environment: [String: String],
        arguments: [String]
    ) -> ReleaseVerificationConfiguration? {
        let gate = "--easysplat-release-verify-bundled-bootstrap"
        guard environment["EASYSPLAT_ISOLATED_UI_RUNNER"] == "1",
              environment["EASYSPLAT_TOOLCHAIN_MANIFEST_URL"]?.isEmpty != false,
              environment["EASYSPLAT_TOOLCHAIN_PUBLIC_KEY_BASE64"]?.isEmpty != false,
              environment["EASYSPLAT_LOCAL_TOOLCHAIN_ROOT"]?.isEmpty != false,
              arguments.count == 3,
              arguments[1] == gate,
              let fixedHomePath = environment["CFFIXED_USER_HOME"],
              let homePath = environment["HOME"],
              (fixedHomePath as NSString).isAbsolutePath,
              (homePath as NSString).isAbsolutePath,
              (arguments[2] as NSString).isAbsolutePath else {
            return nil
        }

        let fixedHome = URL(fileURLWithPath: fixedHomePath, isDirectory: true)
            .standardizedFileURL
            .resolvingSymlinksInPath()
        let home = URL(fileURLWithPath: homePath, isDirectory: true)
            .standardizedFileURL
            .resolvingSymlinksInPath()
        let input = URL(fileURLWithPath: arguments[2], isDirectory: true)
            .standardizedFileURL
            .resolvingSymlinksInPath()
        guard home == fixedHome,
              isOrdinaryDirectory(fixedHome),
              isOrdinaryDirectory(input),
              input.path.hasPrefix(fixedHome.path + "/") else {
            return nil
        }
        return ReleaseVerificationConfiguration(
            photoFolderURL: input,
            successMarkerURL: fixedHome.appendingPathComponent(
                "release-verification-toolchain-ready.json",
                isDirectory: false
            )
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

    private static func isOrdinaryDirectory(_ url: URL) -> Bool {
        guard let metadata = fileMetadata(at: url) else { return false }
        return (metadata.st_mode & S_IFMT) == S_IFDIR
    }

    private static func isSingleLinkRegularFile(_ url: URL) -> Bool {
        guard let metadata = fileMetadata(at: url) else { return false }
        return (metadata.st_mode & S_IFMT) == S_IFREG
            && metadata.st_nlink == 1
            && metadata.st_size > 0
    }

    private static func fileMetadata(at url: URL) -> stat? {
        guard url.isFileURL else { return nil }
        return url.withUnsafeFileSystemRepresentation { path in
            guard let path else { return nil }
            var metadata = stat()
            guard Darwin.lstat(path, &metadata) == 0 else { return nil }
            return metadata
        }
    }
}
