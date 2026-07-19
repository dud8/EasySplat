import CryptoKit
import Foundation

/// Signed description of the independently installable EasySplat toolchain components.
public struct ToolchainManifest: Codable, Sendable {
    public static let currentSchemaVersion = 2
    public static let currentToolchainAPI = 2
    public static let maximumEncodedBytes = 8 * 1_024 * 1_024
    public static let maximumInstallStateEnvelopeBytes = 16 * 1_024 * 1_024

    public enum AuthenticationError: Error {
        case invalidEncoding
        case invalidSignature
    }

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
        public var expandedSizeBytes: UInt64
        public var expandedClosureSHA256: String
        public var contents: [String]
        public var criticalFileHashes: [String: String]
        public var dependencies: [String]
        public var requirement: ComponentRequirement

        public init(
            name: String,
            capabilities: [String],
            url: String,
            sha256: String,
            sizeBytes: UInt64,
            expandedSizeBytes: UInt64? = nil,
            expandedClosureSHA256: String = String(repeating: "0", count: 64),
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
            self.expandedSizeBytes = expandedSizeBytes ?? sizeBytes
            self.expandedClosureSHA256 = expandedClosureSHA256
            self.contents = contents
            self.criticalFileHashes = criticalFileHashes
            self.dependencies = dependencies
            self.requirement = requirement
        }
    }

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

    public static func readAuthenticated(
        at url: URL,
        publicKeyBase64: String
    ) throws -> (manifest: ToolchainManifest, data: Data) {
        let data = try BoundedFileReader.readRegularFile(
            at: url,
            maximumBytes: maximumEncodedBytes
        )
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let manifest = try? decoder.decode(ToolchainManifest.self, from: data) else {
            throw AuthenticationError.invalidEncoding
        }
        guard manifest.hasMatchingKeyID(publicKeyBase64: publicKeyBase64),
              manifest.verifying(publicKeyBase64: publicKeyBase64) else {
            throw AuthenticationError.invalidSignature
        }
        return (manifest, data)
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
}
