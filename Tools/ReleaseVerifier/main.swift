import EasySplatCore
import Foundation

private enum InstallationPolicy: String {
    case remoteOnly = "remote-only"
    case bundledBootstrapOnly = "bundled-bootstrap-only"
}

private struct Arguments {
    var fixture: URL
    var manifestURL: URL
    var publicKeyFile: URL
    var bootstrapManifest: URL?
    var bootstrapCoreArchive: URL?
    var cacheRoot: URL
    var output: URL
    var appVersion: String
    var installationPolicy: InstallationPolicy
    var offline: Bool
    var allowInsecureLoopbackHTTP: Bool

    static func parse(_ raw: [String]) throws -> Arguments {
        var values: [String: String] = [:]
        var offline = false
        var allowInsecureLoopbackHTTP = false
        var index = 0
        while index < raw.count {
            let option = raw[index]
            if option == "--offline" {
                offline = true
                index += 1
                continue
            }
            if option == "--allow-insecure-loopback-http" {
                allowInsecureLoopbackHTTP = true
                index += 1
                continue
            }
            guard [
                "--fixture", "--manifest-url", "--public-key-file", "--cache-root", "--output",
                "--app-version", "--bootstrap-manifest", "--bootstrap-core-archive",
                "--installation-policy",
            ].contains(option), index + 1 < raw.count else {
                throw VerificationError.usage("Unknown or incomplete option: \(option)")
            }
            values[option] = raw[index + 1]
            index += 2
        }

        guard let fixture = values["--fixture"],
              let manifest = values["--manifest-url"],
              let manifestURL = URL(string: manifest),
              let publicKeyFile = values["--public-key-file"],
              let cacheRoot = values["--cache-root"],
              let output = values["--output"],
              let appVersion = values["--app-version"],
              let policyValue = values["--installation-policy"],
              let installationPolicy = InstallationPolicy(rawValue: policyValue) else {
            throw VerificationError.usage(
                "Usage: EasySplatReleaseVerifier --fixture <media> --manifest-url <https-url> "
                    + "--public-key-file <file> --cache-root <dir> --output <splat.ply> "
                    + "--app-version <semver> --installation-policy <remote-only|bundled-bootstrap-only> "
                    + "[--bootstrap-manifest <manifest.json> --bootstrap-core-archive <core.zip> --offline] "
                    + "[--allow-insecure-loopback-http]"
            )
        }
        switch installationPolicy {
        case .remoteOnly where offline:
            throw VerificationError.usage("The remote-only installation policy cannot be combined with --offline.")
        case .remoteOnly where values["--bootstrap-manifest"] != nil || values["--bootstrap-core-archive"] != nil:
            throw VerificationError.usage("The remote-only installation policy cannot receive bundled-bootstrap inputs.")
        case .bundledBootstrapOnly where !offline:
            throw VerificationError.usage("The bundled-bootstrap-only installation policy requires --offline.")
        case .bundledBootstrapOnly where values["--bootstrap-manifest"] == nil || values["--bootstrap-core-archive"] == nil:
            throw VerificationError.usage(
                "The bundled-bootstrap-only installation policy requires both bootstrap inputs."
            )
        default:
            break
        }
        return Arguments(
            fixture: URL(fileURLWithPath: fixture),
            manifestURL: manifestURL,
            publicKeyFile: URL(fileURLWithPath: publicKeyFile),
            bootstrapManifest: values["--bootstrap-manifest"].map(URL.init(fileURLWithPath:)),
            bootstrapCoreArchive: values["--bootstrap-core-archive"].map(URL.init(fileURLWithPath:)),
            cacheRoot: URL(fileURLWithPath: cacheRoot, isDirectory: true),
            output: URL(fileURLWithPath: output),
            appVersion: appVersion,
            installationPolicy: installationPolicy,
            offline: offline,
            allowInsecureLoopbackHTTP: allowInsecureLoopbackHTTP
        )
    }
}

private enum VerificationError: Error, LocalizedError {
    case usage(String)
    case invalidFixture(String)
    case invalidPublicKey
    case nonemptyCacheRoot(String)
    case missingOutput
    case invalidOutput(String)

    var errorDescription: String? {
        switch self {
        case .usage(let message), .invalidFixture(let message), .invalidOutput(let message),
             .nonemptyCacheRoot(let message):
            return message
        case .invalidPublicKey:
            return "The toolchain public-key file is empty."
        case .missingOutput:
            return "The completed project did not record a PLY output."
        }
    }
}

@main
private enum ReleaseVerifier {
    static func main() async {
        do {
            try await run()
        } catch {
            FileHandle.standardError.write(Data("Release verification failed: \(error.localizedDescription)\n".utf8))
            Foundation.exit(EXIT_FAILURE)
        }
    }

    private static func run() async throws {
        let arguments = try Arguments.parse(Array(CommandLine.arguments.dropFirst()))
        let fileManager = FileManager.default
        var isDirectory = ObjCBool(false)
        guard fileManager.fileExists(atPath: arguments.fixture.path, isDirectory: &isDirectory) else {
            throw VerificationError.invalidFixture("Release fixture does not exist: \(arguments.fixture.path)")
        }
        let input: InputSpec
        if isDirectory.boolValue {
            input = .photos(folder: arguments.fixture.path)
        } else {
            input = .video(files: [arguments.fixture.path])
        }

        let publicKey = try String(contentsOf: arguments.publicKeyFile, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !publicKey.isEmpty else { throw VerificationError.invalidPublicKey }
        try fileManager.createDirectory(at: arguments.cacheRoot, withIntermediateDirectories: true)
        guard try fileManager.contentsOfDirectory(atPath: arguments.cacheRoot.path).isEmpty else {
            throw VerificationError.nonemptyCacheRoot(
                "Release-verification cache root must start empty: \(arguments.cacheRoot.path)"
            )
        }

        let options = RequestedRunOptions(
            capturePath: .automatic,
            detailProfile: .balanced,
            cameraGrouping: .automatic,
            lensProjection: .automatic,
            inputOrdering: .automatic,
            resourcePolicy: .automatic,
            photoSelection: .automatic
        )
        try RunPlanResolver.validate(requestedOptions: options, input: input)
        let plan = RunPlanResolver.resolveForCurrentHardware(
            requestedOptions: options,
            input: input,
            developmentOverrides: DevelopmentOverrides(benchmarkSeed: 42)
        )
        let request = try plan.toolchainCapabilityRequest()
        let manifestURL: URL
        let bundledBootstrap: ToolchainBootstrap?
        switch arguments.installationPolicy {
        case .remoteOnly:
            manifestURL = arguments.manifestURL
            bundledBootstrap = nil
        case .bundledBootstrapOnly:
            guard let bootstrapManifest = arguments.bootstrapManifest,
                  let bootstrapCoreArchive = arguments.bootstrapCoreArchive else {
                throw VerificationError.usage("Bundled-bootstrap inputs are missing.")
            }
            manifestURL = URL(string: "https://127.0.0.1:1/easysplat-offline-verification.json")!
            bundledBootstrap = ToolchainBootstrap(
                manifestURL: bootstrapManifest,
                coreArchiveURL: bootstrapCoreArchive
            )
        }
        let manager = ToolchainManager(
            appVersion: arguments.appVersion,
            localToolchainRoot: nil,
            installationRoot: arguments.cacheRoot,
            allowInsecureLoopbackHTTP: arguments.allowInsecureLoopbackHTTP,
            bundledBootstrap: bundledBootstrap
        )
        let toolchain = try await manager.ensureToolchain(
            manifestURL: manifestURL,
            publicKeyBase64: publicKey,
            request: request
        ) { fraction, message in
            let progress = fraction >= 0 ? " \(Int((fraction * 100).rounded()))%" : ""
            print("Tools:\(progress) \(message)")
        }

        let projectParent = arguments.output.deletingLastPathComponent()
        try fileManager.createDirectory(at: projectParent, withIntermediateDirectories: true)
        let projectURL = projectParent.appendingPathComponent(
            arguments.offline ? "Offline.easysplatproj" : "Online.easysplatproj",
            isDirectory: true
        )
        if fileManager.fileExists(atPath: projectURL.path) {
            try fileManager.removeItem(at: projectURL)
        }
        let paths = ProjectPaths(root: projectURL)
        try paths.ensureDirectories()
        let metadata = ProjectMetadata(
            title: "Release Verification",
            input: input,
            requestedRunOptions: options,
            resolvedRunPlan: plan
        )
        try ProjectMetadataStore.save(metadata, to: paths.metadataURL)

        let runner = PipelineRunner(
            projectURL: projectURL,
            config: .init(
                toolchain: toolchain,
                developmentOverrides: DevelopmentOverrides(benchmarkSeed: 42),
                resolvedRunPlan: plan
            )
        )
        try await runner.run { event in
            switch event {
            case .stageStarted(let stage):
                print("Stage: \(stage.rawValue)")
            case .stageLog(_, let line, let isError):
                let stream = isError ? FileHandle.standardError : FileHandle.standardOutput
                stream.write(Data("\(line)\n".utf8))
            default:
                break
            }
        }

        let completed = try ProjectMetadataStore.load(from: paths.metadataURL)
        guard let relativeOutput = completed.outputs?.splatPlyPath else {
            throw VerificationError.missingOutput
        }
        let validated = try ProjectArtifactValidator.resolveValidatedOutputPly(
            paths: paths,
            relativePath: relativeOutput
        )
        if fileManager.fileExists(atPath: arguments.output.path) {
            try fileManager.removeItem(at: arguments.output)
        }
        try fileManager.copyItem(at: validated, to: arguments.output)
        guard case .valid = ProjectArtifactValidator.validatePlyFile(at: arguments.output) else {
            throw VerificationError.invalidOutput("The copied release-verification output is not a valid Gaussian PLY.")
        }
        print(arguments.installationPolicy == .bundledBootstrapOnly
            ? "Bundled-bootstrap-only reconstruction passed."
            : "Fresh remote-only signed installation and reconstruction passed.")
    }
}
