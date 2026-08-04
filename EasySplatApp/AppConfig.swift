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
    private static let releaseVerificationPoisonValues = [
        "EASYSPLAT_PROJECT_HOME_URL": "https://release-verifier-poison.invalid/project",
        "EASYSPLAT_LOCAL_TOOLCHAIN_ROOT": "/release-verifier-poison/toolchain",
        "EASYSPLAT_SKIP_TRAINING": "1",
        "EASYSPLAT_STOP_AFTER_STAGE": PipelineStage.sfmMapping.rawValue,
        "EASYSPLAT_CANDIDATE_ROUTE": "da3",
        "EASYSPLAT_BENCHMARK_SEED": "2147483647",
    ]
    private static let releaseVerificationAttemptSentinelKeys = [
        "EASYSPLAT_PROJECT_HOME_URL",
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
