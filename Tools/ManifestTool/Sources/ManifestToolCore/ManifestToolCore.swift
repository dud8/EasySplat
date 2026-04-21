import CryptoKit
import Foundation

public struct ManifestDocument: Codable, Equatable {
    public var version: String
    public var publishedAt: Date
    public var artifacts: [Artifact]
    public var signatureEd25519: String

    public struct Artifact: Codable, Equatable {
        public var name: String
        public var url: String
        public var sha256: String
        public var sizeBytes: UInt64
        public var contents: [String]

        public init(name: String, url: String, sha256: String, sizeBytes: UInt64, contents: [String]) {
            self.name = name
            self.url = url
            self.sha256 = sha256
            self.sizeBytes = sizeBytes
            self.contents = contents
        }
    }

    public init(version: String, publishedAt: Date, artifacts: [Artifact], signatureEd25519: String) {
        self.version = version
        self.publishedAt = publishedAt
        self.artifacts = artifacts
        self.signatureEd25519 = signatureEd25519
    }
}

public struct ManifestArtifactInput: Equatable {
    public var name: String
    public var artifactURL: String
    public var zipURL: URL
    public var contents: [String]

    public init(name: String, artifactURL: String, zipURL: URL, contents: [String]) {
        self.name = name
        self.artifactURL = artifactURL
        self.zipURL = zipURL
        self.contents = contents
    }
}

public enum ManifestBuilder {
    public static func build(
        version: String,
        publishedAt: Date,
        artifacts: [ManifestArtifactInput],
        privateKeyBase64: String
    ) throws -> ManifestDocument {
        let builtArtifacts = try artifacts.map(makeArtifact(from:))
        var manifest = ManifestDocument(
            version: version,
            publishedAt: publishedAt,
            artifacts: builtArtifacts,
            signatureEd25519: ""
        )
        manifest.signatureEd25519 = try sign(data: canonicalData(for: manifest), privateKeyBase64: privateKeyBase64)
        return manifest
    }

    public static func generateKeypair() -> (publicKeyBase64: String, privateKeyBase64: String) {
        let key = Curve25519.Signing.PrivateKey()
        return (
            publicKeyBase64: key.publicKey.rawRepresentation.base64EncodedString(),
            privateKeyBase64: key.rawRepresentation.base64EncodedString()
        )
    }

    public static func canonicalData(for manifest: ManifestDocument) throws -> Data {
        var copy = manifest
        copy.signatureEd25519 = ""
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(copy)
    }

    public static func verifySignature(for manifest: ManifestDocument, publicKeyBase64: String) -> Bool {
        guard let signatureData = Data(base64Encoded: manifest.signatureEd25519),
              let publicKeyData = Data(base64Encoded: publicKeyBase64),
              let canonical = try? canonicalData(for: manifest),
              let publicKey = try? Curve25519.Signing.PublicKey(rawRepresentation: publicKeyData) else {
            return false
        }
        return publicKey.isValidSignature(signatureData, for: canonical)
    }

    public static func writeManifest(_ manifest: ManifestDocument, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(manifest).write(to: url, options: [.atomic])
    }

    public static func sha256Hex(url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            let data = try handle.read(upToCount: 1024 * 1024) ?? Data()
            if data.isEmpty { break }
            hasher.update(data: data)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func makeArtifact(from input: ManifestArtifactInput) throws -> ManifestDocument.Artifact {
        let size = try FileManager.default.attributesOfItem(atPath: input.zipURL.path)[.size] as? UInt64 ?? 0
        let sha = try sha256Hex(url: input.zipURL)
        return ManifestDocument.Artifact(
            name: input.name,
            url: input.artifactURL,
            sha256: sha,
            sizeBytes: size,
            contents: input.contents
        )
    }

    private static func sign(data: Data, privateKeyBase64: String) throws -> String {
        guard let keyData = Data(base64Encoded: privateKeyBase64) else {
            throw NSError(domain: "ManifestTool", code: 3, userInfo: [NSLocalizedDescriptionKey: "Invalid private key base64"])
        }
        let key = try Curve25519.Signing.PrivateKey(rawRepresentation: keyData)
        return try key.signature(for: data).base64EncodedString()
    }
}

public enum ManifestToolDefaults {
    public static let splitCoreContents = [
        "bin/colmap",
        "bin/brush",
        "bin/brush.real",
        "lib/libcrypto.3.dylib",
        "lib/libssl.3.dylib",
        "mapanything_mps/bin/easysplat_mapanything_sfm",
        "mapanything_mps/python/bin/python3",
        "mapanything_mps/build_info.json",
        "mapanything_mps/app/easysplat_mapanything_sfm/run.py",
        "mapanything_mps/vendor/mapanything/mapanything/models/mapanything/model.py",
        "vggt_mps/bin/easysplat_vggt_sfm",
        "vggt_mps/python/bin/python3",
        "vggt_mps/build_info.json",
        "vggt_mps/app/easysplat_vggt_sfm/run.py",
        "vggt_mps/vendor/vggt/vggt/models/vggt.py",
        "fastvggt_mps/bin/easysplat_fastvggt_sfm",
        "fastvggt_mps/python/bin/python3",
        "fastvggt_mps/build_info.json",
        "fastvggt_mps/app/easysplat_fastvggt_sfm/run.py",
        "fastvggt_mps/vendor/fastvggt/vggt/models/vggt.py",
    ]

    public static let splitModelsContents = [
        "mapanything_mps/models/map-anything-apache/config.json",
        "mapanything_mps/models/map-anything-apache/model.safetensors",
        "mapanything_mps/models/dinov2/dinov2_vitg14_pretrain.pth",
        "vggt_mps/models/vggt_model.pt",
        "fastvggt_mps/models/fastvggt_model.pt",
    ]

    public static let monolithicContents = splitCoreContents + splitModelsContents
}

public enum ExitCode: Int32 {
    case ok = 0
    case usage = 64
    case failure = 1
}

public struct ArgParser {
    private var args: [String]

    public init(_ args: [String]) {
        self.args = args
    }

    public mutating func require(_ key: String) throws -> String {
        guard let value = value(for: key) else {
            throw NSError(domain: "ManifestTool", code: 4, userInfo: [NSLocalizedDescriptionKey: "Missing \(key)"])
        }
        return value
    }

    public mutating func value(for key: String) -> String? {
        guard let index = args.firstIndex(of: key), index + 1 < args.count else { return nil }
        let value = args[index + 1]
        return value.hasPrefix("--") ? nil : value
    }
}
