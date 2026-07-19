import Darwin
import EasySplatCore
import EasySplatReleaseVerifierCore
import Foundation

enum AppConfig {
    struct ReleaseVerificationConfiguration: Equatable {
        var inputManifestURL: URL
        var inputRootURL: URL
        var successMarkerURL: URL
        var verificationToken: String
    }

    enum ReleaseVerificationStartup: Equatable {
        case ordinary
        case authorized(ReleaseVerificationConfiguration)
        case rejected

        var configuration: ReleaseVerificationConfiguration? {
            guard case .authorized(let configuration) = self else { return nil }
            return configuration
        }

        var requiresImmediateExit: Bool {
            self == .rejected
        }
    }

    private static let defaultProjectHomeURLString = "https://github.com/dud8/EasySplat"
    private static let defaultToolchainManifestURLString = "https://github.com/dud8/EasySplat/releases/download/toolchain-v2.0.0/manifest.json"
    private static let releaseVerificationPoisonValues = [
        "EASYSPLAT_PROJECT_HOME_URL": "https://release-verifier-poison.invalid/project",
        "EASYSPLAT_TOOLCHAIN_MANIFEST_URL": "https://release-verifier-poison.invalid/manifest.json",
        "EASYSPLAT_TOOLCHAIN_PUBLIC_KEY_BASE64": "release-verifier-poison-public-key",
        "EASYSPLAT_LOCAL_TOOLCHAIN_ROOT": "/release-verifier-poison/toolchain",
        "EASYSPLAT_SKIP_TRAINING": "1",
        "EASYSPLAT_STOP_AFTER_STAGE": PipelineStage.sfmMapping.rawValue,
        "EASYSPLAT_CANDIDATE_ROUTE": "da3",
        "EASYSPLAT_BENCHMARK_SEED": "2147483647",
    ]
    private static let releaseVerificationAttemptSentinelKeys = [
        "EASYSPLAT_PROJECT_HOME_URL",
        "EASYSPLAT_TOOLCHAIN_MANIFEST_URL",
        "EASYSPLAT_TOOLCHAIN_PUBLIC_KEY_BASE64",
        "EASYSPLAT_LOCAL_TOOLCHAIN_ROOT",
    ]

    static let allowsDevelopmentOverrides: Bool = {
#if DEBUG
        true
#else
        false
#endif
    }()

    static var projectHomeURL: URL {
        resolvedProjectHomeURL(
            environment: ProcessInfo.processInfo.environment,
            allowsDevelopmentOverrides: allowsDevelopmentOverrides
        )
    }

    static func resolvedProjectHomeURL(
        environment: [String: String],
        allowsDevelopmentOverrides: Bool
    ) -> URL {
        if allowsDevelopmentOverrides,
           let url = urlFromEnvironment("EASYSPLAT_PROJECT_HOME_URL", environment: environment) {
            return url
        }
        if let url = readURLResource(named: "project_home_url") {
            return url
        }
        return URL(string: defaultProjectHomeURLString) ?? URL(fileURLWithPath: "/")
    }

    static var toolchainManifestURL: URL {
        resolvedToolchainManifestURL(
            environment: ProcessInfo.processInfo.environment,
            allowsDevelopmentOverrides: allowsDevelopmentOverrides
        )
    }

    static func resolvedToolchainManifestURL(
        environment: [String: String],
        allowsDevelopmentOverrides: Bool
    ) -> URL {
        if allowsDevelopmentOverrides,
           let url = urlFromEnvironment("EASYSPLAT_TOOLCHAIN_MANIFEST_URL", environment: environment) {
            return url
        }
        if let url = readURLResource(named: "toolchain_manifest_url") {
            return url
        }
        return URL(string: defaultToolchainManifestURLString)
            ?? resolvedProjectHomeURL(
                environment: environment,
                allowsDevelopmentOverrides: allowsDevelopmentOverrides
            )
    }

    static var toolchainPublicKeyBase64: String {
        resolvedToolchainPublicKeyBase64(
            environment: ProcessInfo.processInfo.environment,
            allowsDevelopmentOverrides: allowsDevelopmentOverrides
        )
    }

    static func resolvedToolchainPublicKeyBase64(
        environment: [String: String],
        allowsDevelopmentOverrides: Bool
    ) -> String {
        if allowsDevelopmentOverrides,
           let value = environment["EASYSPLAT_TOOLCHAIN_PUBLIC_KEY_BASE64"],
           !value.isEmpty {
            return value
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
        bundledToolchainBootstrap(
            environment: environment,
            resourceRoot: resourceRoot,
            allowsDevelopmentOverrides: allowsDevelopmentOverrides
        )
    }

    static func bundledToolchainBootstrap(
        environment: [String: String],
        resourceRoot: URL?,
        allowsDevelopmentOverrides: Bool
    ) -> ToolchainBootstrap? {
        if allowsDevelopmentOverrides {
            guard environment["EASYSPLAT_TOOLCHAIN_MANIFEST_URL"]?.isEmpty != false,
                  environment["EASYSPLAT_TOOLCHAIN_PUBLIC_KEY_BASE64"]?.isEmpty != false else {
                return nil
            }
        }
        guard let resourceRoot else { return nil }

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

    static var currentDevelopmentOverrides: DevelopmentOverrides {
        developmentOverrides(
            environment: ProcessInfo.processInfo.environment,
            allowsDevelopmentOverrides: allowsDevelopmentOverrides
        )
    }

    static func developmentOverrides(
        environment: [String: String],
        allowsDevelopmentOverrides: Bool
    ) -> DevelopmentOverrides {
        guard allowsDevelopmentOverrides else { return .none }
        return DevelopmentOverrides.fromEnvironment(environment)
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

    static var releaseVerificationConfiguration: ReleaseVerificationConfiguration? {
        releaseVerificationStartup.configuration
    }

    static var releaseVerificationStartup: ReleaseVerificationStartup {
        releaseVerificationStartup(
            environment: ProcessInfo.processInfo.environment,
            arguments: ProcessInfo.processInfo.arguments
        )
    }

    static func releaseVerificationStartup(
        environment: [String: String],
        arguments: [String]
    ) -> ReleaseVerificationStartup {
        guard isReleaseVerificationAttempt(environment: environment, arguments: arguments) else {
            return .ordinary
        }
        guard let configuration = validatedReleaseVerificationConfiguration(
            environment: environment,
            arguments: arguments
        ) else {
            return .rejected
        }
        return .authorized(configuration)
    }

    static func releaseVerificationConfiguration(
        environment: [String: String],
        arguments: [String]
    ) -> ReleaseVerificationConfiguration? {
        releaseVerificationStartup(
            environment: environment,
            arguments: arguments
        ).configuration
    }

    private static func validatedReleaseVerificationConfiguration(
        environment: [String: String],
        arguments: [String]
    ) -> ReleaseVerificationConfiguration? {
        let gate = "--easysplat-release-verify-bundled-pipeline"
        guard environment["EASYSPLAT_ISOLATED_UI_RUNNER"] == "1",
              hasOnlyReleaseVerificationPoisonValues(environment),
              arguments.count >= 2,
              arguments[1] == gate,
              let fixedHomePath = environment["CFFIXED_USER_HOME"],
              let homePath = environment["HOME"],
              let verificationToken = environment["EASYSPLAT_RELEASE_VERIFY_TOKEN"],
              isValidReleaseVerificationToken(verificationToken),
              (fixedHomePath as NSString).isAbsolutePath,
              (homePath as NSString).isAbsolutePath else {
            return nil
        }

        let fixedHome = URL(fileURLWithPath: fixedHomePath, isDirectory: true)
            .standardizedFileURL
            .resolvingSymlinksInPath()
        let home = URL(fileURLWithPath: homePath, isDirectory: true)
            .standardizedFileURL
            .resolvingSymlinksInPath()
        let isolatedRoot = fixedHome.deletingLastPathComponent()
        let isolatedInputRoot = isolatedRoot.appendingPathComponent(
            "ReleaseVerificationInput",
            isDirectory: true
        )
            .standardizedFileURL
            .resolvingSymlinksInPath()
        guard home == fixedHome,
              isOrdinaryDirectory(fixedHome),
              fixedHome.lastPathComponent == "ReleaseVerificationHome" else {
            return nil
        }
        let inputArguments = Array(arguments.dropFirst(2))
        guard inputArguments.count == 4,
              inputArguments[0] == "--input-manifest",
              inputArguments[2] == "--input-root" else {
            return nil
        }
        let manifestPath = inputArguments[1]
        let rootPath = inputArguments[3]
        guard (manifestPath as NSString).isAbsolutePath,
              (rootPath as NSString).isAbsolutePath else {
            return nil
        }
        let manifest = URL(fileURLWithPath: manifestPath).standardizedFileURL
        let inputRoot = URL(fileURLWithPath: rootPath, isDirectory: true)
            .standardizedFileURL
        let expectedManifest = isolatedInputRoot.appendingPathComponent(
            "release-input-manifest.json",
            isDirectory: false
        )
        guard manifest == expectedManifest,
              inputRoot == isolatedInputRoot else {
            return nil
        }
        guard (try? PackagedProjectInputResolver.resolve(
            manifestURL: manifest,
            inputRoot: inputRoot
        )) != nil else {
            return nil
        }
        return ReleaseVerificationConfiguration(
            inputManifestURL: manifest,
            inputRootURL: inputRoot,
            successMarkerURL: fixedHome.appendingPathComponent(
                "release-verification-pipeline-passed.json",
                isDirectory: false
            ),
            verificationToken: verificationToken
        )
    }

    private static func isReleaseVerificationAttempt(
        environment: [String: String],
        arguments: [String]
    ) -> Bool {
        if environment.keys.contains("EASYSPLAT_RELEASE_VERIFY_TOKEN") {
            return true
        }
        if arguments.dropFirst().contains(where: {
            $0.hasPrefix("--easysplat-release-verify")
        }) {
            return true
        }
        return releaseVerificationAttemptSentinelKeys.contains { key in
            guard let sentinel = releaseVerificationPoisonValues[key] else { return false }
            return environment[key] == sentinel
        }
    }

    private static func urlFromEnvironment(_ name: String, environment: [String: String]) -> URL? {
        guard let value = environment[name], !value.isEmpty else { return nil }
        return URL(string: value)
    }

    private static func hasOnlyReleaseVerificationPoisonValues(
        _ environment: [String: String]
    ) -> Bool {
        releaseVerificationPoisonValues.allSatisfy { key, expectedValue in
            environment[key].map { $0 == expectedValue } ?? true
        }
    }

    private static func readURLResource(named: String) -> URL? {
        guard let url = Bundle.module.url(forResource: named, withExtension: "txt"),
              let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    static func isValidReleaseVerificationToken(_ value: String) -> Bool {
        let prefix = "easysplat-release-verify-"
        guard value.hasPrefix(prefix) else { return false }
        let suffix = String(value.dropFirst(prefix.count))
        guard suffix.count == 36,
              let uuid = UUID(uuidString: suffix) else {
            return false
        }
        return uuid.uuidString.caseInsensitiveCompare(suffix) == .orderedSame
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
