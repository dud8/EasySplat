import Foundation
import ManifestToolCore

@main
struct ManifestTool {
    static func main() {
        do {
            let args = CommandLine.arguments.dropFirst()
            guard let command = args.first else {
                try usage()
                exit(ExitCode.usage.rawValue)
            }

            if command == "generate-keypair" {
                var parser = ArgParser(Array(args.dropFirst()))
                let pubOut = try parser.require("--public-key-out")
                let privOut = try parser.require("--private-key-out")
                let keypair = ManifestBuilder.generateKeypair()
                try keypair.publicKeyBase64.write(to: URL(fileURLWithPath: pubOut), atomically: true, encoding: .utf8)
                try keypair.privateKeyBase64.write(to: URL(fileURLWithPath: privOut), atomically: true, encoding: .utf8)
                exit(ExitCode.ok.rawValue)
            }

            var parser = ArgParser(Array(args))
            let version = try parser.require("--version")
            let publishedAtValue = try parser.require("--published-at")
            let manifestOut = try parser.require("--manifest-out")
            let privateKey = try parser.require("--private-key")
            let publishedAt = try parsePublishedAt(publishedAtValue)

            let artifactInputs = try buildArtifactInputs(parser: &parser)
            let manifest = try ManifestBuilder.build(
                version: version,
                publishedAt: publishedAt,
                artifacts: artifactInputs,
                privateKeyBase64: privateKey
            )
            try ManifestBuilder.writeManifest(manifest, to: URL(fileURLWithPath: manifestOut))
            exit(ExitCode.ok.rawValue)
        } catch {
            fputs("ManifestTool error: \(error)\n", stderr)
            exit(ExitCode.failure.rawValue)
        }
    }

    private static func usage() throws {
        let text = """
        ManifestTool

        Generate keypair:
          ManifestTool generate-keypair --public-key-out <path> --private-key-out <path>

        Generate manifest (single artifact):
          ManifestTool --zip <path> --version <semver> --published-at <iso8601> \\
            --artifact-url <url> --private-key <base64> --manifest-out <path>

        Generate manifest (core + models):
          ManifestTool --core-zip <path> --core-url <url> \\
            --models-zip <path> --models-url <url> \\
            --version <semver> --published-at <iso8601> \\
            --private-key <base64> --manifest-out <path>
        """
        print(text)
    }

    private static func parsePublishedAt(_ value: String) throws -> Date {
        let formatter = ISO8601DateFormatter()
        guard let date = formatter.date(from: value) else {
            throw NSError(
                domain: "ManifestTool",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Invalid --published-at ISO-8601 date"]
            )
        }
        return date
    }

    private static func buildArtifactInputs(parser: inout ArgParser) throws -> [ManifestArtifactInput] {
        if let coreZipPath = parser.value(for: "--core-zip") {
            let coreURL = try parser.require("--core-url")
            let modelsZipPath = try parser.require("--models-zip")
            let modelsURL = try parser.require("--models-url")
            return [
                ManifestArtifactInput(
                    name: "macos-arm64-core",
                    artifactURL: coreURL,
                    zipURL: URL(fileURLWithPath: coreZipPath),
                    contents: ManifestToolDefaults.splitCoreContents
                ),
                ManifestArtifactInput(
                    name: "macos-arm64-models",
                    artifactURL: modelsURL,
                    zipURL: URL(fileURLWithPath: modelsZipPath),
                    contents: ManifestToolDefaults.splitModelsContents
                ),
            ]
        }

        let zipPath = try parser.require("--zip")
        let artifactURL = try parser.require("--artifact-url")
        return [
            ManifestArtifactInput(
                name: "macos-arm64",
                artifactURL: artifactURL,
                zipURL: URL(fileURLWithPath: zipPath),
                contents: ManifestToolDefaults.monolithicContents
            )
        ]
    }
}
