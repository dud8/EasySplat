import Foundation
import CryptoKit

struct Manifest: Codable {
    var version: String
    var publishedAt: Date
    var artifacts: [Artifact]
    var signatureEd25519: String

    struct Artifact: Codable {
        var name: String
        var url: String
        var sha256: String
        var sizeBytes: UInt64
        var contents: [String]
    }
}

enum ExitCode: Int32 {
    case ok = 0
    case usage = 64
    case failure = 1
}

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
                try generateKeypair(publicOut: URL(fileURLWithPath: pubOut), privateOut: URL(fileURLWithPath: privOut))
                exit(ExitCode.ok.rawValue)
            } else {
                var parser = ArgParser(Array(args))
                let version = try parser.require("--version")
                let publishedAt = try parser.require("--published-at")
                let manifestOut = try parser.require("--manifest-out")
                let privateKey = try parser.require("--private-key")

                let artifacts: [Manifest.Artifact]
                if let coreZipPath = parser.value(for: "--core-zip") {
                    let coreURL = try parser.require("--core-url")
                    let modelsZipPath = try parser.require("--models-zip")
                    let modelsURL = try parser.require("--models-url")

                    let coreZipURL = URL(fileURLWithPath: coreZipPath)
                    let coreSize = try FileManager.default.attributesOfItem(atPath: coreZipURL.path)[.size] as? UInt64 ?? 0
                    let coreSha = try sha256Hex(url: coreZipURL)

                    let modelsZipURL = URL(fileURLWithPath: modelsZipPath)
                    let modelsSize = try FileManager.default.attributesOfItem(atPath: modelsZipURL.path)[.size] as? UInt64 ?? 0
                    let modelsSha = try sha256Hex(url: modelsZipURL)

                    let coreContents = [
                        "bin/colmap",
                        "bin/brush",
                        "bin/brush.real",
                        "lib/libcrypto.3.dylib",
                        "lib/libssl.3.dylib",
                        "vggt_mps/bin/easysplat_vggt_sfm",
                        "vggt_mps/python/bin/python3",
                        "vggt_mps/app/easysplat_vggt_sfm/run.py",
                        "vggt_mps/vendor/vggt/vggt/models/vggt.py",
                        "fastvggt_mps/bin/easysplat_fastvggt_sfm",
                        "fastvggt_mps/python/bin/python3",
                        "fastvggt_mps/app/easysplat_fastvggt_sfm/run.py",
                        "fastvggt_mps/vendor/fastvggt/vggt/models/vggt.py",
                    ]
                    let modelsContents = [
                        "vggt_mps/models/vggt_model.pt",
                        "fastvggt_mps/models/fastvggt_model.pt",
                    ]

                    artifacts = [
                        .init(name: "macos-arm64-core", url: coreURL, sha256: coreSha, sizeBytes: coreSize, contents: coreContents),
                        .init(name: "macos-arm64-models", url: modelsURL, sha256: modelsSha, sizeBytes: modelsSize, contents: modelsContents),
                    ]
                } else {
                    let zipPath = try parser.require("--zip")
                    let artifactURL = try parser.require("--artifact-url")

                    let zipURL = URL(fileURLWithPath: zipPath)
                    let size = try FileManager.default.attributesOfItem(atPath: zipURL.path)[.size] as? UInt64 ?? 0
                    let sha = try sha256Hex(url: zipURL)
                    let contents = [
                        "bin/colmap",
                        "bin/brush",
                        "bin/brush.real",
                        "lib/libcrypto.3.dylib",
                        "lib/libssl.3.dylib",
                        "vggt_mps/bin/easysplat_vggt_sfm",
                        "vggt_mps/python/bin/python3",
                        "vggt_mps/app/easysplat_vggt_sfm/run.py",
                        "vggt_mps/vendor/vggt/vggt/models/vggt.py",
                        "vggt_mps/models/vggt_model.pt",
                        "fastvggt_mps/bin/easysplat_fastvggt_sfm",
                        "fastvggt_mps/python/bin/python3",
                        "fastvggt_mps/app/easysplat_fastvggt_sfm/run.py",
                        "fastvggt_mps/vendor/fastvggt/vggt/models/vggt.py",
                        "fastvggt_mps/models/fastvggt_model.pt",
                    ]

                    artifacts = [
                        .init(name: "macos-arm64", url: artifactURL, sha256: sha, sizeBytes: size, contents: contents)
                    ]
                }

                let formatter = ISO8601DateFormatter()
                guard let date = formatter.date(from: publishedAt) else {
                    throw NSError(domain: "ManifestTool", code: 2, userInfo: [NSLocalizedDescriptionKey: "Invalid --published-at ISO-8601 date"])
                }

                var manifest = Manifest(
                    version: version,
                    publishedAt: date,
                    artifacts: artifacts,
                    signatureEd25519: ""
                )

                let canonical = try canonicalData(for: manifest)
                let signature = try sign(data: canonical, privateKeyBase64: privateKey)
                manifest.signatureEd25519 = signature

                try writeManifest(manifest, to: URL(fileURLWithPath: manifestOut))
                exit(ExitCode.ok.rawValue)
            }
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

    private static func generateKeypair(publicOut: URL, privateOut: URL) throws {
        let key = Curve25519.Signing.PrivateKey()
        let publicKey = key.publicKey.rawRepresentation.base64EncodedString()
        let privateKey = key.rawRepresentation.base64EncodedString()
        try publicKey.write(to: publicOut, atomically: true, encoding: .utf8)
        try privateKey.write(to: privateOut, atomically: true, encoding: .utf8)
    }

    private static func canonicalData(for manifest: Manifest) throws -> Data {
        var copy = manifest
        copy.signatureEd25519 = ""
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(copy)
    }

    private static func writeManifest(_ manifest: Manifest, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(manifest)
        try data.write(to: url, options: [.atomic])
    }

    private static func sign(data: Data, privateKeyBase64: String) throws -> String {
        guard let keyData = Data(base64Encoded: privateKeyBase64) else {
            throw NSError(domain: "ManifestTool", code: 3, userInfo: [NSLocalizedDescriptionKey: "Invalid private key base64"])
        }
        let key = try Curve25519.Signing.PrivateKey(rawRepresentation: keyData)
        let signature = try key.signature(for: data)
        return Data(signature).base64EncodedString()
    }

    private static func sha256Hex(url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            let data = try handle.read(upToCount: 1024 * 1024) ?? Data()
            if data.isEmpty { break }
            hasher.update(data: data)
        }
        let digest = hasher.finalize()
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

struct ArgParser {
    private var args: [String]

    init(_ args: [String]) {
        self.args = args
    }

    mutating func require(_ key: String) throws -> String {
        guard let value = value(for: key) else {
            throw NSError(domain: "ManifestTool", code: 4, userInfo: [NSLocalizedDescriptionKey: "Missing \(key)"])
        }
        return value
    }

    mutating func value(for key: String) -> String? {
        guard let index = args.firstIndex(of: key), index + 1 < args.count else { return nil }
        let value = args[index + 1]
        return value.hasPrefix("--") ? nil : value
    }
}
