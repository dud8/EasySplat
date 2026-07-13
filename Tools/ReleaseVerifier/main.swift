import EasySplatCore
import Foundation

private struct Arguments {
    var fixture: URL
    var manifestURL: URL
    var publicKeyFile: URL
    var cacheRoot: URL
    var output: URL
    var appVersion: String
    var offline: Bool

    static func parse(_ raw: [String]) throws -> Arguments {
        var values: [String: String] = [:]
        var offline = false
        var index = 0
        while index < raw.count {
            let option = raw[index]
            if option == "--offline" {
                offline = true
                index += 1
                continue
            }
            guard [
                "--fixture", "--manifest-url", "--public-key-file", "--cache-root", "--output",
                "--app-version",
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
              let appVersion = values["--app-version"] else {
            throw VerificationError.usage(
                "Usage: EasySplatReleaseVerifier --fixture <media> --manifest-url <https-url> "
                    + "--public-key-file <file> --cache-root <dir> --output <splat.ply> "
                    + "--app-version <semver> [--offline]"
            )
        }
        return Arguments(
            fixture: URL(fileURLWithPath: fixture),
            manifestURL: manifestURL,
            publicKeyFile: URL(fileURLWithPath: publicKeyFile),
            cacheRoot: URL(fileURLWithPath: cacheRoot, isDirectory: true),
            output: URL(fileURLWithPath: output),
            appVersion: appVersion,
            offline: offline
        )
    }
}

private enum VerificationError: Error, LocalizedError {
    case usage(String)
    case invalidFixture(String)
    case invalidPublicKey
    case missingOutput
    case invalidOutput(String)

    var errorDescription: String? {
        switch self {
        case .usage(let message), .invalidFixture(let message), .invalidOutput(let message):
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

        let options = RequestedRunOptions(
            capturePath: .automatic,
            detailProfile: .fast,
            cameraGrouping: .automatic,
            lensProjection: .automatic,
            inputOrdering: .automatic,
            resourcePolicy: .conserveMemory,
            photoSelection: .automatic
        )
        try RunPlanResolver.validate(requestedOptions: options, input: input)
        let plan = RunPlanResolver.resolveForCurrentHardware(
            requestedOptions: options,
            input: input,
            developmentOverrides: DevelopmentOverrides(benchmarkSeed: 42)
        )
        let request = ToolchainCapabilityRequest(
            capabilities: Set(ToolchainCapability.allCases)
        )
        let manifestURL = arguments.offline
            ? URL(string: "https://127.0.0.1:1/easysplat-offline-verification.json")!
            : arguments.manifestURL
        let manager = ToolchainManager(
            appVersion: arguments.appVersion,
            localToolchainRoot: nil,
            installationRoot: arguments.cacheRoot
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
        print(arguments.offline ? "Cached offline reconstruction passed." : "Fresh signed installation and reconstruction passed.")
    }
}
