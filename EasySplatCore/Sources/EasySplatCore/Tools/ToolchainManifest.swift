import CryptoKit
import Foundation

/// Signed description of the independently installable EasySplat toolchain components.
///
/// Schema 2 is the canonical component manifest. The custom decoder and encoder keep
/// schema-1 `artifacts` manifests verifiable while existing releases age out.
public struct ToolchainManifest: Codable, Sendable {
    public static let currentSchemaVersion = 2
    public static let currentToolchainAPI = 2

    public enum ComponentRequirement: String, Codable, Sendable {
        case required
        case optional
    }

    public struct AppVersionRange: Codable, Sendable, Equatable {
        public var minimum: String
        public var maximumExclusive: String?

        public init(minimum: String, maximumExclusive: String?) {
            self.minimum = minimum
            self.maximumExclusive = maximumExclusive
        }
    }

    public struct Component: Codable, Sendable, Equatable {
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

        /// Source compatibility for the unreleased schema-2 draft that named this
        /// general integrity map after its first executable-only use.
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

        /// Source-compatible initializer for schema-1 artifact call sites.
        public init(name: String, url: String, sha256: String, sizeBytes: UInt64, contents: [String]) {
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

            let critical = try container.decodeIfPresent([String: String].self, forKey: .criticalFileHashes)
            let legacy = try container.decodeIfPresent([String: String].self, forKey: .executableHashes)
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

    public enum ResolutionError: Error, LocalizedError, Equatable {
        case duplicateComponent(String)
        case missingCapability(String)
        case missingDependency(component: String, dependency: String)
        case dependencyCycle(String)

        public var errorDescription: String? {
            switch self {
            case .duplicateComponent(let name):
                return "Toolchain manifest contains duplicate component '\(name)'."
            case .missingCapability(let capability):
                return "Toolchain manifest does not provide requested capability '\(capability)'."
            case .missingDependency(let component, let dependency):
                return "Toolchain component '\(component)' is missing dependency '\(dependency)'."
            case .dependencyCycle(let name):
                return "Toolchain component dependency cycle includes '\(name)'."
            }
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

    /// Compatibility alias used by schema-1 install and test call sites.
    public var artifacts: [Artifact] {
        get { components }
        set { components = newValue }
    }

    public init(
        schemaVersion: Int,
        toolchainAPI: Int,
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

    /// Source- and signature-compatible schema-1 initializer.
    public init(version: String, publishedAt: Date, artifacts: [Artifact], signatureEd25519: String) {
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

    public func verifying(publicKeyBase64: String) -> Bool {
        guard let signatureData = Data(base64Encoded: signatureEd25519),
              let publicKeyData = Data(base64Encoded: publicKeyBase64),
              let canonical = try? canonicalData(),
              let publicKey = try? Curve25519.Signing.PublicKey(rawRepresentation: publicKeyData) else {
            return false
        }
        return publicKey.isValidSignature(signatureData, for: canonical)
    }

    public func hasMatchingKeyID(publicKeyBase64: String) -> Bool {
        guard schemaVersion >= Self.currentSchemaVersion else { return true }
        return Self.keyID(publicKeyBase64: publicKeyBase64) == keyID.lowercased()
    }

    public static func keyID(publicKeyBase64: String) -> String? {
        guard let publicKeyData = Data(base64Encoded: publicKeyBase64),
              (try? Curve25519.Signing.PublicKey(rawRepresentation: publicKeyData)) != nil else {
            return nil
        }
        return SHA256.hash(data: publicKeyData).map { String(format: "%02x", $0) }.joined()
    }

    public func canonicalData() throws -> Data {
        var copy = self
        copy.signatureEd25519 = ""
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(copy)
    }

    /// Resolves direct providers plus their transitive component dependencies.
    /// Returned components retain manifest order so packaging order remains deterministic.
    public func resolvedComponents(requesting requestedCapabilities: Set<String>) throws -> [Component] {
        var byName: [String: Component] = [:]
        for component in components {
            guard byName[component.name] == nil else {
                throw ResolutionError.duplicateComponent(component.name)
            }
            byName[component.name] = component
        }

        let providedCapabilities = Set(components.flatMap(\.capabilities))
        if let missing = requestedCapabilities.subtracting(providedCapabilities).sorted().first {
            throw ResolutionError.missingCapability(missing)
        }

        var selected = Set(
            components
                .filter { !requestedCapabilities.isDisjoint(with: $0.capabilities) }
                .map(\.name)
        )
        var visiting = Set<String>()
        var visited = Set<String>()

        func includeDependencies(of componentName: String) throws {
            if visited.contains(componentName) { return }
            guard !visiting.contains(componentName) else {
                throw ResolutionError.dependencyCycle(componentName)
            }
            guard let component = byName[componentName] else { return }
            visiting.insert(componentName)
            for dependency in component.dependencies {
                guard byName[dependency] != nil else {
                    throw ResolutionError.missingDependency(component: componentName, dependency: dependency)
                }
                selected.insert(dependency)
                try includeDependencies(of: dependency)
            }
            visiting.remove(componentName)
            visited.insert(componentName)
        }

        for name in selected.sorted() {
            try includeDependencies(of: name)
        }
        return components.filter { selected.contains($0.name) }
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
            Component(name: name, url: url, sha256: sha256, sizeBytes: sizeBytes, contents: contents)
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        version = try container.decode(String.self, forKey: .version)
        publishedAt = try container.decode(Date.self, forKey: .publishedAt)
        signatureEd25519 = try container.decode(String.self, forKey: .signatureEd25519)

        if schemaVersion >= Self.currentSchemaVersion {
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

        if schemaVersion >= Self.currentSchemaVersion {
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
