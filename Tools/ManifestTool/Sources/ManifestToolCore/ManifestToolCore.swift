import CryptoKit
import Foundation

public struct ManifestDocument: Codable, Equatable {
    public enum ComponentRequirement: String, Codable, Equatable {
        case required
        case optional
    }

    public struct AppVersionRange: Codable, Equatable {
        public var minimum: String
        public var maximumExclusive: String?

        public init(minimum: String, maximumExclusive: String?) {
            self.minimum = minimum
            self.maximumExclusive = maximumExclusive
        }
    }

    public var schemaVersion: Int
    public var toolchainAPI: Int
    public var keyID: String
    public var version: String
    public var publishedAt: Date
    public var appVersionRange: AppVersionRange
    public var components: [Component]
    public var signatureEd25519: String

    public struct Component: Codable, Equatable {
        public var name: String
        public var capabilities: [String]
        public var url: String
        public var sha256: String
        public var sizeBytes: UInt64
        public var contents: [String]
        public var criticalFileHashes: [String: String]
        public var dependencies: [String]
        public var requirement: ComponentRequirement
        private var encodesLegacyExecutableHashes: Bool

        public var executableHashes: [String: String] {
            get { criticalFileHashes }
            set {
                criticalFileHashes = newValue
                encodesLegacyExecutableHashes = true
            }
        }

        public init(
            name: String,
            capabilities: [String],
            url: String,
            sha256: String,
            sizeBytes: UInt64,
            contents: [String],
            executableHashes: [String: String],
            dependencies: [String],
            requirement: ComponentRequirement
        ) {
            self.name = name
            self.capabilities = capabilities
            self.url = url
            self.sha256 = sha256
            self.sizeBytes = sizeBytes
            self.contents = contents
            self.criticalFileHashes = executableHashes
            self.dependencies = dependencies
            self.requirement = requirement
            self.encodesLegacyExecutableHashes = true
        }

        public init(
            name: String,
            capabilities: [String],
            url: String,
            sha256: String,
            sizeBytes: UInt64,
            contents: [String],
            criticalFileHashes: [String: String],
            dependencies: [String],
            requirement: ComponentRequirement
        ) {
            self.name = name
            self.capabilities = capabilities
            self.url = url
            self.sha256 = sha256
            self.sizeBytes = sizeBytes
            self.contents = contents
            self.criticalFileHashes = criticalFileHashes
            self.dependencies = dependencies
            self.requirement = requirement
            self.encodesLegacyExecutableHashes = false
        }

        public init(
            name: String,
            url: String,
            sha256: String,
            sizeBytes: UInt64,
            contents: [String]
        ) {
            self.init(
                name: name,
                capabilities: [],
                url: url,
                sha256: sha256,
                sizeBytes: sizeBytes,
                contents: contents,
                executableHashes: [:],
                dependencies: [],
                requirement: .required
            )
        }

        private enum CodingKeys: String, CodingKey {
            case name
            case capabilities
            case url
            case sha256
            case sizeBytes
            case contents
            case criticalFileHashes
            case executableHashes
            case dependencies
            case requirement
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            name = try container.decode(String.self, forKey: .name)
            capabilities = try container.decode([String].self, forKey: .capabilities)
            url = try container.decode(String.self, forKey: .url)
            sha256 = try container.decode(String.self, forKey: .sha256)
            sizeBytes = try container.decode(UInt64.self, forKey: .sizeBytes)
            contents = try container.decode([String].self, forKey: .contents)
            dependencies = try container.decode([String].self, forKey: .dependencies)
            requirement = try container.decode(ComponentRequirement.self, forKey: .requirement)

            let critical = try container.decodeIfPresent(
                [String: String].self,
                forKey: .criticalFileHashes
            )
            let legacy = try container.decodeIfPresent(
                [String: String].self,
                forKey: .executableHashes
            )
            guard critical == nil || legacy == nil else {
                throw DecodingError.dataCorruptedError(
                    forKey: .criticalFileHashes,
                    in: container,
                    debugDescription: "Component cannot contain both criticalFileHashes and executableHashes."
                )
            }
            if let critical {
                criticalFileHashes = critical
                encodesLegacyExecutableHashes = false
            } else {
                criticalFileHashes = legacy ?? [:]
                encodesLegacyExecutableHashes = true
            }
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(name, forKey: .name)
            try container.encode(capabilities, forKey: .capabilities)
            try container.encode(url, forKey: .url)
            try container.encode(sha256, forKey: .sha256)
            try container.encode(sizeBytes, forKey: .sizeBytes)
            try container.encode(contents, forKey: .contents)
            if encodesLegacyExecutableHashes {
                try container.encode(criticalFileHashes, forKey: .executableHashes)
            } else {
                try container.encode(criticalFileHashes, forKey: .criticalFileHashes)
            }
            try container.encode(dependencies, forKey: .dependencies)
            try container.encode(requirement, forKey: .requirement)
        }
    }

    public typealias Artifact = Component

    public var artifacts: [Artifact] {
        get { components }
        set { components = newValue }
    }

    public init(
        schemaVersion: Int = 2,
        toolchainAPI: Int = 2,
        keyID: String,
        version: String,
        publishedAt: Date,
        appVersionRange: AppVersionRange,
        components: [Component],
        signatureEd25519: String
    ) {
        self.schemaVersion = schemaVersion
        self.toolchainAPI = toolchainAPI
        self.keyID = keyID
        self.version = version
        self.publishedAt = publishedAt
        self.appVersionRange = appVersionRange
        self.components = components
        self.signatureEd25519 = signatureEd25519
    }

    public init(
        version: String,
        publishedAt: Date,
        artifacts: [Artifact],
        signatureEd25519: String
    ) {
        self.init(
            schemaVersion: 1,
            toolchainAPI: 1,
            keyID: "",
            version: version,
            publishedAt: publishedAt,
            appVersionRange: .init(minimum: "0.0.0", maximumExclusive: nil),
            components: artifacts,
            signatureEd25519: signatureEd25519
        )
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case toolchainAPI
        case keyID
        case version
        case publishedAt
        case appVersionRange
        case components
        case artifacts
        case signatureEd25519
    }

    private struct LegacyArtifact: Codable {
        var name: String
        var url: String
        var sha256: String
        var sizeBytes: UInt64
        var contents: [String]

        init(_ component: Component) {
            name = component.name
            url = component.url
            sha256 = component.sha256
            sizeBytes = component.sizeBytes
            contents = component.contents
        }

        var component: Component {
            Component(
                name: name,
                url: url,
                sha256: sha256,
                sizeBytes: sizeBytes,
                contents: contents
            )
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        version = try container.decode(String.self, forKey: .version)
        publishedAt = try container.decode(Date.self, forKey: .publishedAt)
        signatureEd25519 = try container.decode(String.self, forKey: .signatureEd25519)

        if schemaVersion >= 2 {
            toolchainAPI = try container.decode(Int.self, forKey: .toolchainAPI)
            keyID = try container.decode(String.self, forKey: .keyID)
            appVersionRange = try container.decode(AppVersionRange.self, forKey: .appVersionRange)
            components = try container.decode([Component].self, forKey: .components)
        } else {
            toolchainAPI = 1
            keyID = ""
            appVersionRange = .init(minimum: "0.0.0", maximumExclusive: nil)
            components = try container.decode([LegacyArtifact].self, forKey: .artifacts).map(\.component)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(version, forKey: .version)
        try container.encode(publishedAt, forKey: .publishedAt)
        try container.encode(signatureEd25519, forKey: .signatureEd25519)

        if schemaVersion >= 2 {
            try container.encode(schemaVersion, forKey: .schemaVersion)
            try container.encode(toolchainAPI, forKey: .toolchainAPI)
            try container.encode(keyID, forKey: .keyID)
            try container.encode(appVersionRange, forKey: .appVersionRange)
            try container.encode(components, forKey: .components)
        } else {
            try container.encode(components.map(LegacyArtifact.init), forKey: .artifacts)
        }
    }
}

public struct ManifestArtifactInput: Equatable {
    public var name: String
    public var artifactURL: String
    public var zipURL: URL
    public var contents: [String]
    public var capabilities: [String]
    public var dependencies: [String]
    public var requirement: ManifestDocument.ComponentRequirement
    public var criticalFilePaths: [String]
    public var deriveExactContents: Bool

    public init(name: String, artifactURL: String, zipURL: URL, contents: [String]) {
        self.name = name
        self.artifactURL = artifactURL
        self.zipURL = zipURL
        self.contents = contents
        self.capabilities = []
        self.dependencies = []
        self.requirement = .required
        self.criticalFilePaths = []
        self.deriveExactContents = false
    }

    public init(
        name: String,
        artifactURL: String,
        zipURL: URL,
        capabilities: [String],
        dependencies: [String],
        requirement: ManifestDocument.ComponentRequirement,
        contents: [String] = [],
        criticalFilePaths: [String] = [],
        deriveExactContents: Bool = true
    ) {
        self.name = name
        self.artifactURL = artifactURL
        self.zipURL = zipURL
        self.contents = contents
        self.capabilities = capabilities
        self.dependencies = dependencies
        self.requirement = requirement
        self.criticalFilePaths = criticalFilePaths
        self.deriveExactContents = deriveExactContents
    }
}

public enum ManifestBuilder {
    public static let maximumReleaseAssetBytes: UInt64 = 2_147_483_648

    public static func build(
        version: String,
        publishedAt: Date,
        artifacts: [ManifestArtifactInput],
        privateKeyBase64: String
    ) throws -> ManifestDocument {
        let key = try privateKey(from: privateKeyBase64)
        let builtArtifacts = try artifacts.map {
            try makeComponent(from: $0, deriveCoreCriticalFiles: false)
        }
        var manifest = ManifestDocument(
            version: version,
            publishedAt: publishedAt,
            artifacts: builtArtifacts,
            signatureEd25519: ""
        )
        manifest.signatureEd25519 = try key.signature(
            for: canonicalData(for: manifest)
        ).base64EncodedString()
        return manifest
    }

    public static func build(
        version: String,
        publishedAt: Date,
        appVersionRange: ManifestDocument.AppVersionRange,
        components: [ManifestArtifactInput],
        privateKeyBase64: String
    ) throws -> ManifestDocument {
        guard !components.isEmpty,
              components.allSatisfy({ !$0.criticalFilePaths.isEmpty }) else {
            throw NSError(
                domain: "ManifestTool",
                code: 9,
                userInfo: [
                    NSLocalizedDescriptionKey: "Schema-2 components must declare critical files to hash."
                ]
            )
        }
        let key = try privateKey(from: privateKeyBase64)
        let builtComponents = try components.map {
            try makeComponent(from: $0, deriveCoreCriticalFiles: true)
        }
        let publicKeyData = key.publicKey.rawRepresentation
        let keyID = SHA256.hash(data: publicKeyData).map { String(format: "%02x", $0) }.joined()
        var manifest = ManifestDocument(
            keyID: keyID,
            version: version,
            publishedAt: publishedAt,
            appVersionRange: appVersionRange,
            components: builtComponents,
            signatureEd25519: ""
        )
        manifest.signatureEd25519 = try key.signature(for: canonicalData(for: manifest)).base64EncodedString()
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

    private static func makeComponent(
        from input: ManifestArtifactInput,
        deriveCoreCriticalFiles: Bool
    ) throws -> ManifestDocument.Component {
        let size = try FileManager.default.attributesOfItem(atPath: input.zipURL.path)[.size] as? UInt64 ?? 0
        guard size > 0, size < maximumReleaseAssetBytes else {
            throw NSError(
                domain: "ManifestTool",
                code: 10,
                userInfo: [
                    NSLocalizedDescriptionKey: "Release components must be smaller than GitHub's 2 GiB asset limit."
                ]
            )
        }
        let sha = try sha256Hex(url: input.zipURL)
        let contents = input.deriveExactContents ? try archiveContents(at: input.zipURL) : input.contents
        var criticalFilePaths = Set(input.criticalFilePaths)
        if deriveCoreCriticalFiles, input.name == "macos-arm64-core" {
            criticalFilePaths.formUnion(
                ManifestToolDefaults.criticalCoreFiles(in: contents)
            )
            criticalFilePaths.formUnion(try archiveExecutablePaths(at: input.zipURL))
        }
        let criticalFileHashes = try archiveCriticalFileHashes(
            zipURL: input.zipURL,
            paths: criticalFilePaths.sorted()
        )
        return ManifestDocument.Component(
            name: input.name,
            capabilities: input.capabilities,
            url: input.artifactURL,
            sha256: sha,
            sizeBytes: size,
            contents: contents,
            criticalFileHashes: criticalFileHashes,
            dependencies: input.dependencies,
            requirement: input.requirement
        )
    }

    private static func privateKey(from privateKeyBase64: String) throws -> Curve25519.Signing.PrivateKey {
        guard let keyData = Data(base64Encoded: privateKeyBase64) else {
            throw NSError(domain: "ManifestTool", code: 3, userInfo: [NSLocalizedDescriptionKey: "Invalid private key base64"])
        }
        return try Curve25519.Signing.PrivateKey(rawRepresentation: keyData)
    }

    private static func archiveContents(at zipURL: URL) throws -> [String] {
        try rejectArchiveLinks(at: zipURL)
        let output = try runUnzip(arguments: ["-Z1", zipURL.path])
        let entries = String(decoding: output, as: UTF8.self)
            .split(whereSeparator: \.isNewline)
            .map(String.init)
            .filter { !$0.hasSuffix("/") }
        try validateArchivePaths(entries)
        guard !entries.isEmpty, Set(entries).count == entries.count else {
            throw NSError(domain: "ManifestTool", code: 8, userInfo: [NSLocalizedDescriptionKey: "Archive contents are empty or duplicated"])
        }
        return entries.sorted()
    }

    private static func rejectArchiveLinks(at zipURL: URL) throws {
        let process = Process()
        let stdout = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/zipinfo")
        process.arguments = ["-l", zipURL.path]
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        try process.run()
        let output = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationReason == .exit, process.terminationStatus == 0 else {
            throw NSError(domain: "ManifestTool", code: 8, userInfo: [NSLocalizedDescriptionKey: "Unable to inspect component archive metadata"])
        }
        let text = String(decoding: output, as: UTF8.self)
        if text.split(whereSeparator: \.isNewline).contains(where: { $0.first == "l" }) {
            throw NSError(domain: "ManifestTool", code: 8, userInfo: [NSLocalizedDescriptionKey: "Component archive contains a symbolic link"])
        }
    }

    private static func archiveExecutablePaths(at zipURL: URL) throws -> Set<String> {
        let process = Process()
        let stdout = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/zipinfo")
        process.arguments = ["-l", zipURL.path]
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        try process.run()
        let output = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationReason == .exit, process.terminationStatus == 0 else {
            throw NSError(
                domain: "ManifestTool",
                code: 8,
                userInfo: [NSLocalizedDescriptionKey: "Unable to inspect component archive permissions"]
            )
        }

        var paths = Set<String>()
        for line in String(decoding: output, as: UTF8.self).split(whereSeparator: \.isNewline) {
            let permissions = line.prefix(10)
            guard permissions.first == "-", permissions.contains("x") else { continue }
            let fields = line.split(separator: " ", maxSplits: 9, omittingEmptySubsequences: true)
            guard fields.count == 10 else {
                throw NSError(
                    domain: "ManifestTool",
                    code: 8,
                    userInfo: [NSLocalizedDescriptionKey: "Unable to parse executable archive entry"]
                )
            }
            paths.insert(String(fields[9]))
        }
        try validateArchivePaths(Array(paths))
        return paths
    }

    private static func archiveCriticalFileHashes(zipURL: URL, paths: [String]) throws -> [String: String] {
        guard !paths.isEmpty else { return [:] }
        try validateArchivePaths(paths)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try runUnzip(arguments: ["-qq", zipURL.path, "-d", root.path])
        let resolvedRoot = root.resolvingSymlinksInPath().standardizedFileURL.path
        var result: [String: String] = [:]
        for path in paths {
            let file = root.appendingPathComponent(path).resolvingSymlinksInPath().standardizedFileURL
            guard file.path.hasPrefix(resolvedRoot + "/"),
                  FileManager.default.fileExists(atPath: file.path) else {
                throw NSError(domain: "ManifestTool", code: 8, userInfo: [NSLocalizedDescriptionKey: "Critical file is missing or escapes the archive root: \(path)"])
            }
            result[path] = try sha256Hex(url: file)
        }
        return result
    }

    private static func runUnzip(arguments: [String]) throws -> Data {
        let process = Process()
        let stdout = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = arguments
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationReason == .exit, process.terminationStatus == 0 else {
            throw NSError(domain: "ManifestTool", code: 8, userInfo: [NSLocalizedDescriptionKey: "Unable to inspect component archive"])
        }
        return data
    }

    private static func validateArchivePaths(_ paths: [String]) throws {
        for path in paths {
            let parts = path.split(separator: "/", omittingEmptySubsequences: false)
            guard !path.isEmpty,
                  !path.hasPrefix("/"),
                  !path.contains("\\"),
                  !parts.contains(where: { $0 == "." || $0 == ".." }) else {
                throw NSError(domain: "ManifestTool", code: 8, userInfo: [NSLocalizedDescriptionKey: "Archive contains an unsafe path"])
            }
        }
    }
}

public enum ManifestToolDefaults {
    public static let coreCapabilities = [
        "runtime.core",
        "geometry.colmap",
        "geometry.da3.runtime",
        "training.msplat",
    ]

    public static let criticalCoreAnchors = [
        "bin/colmap",
        "bin/easysplat-train",
        "bin/default.metallib",
        "da3_mps/bin/easysplat_da3_sfm",
        "da3_mps/python/bin/python3",
        "da3_mps/app/easysplat_da3_sfm/run.py",
        "da3_mps/build_info.json",
        "msplat/build_info.json",
    ]

    public static let criticalCoreFiles = criticalCoreAnchors

    public static func criticalCoreFiles(in contents: [String]) -> Set<String> {
        var required = Set(criticalCoreAnchors)
        for path in contents {
            let lowercased = path.lowercased()
            let pathExtension = URL(fileURLWithPath: lowercased).pathExtension
            let isPythonCode = ["py", "pyc", "pth"].contains(pathExtension)
                && (
                    lowercased.hasPrefix("da3_mps/app/")
                        || lowercased.hasPrefix("da3_mps/vendor/")
                        || lowercased.hasPrefix("da3_mps/python/")
                )
            let isRuntimeConfiguration = ["yaml", "yml", "json", "toml"].contains(pathExtension)
                && (
                    lowercased.hasPrefix("da3_mps/app/")
                        || lowercased.hasPrefix("da3_mps/vendor/")
                        || lowercased.hasPrefix("da3_mps/python/")
                )
            let isLoadedLibrary = ["dylib", "so"].contains(pathExtension)
                && (
                    lowercased.hasPrefix("lib/")
                        || lowercased.hasPrefix("da3_mps/")
                )
            let isMetalLibrary = pathExtension == "metallib"
            let pathComponents = lowercased.split(separator: "/")
            let isNestedExecutablePayload = lowercased.hasPrefix("da3_mps/")
                && pathComponents.dropLast().contains(where: { $0 == "bin" || $0 == "libexec" })
            let isExecutablePayload = lowercased.hasPrefix("bin/")
                || lowercased.hasPrefix("da3_mps/bin/")
                || lowercased.hasPrefix("da3_mps/python/bin/")
                || isNestedExecutablePayload
            if isPythonCode || isRuntimeConfiguration || isLoadedLibrary || isMetalLibrary || isExecutablePayload {
                required.insert(path)
            }
        }
        return required
    }

    public static let splitCoreContents = [
        "bin/colmap",
        "bin/easysplat-train",
        "bin/default.metallib",
        "lib/libcrypto.3.dylib",
        "lib/libssl.3.dylib",
        "msplat/build_info.json",
        "msplat/LICENSE",
        "da3_mps/bin/easysplat_da3_sfm",
        "da3_mps/python/bin/python3",
        "da3_mps/build_info.json",
        "da3_mps/app/easysplat_da3_sfm/run.py",
        "da3_mps/vendor/depth-anything-3/src/depth_anything_3/api.py",
    ]

    public static let splitModelsContents = [
        "da3_mps/models/DA3-BASE/config.json",
        "da3_mps/models/DA3-BASE/model.safetensors",
        "da3_mps/models/DA3-BASE/easysplat_model_info.json",
        "da3_mps/models/DA3-SMALL/config.json",
        "da3_mps/models/DA3-SMALL/model.safetensors",
        "da3_mps/models/DA3-SMALL/easysplat_model_info.json",
    ]

    public static let da3BaseContents = [
        "da3_mps/models/DA3-BASE/config.json",
        "da3_mps/models/DA3-BASE/model.safetensors",
        "da3_mps/models/DA3-BASE/easysplat_model_info.json",
    ]

    public static let da3SmallContents = [
        "da3_mps/models/DA3-SMALL/config.json",
        "da3_mps/models/DA3-SMALL/model.safetensors",
        "da3_mps/models/DA3-SMALL/easysplat_model_info.json",
    ]

    public static let monolithicContents = splitCoreContents + splitModelsContents
}

public enum ManifestKeyInput {
    public static func resolvePrivateKeyBase64(parser: inout ArgParser) throws -> String {
        guard parser.value(for: "--private-key") == nil else {
            throw NSError(
                domain: "ManifestTool",
                code: 5,
                userInfo: [
                    NSLocalizedDescriptionKey: "Private keys must be read from a file or environment variable, not a process argument."
                ]
            )
        }
        let filePath = parser.value(for: "--private-key-file")
        let envName = parser.value(for: "--private-key-env")
        let sources = [filePath, envName].compactMap { $0 }
        guard sources.count == 1 else {
            throw NSError(
                domain: "ManifestTool",
                code: 5,
                userInfo: [NSLocalizedDescriptionKey: "Specify exactly one private key source: --private-key-file or --private-key-env"]
            )
        }

        if let filePath {
            let url = URL(fileURLWithPath: filePath)
            return try String(contentsOf: url, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard let envName else {
            throw NSError(
                domain: "ManifestTool",
                code: 5,
                userInfo: [NSLocalizedDescriptionKey: "Specify exactly one private key source"]
            )
        }
        let trimmedName = envName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty,
              let value = ProcessInfo.processInfo.environment[trimmedName]?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else {
            throw NSError(
                domain: "ManifestTool",
                code: 6,
                userInfo: [NSLocalizedDescriptionKey: "Environment variable \(envName) does not contain a private key"]
            )
        }
        return value
    }

    public static func writePrivateKeyBase64(_ value: String, to url: URL) throws {
        let fm = FileManager.default
        let parent = url.deletingLastPathComponent()
        try fm.createDirectory(at: parent, withIntermediateDirectories: true)
        let tempURL = parent.appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")
        defer {
            if fm.fileExists(atPath: tempURL.path) {
                try? fm.removeItem(at: tempURL)
            }
        }

        guard fm.createFile(
            atPath: tempURL.path,
            contents: Data(value.utf8),
            attributes: [.posixPermissions: 0o600]
        ) else {
            throw NSError(
                domain: "ManifestTool",
                code: 7,
                userInfo: [NSLocalizedDescriptionKey: "Failed to create private key file at \(url.path)"]
            )
        }
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: tempURL.path)

        if fm.fileExists(atPath: url.path) {
            _ = try fm.replaceItemAt(url, withItemAt: tempURL, backupItemName: nil, options: [])
        } else {
            try fm.moveItem(at: tempURL, to: url)
        }
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
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
