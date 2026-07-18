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
                try ManifestKeyInput.writePrivateKeyBase64(keypair.privateKeyBase64, to: URL(fileURLWithPath: privOut))
                exit(ExitCode.ok.rawValue)
            }

            if command == "verify-bootstrap" {
                var parser = ArgParser(Array(args.dropFirst()))
                try parser.requireOnly([
                    "--manifest",
                    "--public-key-file",
                    "--app-version",
                    "--core-zip",
                ])
                let manifestURL = URL(fileURLWithPath: try parser.require("--manifest"))
                let publicKeyURL = URL(fileURLWithPath: try parser.require("--public-key-file"))
                let appVersion = try parser.require("--app-version")
                let coreArchive = URL(fileURLWithPath: try parser.require("--core-zip"))
                let decoder = JSONDecoder()
                decoder.dateDecodingStrategy = .iso8601
                let manifest = try decoder.decode(
                    ManifestDocument.self,
                    from: Data(contentsOf: manifestURL)
                )
                let publicKeyBase64 = try String(contentsOf: publicKeyURL, encoding: .utf8)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                try ManifestBuilder.verifyBootstrap(
                    manifest: manifest,
                    publicKeyBase64: publicKeyBase64,
                    expectedAppVersion: appVersion,
                    coreArchive: coreArchive
                )
                print("Verified signed core bootstrap \(manifest.version)")
                exit(ExitCode.ok.rawValue)
            }

            if command == "verify-release" {
                var parser = ArgParser(Array(args.dropFirst()))
                let manifestURL = URL(fileURLWithPath: try parser.require("--manifest"))
                let publicKeyURL = URL(fileURLWithPath: try parser.require("--public-key-file"))
                let version = try parser.require("--toolchain-version")
                let appVersion = try parser.require("--app-version")
                let coreURL = try parser.require("--core-url")
                let baseURL = try parser.require("--da3-base-url")
                let smallURL = try parser.require("--da3-small-url")
                let decoder = JSONDecoder()
                decoder.dateDecodingStrategy = .iso8601
                let manifest = try decoder.decode(
                    ManifestDocument.self,
                    from: Data(contentsOf: manifestURL)
                )
                let publicKey = try String(contentsOf: publicKeyURL, encoding: .utf8)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                try ManifestBuilder.verifyRelease(
                    manifest: manifest,
                    publicKeyBase64: publicKey,
                    expectedToolchainVersion: version,
                    expectedAppVersion: appVersion,
                    expectedComponentURLs: [
                        "macos-arm64-core": coreURL,
                        "geometry-da3-base": baseURL,
                        "geometry-da3-small": smallURL,
                    ],
                    componentArchives: [
                        "macos-arm64-core": URL(fileURLWithPath: try parser.require("--core-zip")),
                        "geometry-da3-base": URL(fileURLWithPath: try parser.require("--da3-base-zip")),
                        "geometry-da3-small": URL(fileURLWithPath: try parser.require("--da3-small-zip")),
                    ]
                )
                print("Verified signed toolchain closure \(version)")
                exit(ExitCode.ok.rawValue)
            }

            if command == "prepare-release" {
                var parser = ArgParser(Array(args.dropFirst()))
                try parser.requireOnly([
                    "--repository",
                    "--source-commit",
                    "--version",
                    "--published-at",
                    "--app-version-minimum",
                    "--app-version-maximum-exclusive",
                    "--public-key-file",
                    "--core-zip",
                    "--core-url",
                    "--da3-base-zip",
                    "--da3-base-url",
                    "--da3-small-zip",
                    "--da3-small-url",
                    "--request-out",
                ])
                let repository = try parser.require("--repository")
                let sourceCommit = try parser.require("--source-commit")
                let version = try parser.require("--version")
                let publishedAt = try parsePublishedAt(parser.require("--published-at"))
                let appRange = ManifestDocument.AppVersionRange(
                    minimum: try parser.require("--app-version-minimum"),
                    maximumExclusive: try parser.require("--app-version-maximum-exclusive")
                )
                let publicKey = try readPublicKey(
                    at: URL(fileURLWithPath: parser.require("--public-key-file"))
                )
                let request = try ManifestBuilder.prepareRelease(
                    repository: repository,
                    sourceCommit: sourceCommit,
                    version: version,
                    publishedAt: publishedAt,
                    appVersionRange: appRange,
                    publicKeyBase64: publicKey,
                    components: buildComponentInputs(parser: &parser)
                )
                try ManifestBuilder.writeReleaseSigningRequest(
                    request,
                    to: URL(fileURLWithPath: parser.require("--request-out"))
                )
                exit(ExitCode.ok.rawValue)
            }

            var parser = ArgParser(Array(args))
            let version = try parser.require("--version")
            let publishedAtValue = try parser.require("--published-at")
            let manifestOut = try parser.require("--manifest-out")
            let privateKey = try ManifestKeyInput.resolvePrivateKeyBase64(parser: &parser)
            let publishedAt = try parsePublishedAt(publishedAtValue)
            let minimumAppVersion = try parser.require("--app-version-minimum")
            let maximumAppVersion = try parser.require("--app-version-maximum-exclusive")

            let componentInputs = try buildComponentInputs(parser: &parser)
            let manifest = try ManifestBuilder.build(
                version: version,
                publishedAt: publishedAt,
                appVersionRange: .init(minimum: minimumAppVersion, maximumExclusive: maximumAppVersion),
                components: componentInputs,
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

        Generate schema-2 component manifest:
          ManifestTool --core-zip <path> --core-url <url> \\
            --da3-base-zip <path> --da3-base-url <url> \\
            --da3-small-zip <path> --da3-small-url <url> \\
            --version <semver> --published-at <iso8601> \\
            --app-version-minimum <semver> --app-version-maximum-exclusive <semver> \\
            --private-key-file <path> --manifest-out <path>

        Verify a signed release closure:
          ManifestTool verify-release --manifest <path> --public-key-file <path> \
            --toolchain-version <semver> --app-version <semver> \
            --core-zip <path> --core-url <url> \
            --da3-base-zip <path> --da3-base-url <url> \
            --da3-small-zip <path> --da3-small-url <url>

        Verify a signed bundled core bootstrap:
          ManifestTool verify-bootstrap --manifest <path> --public-key-file <path> \
            --app-version <semver> --core-zip <path>

        Prepare a canonical release signing request without a private key:
          ManifestTool prepare-release --repository <owner/repo> --source-commit <sha> \
            --version <semver> --published-at <iso8601> \
            --app-version-minimum <semver> --app-version-maximum-exclusive <semver> \
            --public-key-file <path> \
            --core-zip <path> --core-url <url> \
            --da3-base-zip <path> --da3-base-url <url> \
            --da3-small-zip <path> --da3-small-url <url> \
            --request-out <path>

        Private key source:
          Use exactly one of --private-key-file <path> or --private-key-env <name>.
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

    private static func readPublicKey(at url: URL) throws -> String {
        try String(contentsOf: url, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func buildComponentInputs(
        parser: inout ArgParser
    ) throws -> [ManifestArtifactInput] {
        let coreZipPath = try parser.require("--core-zip")
        let coreURL = try parser.require("--core-url")
        let baseZipPath = try parser.require("--da3-base-zip")
        let baseURL = try parser.require("--da3-base-url")
        let smallZipPath = try parser.require("--da3-small-zip")
        let smallURL = try parser.require("--da3-small-url")
        return [
            ManifestArtifactInput(
                name: "macos-arm64-core",
                artifactURL: coreURL,
                zipURL: URL(fileURLWithPath: coreZipPath),
                capabilities: ManifestToolDefaults.coreCapabilities,
                dependencies: [],
                requirement: .required,
                criticalFilePaths: ManifestToolDefaults.criticalCoreFiles
            ),
            ManifestArtifactInput(
                name: "geometry-da3-base",
                artifactURL: baseURL,
                zipURL: URL(fileURLWithPath: baseZipPath),
                capabilities: ["geometry.da3.runtime", "geometry.da3.base"],
                dependencies: ["macos-arm64-core"],
                requirement: .optional,
                criticalFilePaths: ManifestToolDefaults.da3BaseContents
            ),
            ManifestArtifactInput(
                name: "geometry-da3-small",
                artifactURL: smallURL,
                zipURL: URL(fileURLWithPath: smallZipPath),
                capabilities: ["geometry.da3.small"],
                dependencies: ["geometry-da3-base"],
                requirement: .optional,
                criticalFilePaths: ManifestToolDefaults.da3SmallContents
            ),
        ]
    }
}
